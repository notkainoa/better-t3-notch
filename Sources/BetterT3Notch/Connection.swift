import Foundation
import os

private let log = Logger(subsystem: "me.kainoa.better-t3-notch", category: "connection")

/// Where a server answers and how to get in, worked out fresh before every connect.
struct Endpoint {
    let origin: URL
    let token: String
    let environmentId: String?
    let commandOutputStreaming: Bool
}

@MainActor
protocol ConnectionDelegate: AnyObject {
    /// A new socket is up and its shell subscription is on its way.
    func connectionDidOpen(_ connection: Connection)
    func connection(_ connection: Connection, received incoming: Incoming)
    /// The socket went away; it is already retrying. `status` is the HTTP status of a refused upgrade.
    func connectionDidDrop(_ connection: Connection, status: Int?)
}

/// One T3 server's WebSocket RPC: this Mac's, or another machine's through T3 Connect.
/// Reconnects by itself, with backoff, until `close()`.
@MainActor
final class Connection {
    /// Nil for this Mac's server; the environment id of another machine's.
    let remoteId: String?
    /// What T3 calls the machine ("Alex's MacBook Air"); empty for this Mac.
    let label: String
    weak var delegate: ConnectionDelegate?

    /// The shell snapshot arrived on this socket: the threads shown for this machine are current.
    private(set) var connected = false
    /// When this machine's threads stopped being current (the first drop since its last snapshot).
    private(set) var downSince: Date?
    private(set) var environmentId: String?
    private(set) var commandOutputStreaming = false
    var isOpen: Bool { socket != nil }
    /// The socket is up and the server is answering, even if the snapshot is still on its way.
    var answering: Bool {
        socket != nil && heardOnSocket && Date().timeIntervalSince(lastHeard) < pingEvery * 3
    }

    /// Request ids of this socket's streams. Thread ids here are the server's own.
    private(set) var shellRequestId = ""
    var threadRequests: [String: String] = [:] // threadId -> requestId
    var requestThreads: [String: String] = [:] // requestId -> threadId
    var commandThreads: [String: String] = [:] // requestId -> the store's thread key (dispatchCommand)

    private let resolve: () async throws -> Endpoint
    /// Ping cadence, and how long the socket may stay silent before it counts as dead.
    private let pingEvery: TimeInterval
    private let silenceLimit: TimeInterval?
    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var nextRequestId = 1
    private var pingTimer: Timer?
    private var retryDelay: TimeInterval = 1
    private var lastHeard = Date()
    private var heardOnSocket = false
    private var openedAt = Date()
    private var closed = false

    init(remoteId: String?, label: String, pingEvery: TimeInterval, silenceLimit: TimeInterval?,
         resolve: @escaping () async throws -> Endpoint) {
        self.remoteId = remoteId
        self.label = label
        self.pingEvery = pingEvery
        self.silenceLimit = silenceLimit
        self.resolve = resolve
    }

    func start() {
        closed = false
        connect()
    }

    /// Stop for good (the machine was unlinked).
    func close() {
        closed = true
        generation += 1
        teardown()
        connected = false
    }

    /// Drop the socket and connect again now (back from sleep): a socket that slept may be dead
    /// without knowing it yet.
    func reconnectNow() {
        guard !closed else { return }
        retryDelay = 1
        generation += 1
        teardown()
        // Same as a drop: whatever was waiting on the old socket won't hear back.
        if downSince == nil { downSince = Date() }
        connected = false
        delegate?.connectionDidDrop(self, status: nil)
        connect()
    }

    private func connect() {
        generation += 1
        let gen = generation
        Task {
            do {
                let endpoint = try await resolve()
                guard gen == generation, !closed else { return }
                environmentId = endpoint.environmentId ?? environmentId
                commandOutputStreaming = endpoint.commandOutputStreaming
                open(endpoint, gen: gen)
            } catch {
                scheduleReconnect(gen, status: nil)
            }
        }
    }

    private func open(_ endpoint: Endpoint, gen: Int) {
        var comps = URLComponents(url: endpoint.origin, resolvingAgainstBaseURL: false)!
        comps.scheme = endpoint.origin.scheme == "https" ? "wss" : "ws"
        comps.path = "/ws"
        comps.queryItems = [.init(name: "orchestrationProtocol", value: String(ThreadStore.protocolVersion))]
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024 // thread snapshots can be large
        socket = task
        threadRequests = [:]
        requestThreads = [:]
        commandThreads = [:]
        lastHeard = Date()
        openedAt = Date()
        heardOnSocket = false
        task.resume()

        shellRequestId = send(tag: "orchestration.subscribeShell", payload: [:])
        // Ping now, not in 5 s: the first pong tells the store this machine is answering, so a
        // reconnect waiting on a big snapshot keeps its threads instead of flickering them away.
        sendRaw(["_tag": "Ping"])
        delegate?.connectionDidOpen(self)
        receive(task, gen: gen)

        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingEvery, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                // The server answers every ping; this long without a frame means the route is gone
                // (a tunnel dropped, or the network changed while asleep).
                // Before that, the shell snapshot (MBs through a tunnel) gets 90 s from the open,
                // however many pongs come back meanwhile: a subscription that never answers is
                // as dead as a silent socket.
                let now = Date()
                if let limit = self.silenceLimit,
                   self.connected ? now.timeIntervalSince(self.lastHeard) > limit
                                  : now.timeIntervalSince(self.openedAt) > max(limit, 90) {
                    log.notice("silent, reconnecting: \(self.label, privacy: .public)")
                    self.scheduleReconnect(gen, status: nil)
                    return
                }
                self.sendRaw(["_tag": "Ping"])
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, gen: Int) {
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                // Parse off the main thread; snapshots can be hundreds of KB.
                let data: Data? = switch message {
                case .string(let s): s.data(using: .utf8)
                case .data(let d): d
                @unknown default: nil
                }
                if let size = data?.count, size > 200_000 { log.notice("large message: \(size) bytes") }
                let incoming = data.flatMap(Incoming.parse)
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    self.lastHeard = Date()
                    self.heardOnSocket = true
                    // Pongs only prove the route; the threads are current once the snapshot is in.
                    if !self.connected, case .chunk(let id, _)? = incoming, id == self.shellRequestId {
                        self.connected = true
                        self.downSince = nil
                        self.retryDelay = 1
                        if self.remoteId != nil { log.notice("connected: \(self.label, privacy: .public)") }
                    }
                    if let incoming { self.delegate?.connection(self, received: incoming) }
                    self.receive(task, gen: gen)
                }
            case .failure:
                let status = (task.response as? HTTPURLResponse)?.statusCode
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    self.scheduleReconnect(gen, status: status)
                }
            }
        }
    }

    /// The shell stream ended, which it never should: start over.
    func shellEnded() { scheduleReconnect(generation, status: nil) }

    private func scheduleReconnect(_ gen: Int, status: Int?) {
        guard gen == generation, !closed else { return }
        generation += 1 // late callbacks from this socket are ignored from here on
        let next = generation
        teardown()
        if remoteId != nil, connected || status != nil {
            log.notice("dropped: \(self.label, privacy: .public) \(status.map(String.init) ?? "", privacy: .public)")
        }
        if downSince == nil { downSince = Date() }
        connected = false
        delegate?.connectionDidDrop(self, status: status)
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard next == generation, !closed else { return }
            connect()
        }
    }

    private func teardown() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pingTimer?.invalidate()
        pingTimer = nil
    }

    @discardableResult
    func send(tag: String, payload: [String: Any]) -> String {
        let id = String(nextRequestId)
        nextRequestId += 1
        sendRaw(["_tag": "Request", "id": id, "tag": tag, "payload": payload, "headers": [] as [Any]])
        return id
    }

    func sendRaw(_ object: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }
}
