import AppKit
import Combine
import Foundation
import os
import SQLite3

private let log = Logger(subsystem: "me.kainoa.better-t3-notch", category: "threads")

/// Mirrors T3 Code's sidebar status pill (`resolveThreadStatusPill` in apps/web
/// Sidebar.logic.ts), same names, same priority order.
enum ThreadStatus: Equatable, Sendable {
    case pendingApproval, awaitingInput, guestRequest, working, connecting, waiting, failed, planReady, completed
    /// No pill in T3: finished and already seen, stopped, or never run.
    case idle

    var label: String {
        switch self {
        case .pendingApproval: "Pending Approval"
        case .awaitingInput: "Awaiting Input"
        case .guestRequest: "Guest Request"
        case .working: "Working"
        case .connecting: "Connecting"
        case .waiting: "Waiting"
        case .failed: "Failed"
        case .planReady: "Plan Ready"
        case .completed: "Completed"
        case .idle: ""
        }
    }

    /// Blocked on the user.
    var needsYou: Bool { self == .pendingApproval || self == .awaitingInput }
    /// A run is actually in flight (stop / steer apply).
    var isBusy: Bool { self == .working || self == .connecting || self == .waiting }
    /// Shows up in the collapsed live ticker.
    var isActive: Bool { needsYou || isBusy || self == .guestRequest }
}

struct T3Thread: Identifiable, Equatable {
    let id: String
    let title: String
    let project: String
    let status: ThreadStatus
    var startedAt: Date?
    let updatedAt: Date
    var runId: String?
    var model: String?
    /// Provider driver ("claudeAgent", "codex", "cursor"…) for the logo next to the model.
    var provider: String?
    var branch: String?
    var pullRequest: String?
    /// What the agent is doing right now (running) or the last thing it said (finished).
    var activity: String?
    var activityIcon = "text.bubble"
    /// Latest assistant message, used for the "just finished" peek.
    var lastMessage: String?
    var filesChanged = 0
    var toolCalls = 0
    /// The approval / question the agent is blocked on, when it's waiting for you.
    var request: PendingRequest?
    /// Lines added / removed by the latest run (checkpoint, or live file edits while it runs).
    var linesAdded = 0
    var linesRemoved = 0
    var pr: PullRequestInfo?
    /// On T3's settled shelf (put away by hand, or its PR merged or closed).
    var settled = false
    /// Set when the provider's usage limit stopped the thread.
    var usageLimitResetAt: Date?
    var usageLimited = false
    /// `command_execution` item still running, for the live output peek.
    var runningCommandId: String?
}

struct PullRequestInfo: Equatable, Sendable {
    enum Checks: String, Sendable { case passing, failing, pending }
    enum Review: String, Sendable { case approved, changesRequested = "changes-requested", reviewRequired = "review-required" }
    let number: Int
    let url: String
    let state: String // open | closed | merged
    let isDraft: Bool
    let checks: Checks?
    let review: Review?
    let conflicting: Bool

    var label: String { "#\(number)" + (isDraft ? " draft" : state == "open" ? "" : " \(state)") }
}

struct ApprovalOption: Equatable, Sendable {
    let decision, label: String
    let warning: String?
    var isAccept: Bool { decision.hasPrefix("accept") }
}

struct QuestionOption: Equatable, Sendable {
    let label, value: String
    let description: String?
}

struct Question: Equatable, Sendable {
    let id, header, text: String
    let options: [QuestionOption]
    let multiSelect: Bool
}

struct PendingRequest: Equatable {
    enum Kind: Equatable {
        case approval(prompt: String?, reason: String?, options: [ApprovalOption])
        case questions([Question])
    }
    let id: String
    let kind: Kind

    /// One single-choice question is answerable with one tap; anything richer goes to T3 Code.
    var quickQuestion: Question? {
        guard case .questions(let qs) = kind, qs.count == 1, let q = qs.first,
              !q.multiSelect, !q.options.isEmpty else { return nil }
        return q
    }
}

/// Live view of T3 Code threads, streamed from the local T3 server over its WebSocket RPC.
///
/// - `orchestration.subscribeShell` gives every thread's status (cheap, no message bodies).
/// - `orchestration.subscribeThread` is opened only for the visible threads, for their
///   turn items (current command / file edit / last message).
@MainActor
final class ThreadStore: ObservableObject {
    @Published private(set) var threads: [T3Thread] = []
    /// Id of a thread that just changed into an interesting state; drives the "peek".
    @Published private(set) var eventId: String?
    @Published private(set) var connected = false
    /// Threads with a command in flight (button spinners) and ones whose last command failed.
    @Published private(set) var sending: Set<String> = []
    @Published private(set) var failed: [String: String] = [:]
    /// Last few lines of the command being peeked at (hovered / selected running row).
    @Published private(set) var commandOutput: [String: [String]] = [:]
    /// Set when the server speaks a protocol this build doesn't (shown instead of threads).
    @Published private(set) var incompatible: String?
    /// Everything the collapsed pill and the list's footer count, over all threads (not just the
    /// ones with rows).
    @Published private(set) var summary = NotchSummary()

    var busy: [T3Thread] { threads.filter { $0.status.isBusy } }
    var needsYou: [T3Thread] { threads.filter { $0.status.needsYou } }
    var active: [T3Thread] { threads.filter { $0.status.isActive } }
    /// The open list: only threads waiting on you (needs you, plan ready, failed, done unread).
    var inbox: [T3Thread] { threads.filter { inboxIds.contains($0.id) } }
    /// Which of `threads` the list shows (the rest are followed for work or a pop-up).
    private var inboxIds: Set<String> = []
    /// The pop-up the notch shows: `eventId`'s thread, unless that kind of pop-up is turned off.
    var event: T3Thread? {
        guard let t = eventId.flatMap({ id in threads.first { $0.id == id } }) else { return nil }
        return Self.popsUp(eventKind) ? t : nil
    }
    /// What the event was when it happened. Not read off the thread's status later: T3 shows a
    /// failed run you've looked at as idle, which would make it follow the "finished" switch.
    enum EventKind { case done, failed, needsYou, forced }
    private var eventKind: EventKind = .done

    private static func popsUp(_ kind: EventKind) -> Bool {
        switch kind {
        case .done: Settings.popDone
        case .failed: Settings.popFailed
        case .needsYou: Settings.popNeedsYou
        case .forced: true // brought back on purpose (showEvent)
        }
    }

    /// A pop-up switch changed: put away a pop-up of a kind that's now turned off.
    func popUpSettingsChanged() {
        if eventId != nil, !Self.popsUp(eventKind) { dismissEvent() }
    }
    /// The "needs you" card stays up (and stays interactive) until it's answered or dismissed.
    var stickyEvent: T3Thread? { event.flatMap { $0.status.needsYou ? $0 : nil } }

    /// Rows in the open list, and busy threads followed for their activity and final message.
    static let inboxCount = 6
    static let busyCount = 4

    // Shell state
    private var shell: [String: ShellThread] = [:]
    private var projects: [String: String] = [:]
    private var lastPhases: [String: RunPhase] = [:]
    private var lastPRs: [String: PullRequestInfo] = [:]
    private var limitChimed: Set<String> = []
    private var outputWatch: (threadId: String, itemId: String, requestId: String, conn: Connection)?
    private var outputText = ""
    /// Streamed file edits come without their patch; look each up once for live +/- counts.
    private var fetchedEdits: Set<String> = []
    /// Connections being watched for threads that went stale (see `watchForStaleThreads`).
    private var staleWatches: Set<ObjectIdentifier> = []
    private var recomputeScheduled = false
    private var eventClearTask: Task<Void, Never>?
    /// The pop-up goes away once T3 Code says you've seen it: its read receipt (`lastVisitedAt`)
    /// reaches this time. Nil for pop-ups only an answer (or the timer) puts away.
    private var eventReadAfter: Date?
    /// The receipt came while T3 Code was in the background (a thread left open there, or the
    /// phone): you haven't looked yet, so it goes when T3 Code comes to the front.
    private var eventReadAway = false
    /// The finish's thread is settled (an agent that merges its own PR settles it as it ends):
    /// the card files itself away and goes sooner.
    /// The card reads this too, so the box only drops on a card that closes early, and vice versa.
    private(set) var eventSettled = false
    /// A finish while T3 Code is in front waits a beat for the receipt: you may be watching it.
    private var heldFinish: Task<Void, Never>?
    /// The held finish's thread, followed while it waits (an unvisited finish is no row).
    private var heldFinishId: String?

    // Per-thread detail (only for visible threads)
    private var details: [String: [String: TurnItem]] = [:]

    // Connections: this Mac's T3 server, and the other machines it's linked to.
    //
    // Threads are keyed by their own id on this Mac, and by "<environmentId>/<id>" on another
    // machine (ids are only unique per machine). Everything sent to a server uses its own id.
    private var local: Connection!
    private var remotes: [String: Connection] = [:]
    private var remoteLinks: [String: LinkedEnvironment] = [:]
    private let auth = TokenStore()
    private let remoteTokens = RemoteTokens()
    /// Connections whose shell snapshot just (re)arrived: their threads we didn't know yet are
    /// the starting point, not news, so they don't pop up or chime.
    private var freshSnapshots: Set<String> = []

    func start() {
        if !Self.demo.threads.isEmpty {
            // Demo: fake threads only, and no connection (or token) to the real T3 Code.
            connected = true
            scheduleRecompute()
            return
        }
        local = Connection(remoteId: nil, label: "", pingEvery: 20, silenceLimit: nil) { [weak self] in
            guard let self else { throw ConnectError.serverDown }
            return try await self.localEndpoint()
        }
        local.delegate = self
        local.start()
        Task { await refreshRemotes() }
        // Machines get linked and unlinked in T3's settings; pick that up without a restart.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.refreshRemotes() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Sockets that slept through a network change can look alive for a while: start
            // the other machines' over now, and mint again at once if one was waiting.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.remoteTokens.resetBackoff()
                self.remotes.values.forEach { $0.reconnectNow() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.t3BundleId else { return }
            MainActor.assumeIsolated {
                if self?.eventReadAway == true { self?.dismissEvent() }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkLimitResets()
                // Snoozes wake on a clock, not on an update. Offline, the old shell is stale.
                if self?.connected == true { self?.scheduleRecompute() }
            }
        }
    }

    /// Fires when anything in the notch brings T3 Code up: the notch closes behind it.
    let openedT3 = PassthroughSubject<Void, Never>()

    /// T3 Code, without picking a thread (the list's footer).
    func openApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.t3BundleId) else { return }
        closeForT3()
        NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }

    /// Put away the pop-up too: you're about to see the thread in T3 itself.
    private func closeForT3() {
        cancelHeldFinish()
        dismissEvent()
        openedT3.send()
    }

    // MARK: Opening threads

    func open(_ thread: T3Thread) {
        if let (conn, id) = route(thread.id), let env = conn.environmentId,
           let url = URL(string: "t3code://threads/\(env)/\(id)") {
            closeForT3()
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.t3BundleId) {
            closeForT3()
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    // MARK: Actions (need the orchestration:operate scope)

    func approve(_ thread: T3Thread, _ option: ApprovalOption) {
        guard let request = thread.request else { return }
        dispatch(thread, ["type": "runtime-request.respond", "threadId": thread.id,
                          "requestId": request.id, "decision": option.decision])
    }

    func answer(_ thread: T3Thread, _ question: Question, _ option: QuestionOption) {
        guard let request = thread.request else { return }
        dispatch(thread, ["type": "runtime-request.respond", "threadId": thread.id,
                          "requestId": request.id, "answers": [question.id: option.value]])
    }

    func stop(_ thread: T3Thread) {
        guard let runId = thread.runId else { return }
        // holdQueue: same as T3's own stop button; queued follow-ups wait instead of starting.
        dispatch(thread, ["type": "run.interrupt", "threadId": thread.id, "runId": runId, "holdQueue": true])
    }

    /// Follow-up message. `deliveryIntent: auto` lets the server pick: steer the live run,
    /// queue behind it, or start a new run, the same way T3's composer does.
    func reply(_ thread: T3Thread, _ text: String) {
        dispatch(thread, ["type": "message.dispatch", "createdBy": "user", "creationSource": "web",
                          "threadId": thread.id, "messageId": UUID().uuidString.lowercased(),
                          "text": text, "attachments": [] as [Any],
                          "deliveryIntent": "auto", "dispatchMode": ["type": "start_immediately"]])
    }

    /// Bring a put-away "needs you" card back (the little island beside the notch).
    func showEvent(_ t: T3Thread) {
        // Asked for by hand: a receipt that already came doesn't put it straight back.
        let after = shell[t.id].flatMap { s in s.readAfter.flatMap { s.isRead(after: $0) ? nil : $0 } }
        show(t.id, .forced, for: t.status.needsYou ? nil : 7, readAfter: after)
    }

    func dismissEvent() {
        eventClearTask?.cancel()
        eventClearTask = nil
        eventSettled = false
        eventDeadline = nil
        eventId = nil
        eventReadAfter = nil
        eventReadAway = false
    }

    private func dispatch(_ thread: T3Thread, _ command: [String: Any]) {
        guard let (conn, id) = route(thread.id), conn.isOpen else {
            failed[thread.id] = "Not connected to T3 Code"
            return
        }
        var command = command
        command["threadId"] = id // the server's own id, not the notch's key
        command["commandId"] = "better-t3-notch:\(UUID().uuidString.lowercased())"
        failed[thread.id] = nil
        sending.insert(thread.id)
        let requestId = conn.send(tag: "orchestration.dispatchCommand", payload: command)
        conn.commandThreads[requestId] = thread.id
    }

    // MARK: Connections

    /// This Mac's server: wherever its runtime file says, re-read on every connect, since a
    /// restarted server may be on a new port (or a new install).
    private func localEndpoint() async throws -> Endpoint {
        guard let origin = Self.serverOrigin() else { throw ConnectError.serverDown }
        let env = await ServerDescriptor.fetch(origin)
        if let env, let v = env.protocolVersion, v != Self.protocolVersion {
            incompatible = "T3 Code \(env.serverVersion ?? "") speaks protocol \(v); Better T3 Notch speaks \(Self.protocolVersion)"
            throw ConnectError.incompatible
        }
        if env != nil { incompatible = nil }
        guard let token = try await auth.token() else { throw ConnectError.noToken }
        return Endpoint(origin: origin, token: token, environmentId: env?.id ?? local.environmentId,
                        commandOutputStreaming: env?.commandOutputStreaming ?? local.commandOutputStreaming)
    }

    /// Another machine's server, at the first of its addresses that answers as it.
    private func remoteEndpoint(_ link: LinkedEnvironment) async throws -> Endpoint {
        guard let (origin, env) = await RemoteAccess.origin(for: link) else { throw ConnectError.serverDown }
        guard let token = await remoteTokens.token(for: link) else { throw ConnectError.noToken }
        return Endpoint(origin: origin, token: token, environmentId: link.environmentId,
                        commandOutputStreaming: env.commandOutputStreaming)
    }

    /// Follow the machines T3 Code is linked to: connect to new ones, drop unlinked ones.
    private func refreshRemotes() async {
        guard let links = await RemoteAccess.linkedEnvironments() else { return }
        let wanted = Dictionary(links.map { ($0.environmentId, $0) }, uniquingKeysWith: { a, _ in a })
        // Unlinked, or linked again with other addresses or another name: start that one over.
        for (id, conn) in remotes where wanted[id] != remoteLinks[id] {
            log.notice("unlinked: \(conn.label, privacy: .public)")
            conn.close()
            remotes[id] = nil
            remoteLinks[id] = nil
            dropThreads(of: conn)
        }
        updateConnected()
        for link in wanted.values where remotes[link.environmentId] == nil && link.environmentId != local.environmentId {
            remoteLinks[link.environmentId] = link
            log.notice("linked: \(link.label, privacy: .public)")
            // T3's own client pings every 5 s and gives up after 15 s of silence: tunnels drop
            // idle sockets, and a dead route otherwise looks alive for minutes.
            let conn = Connection(remoteId: link.environmentId, label: link.label,
                                  pingEvery: 5, silenceLimit: 15) { [weak self] in
                guard let self else { throw ConnectError.serverDown }
                return try await self.remoteEndpoint(link)
            }
            conn.delegate = self
            remotes[link.environmentId] = conn
            conn.start()
        }
    }

    private var allConnections: [Connection] { (local.map { [$0] } ?? []) + remotes.values }

    /// The store's key for a server's thread (or project) id.
    private func key(_ id: String, _ conn: Connection) -> String {
        conn.remoteId.map { "\($0)/\(id)" } ?? id
    }

    /// Which server a key belongs to, and its id there.
    private func route(_ key: String) -> (Connection, String)? {
        guard let slash = key.firstIndex(of: "/") else { return local.map { ($0, key) } }
        guard let conn = remotes[String(key[..<slash])] else { return nil }
        return (conn, String(key[key.index(after: slash)...]))
    }

    private func belongs(_ key: String, to conn: Connection) -> Bool {
        conn.remoteId.map { key.hasPrefix("\($0)/") } ?? !key.contains("/")
    }

    private func connectionKey(_ conn: Connection) -> String { conn.remoteId ?? "" }

    private func updateConnected() {
        let any = allConnections.contains(where: \.connected)
        if connected != any { connected = any }
    }

    /// A server is gone for good (or for longer than a blip): its threads leave the notch rather
    /// than sit there "running".
    private func dropThreads(of conn: Connection) {
        shell = shell.filter { !belongs($0.key, to: conn) }
        projects = projects.filter { !belongs($0.key, to: conn) }
        details = details.filter { !belongs($0.key, to: conn) }
        sending = sending.filter { !belongs($0, to: conn) }
        failed = failed.filter { !belongs($0.key, to: conn) }
        commandOutput = commandOutput.filter { !belongs($0.key, to: conn) }
        if let id = eventId, belongs(id, to: conn) { dismissEvent() }
        if let id = heldFinishId, belongs(id, to: conn) { cancelHeldFinish() }
        if let watch = outputWatch, watch.conn === conn { outputWatch = nil }
        scheduleRecompute()
    }

    // MARK: Incoming

    private func handle(_ incoming: Incoming, from conn: Connection) {
        switch incoming {
        case .chunk(let requestId, let values):
            conn.sendRaw(["_tag": "Ack", "requestId": requestId]) // flow control: server waits for this
            if requestId == conn.shellRequestId {
                values.compactMap(\.shell).forEach { apply($0, from: conn) }
                scheduleRecompute()
            } else if let threadId = conn.requestThreads[requestId] {
                let k = key(threadId, conn)
                values.compactMap(\.thread).forEach { apply($0, to: k) }
                scheduleRecompute()
            } else if let watch = outputWatch, watch.conn === conn, watch.requestId == requestId {
                for frame in values.compactMap(\.output) {
                    outputText = frame.replace ? frame.text : outputText + frame.text
                    if outputText.count > 8000 { outputText = String(outputText.suffix(4000)) }
                }
                commandOutput[watch.threadId] = Self.tailLines(outputText, 4)
            }
        case .exit(let requestId, let ok, let message):
            if let watch = outputWatch, watch.conn === conn, watch.requestId == requestId { outputWatch = nil } // command finished
            if let threadKey = conn.commandThreads.removeValue(forKey: requestId) {
                sending.remove(threadKey)
                if !ok { failed[threadKey] = message ?? "T3 Code rejected that" }
            } else if requestId == conn.shellRequestId {
                conn.shellEnded() // shell stream should never end
            } else if let threadId = conn.requestThreads.removeValue(forKey: requestId) {
                conn.threadRequests[threadId] = nil
            }
        case .ignored:
            break
        }
    }

    private func apply(_ item: ShellItem, from conn: Connection) {
        let prefix = conn.remoteId
        switch item {
        case .snapshot(let threads, let projects):
            shell = shell.filter { !belongs($0.key, to: conn) }
            for t in threads.map({ $0.namespaced(prefix) }) where shell[t.id] == nil { shell[t.id] = t }
            self.projects = self.projects.filter { !belongs($0.key, to: conn) }
            for (id, title) in projects { self.projects[key(id, conn)] = title }
            freshSnapshots.insert(connectionKey(conn))
        case .projects(let projects):
            for (id, title) in projects { self.projects[key(id, conn)] = title }
        case .threadUpdated(let thread):
            let t = thread.namespaced(prefix)
            shell[t.id] = t
        case .threadRemoved(let id):
            shell[key(id, conn)] = nil
        }
    }

    private func apply(_ item: ThreadItem, to threadId: String) {
        switch item {
        case .snapshot(let items):
            details[threadId] = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        case .turnItem(var item):
            var d = details[threadId] ?? [:]
            if item.linesAdded == nil, let old = d[item.id], old.linesAdded != nil { // keep fetched counts
                item.linesAdded = old.linesAdded
                item.linesRemoved = old.linesRemoved
            }
            d[item.id] = item
            if d.count > 400 { // keep memory bounded on very long runs
                let keep = d.values.sorted { $0.ordinal > $1.ordinal }.prefix(300)
                d = Dictionary(keep.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            details[threadId] = d
        }
    }

    // MARK: Derived state

    /// A streaming agent sends many updates a second; derive state at most 4x/s (still reads live).
    private func scheduleRecompute() {
        guard !recomputeScheduled else { return }
        recomputeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.recomputeScheduled = false
            self.recompute()
        }
    }

    private func recompute() {
        // Subagents ask through their parent: an app-owned child's question shows on its ancestors.
        var childRequests: [String: ThreadStatus] = [:]
        for child in shell.values {
            guard let request = child.subagentRequest else { continue }
            var seen: Set<String> = [child.id]
            var current: ShellThread? = child
            while let c = current, c.isSubagent, let parent = c.parentId, !seen.contains(parent) {
                seen.insert(parent)
                if childRequests[parent] != .pendingApproval { childRequests[parent] = request }
                current = shell[parent]
            }
        }
        // Only write where it changed: rewriting all ~400 structs per update was measurable.
        for (id, request) in childRequests where shell[id]?.childRequest != request { shell[id]?.childRequest = request }
        for (id, t) in shell where t.childRequest != nil && childRequests[id] == nil { shell[id]?.childRequest = nil }

        let candidates = shell.values.filter {
            !$0.isChild && !$0.archived && !$0.deleted && !$0.isShownUnderParent(delegatingParent(of: $0))
        }
        // Sorted into T3's shelves. Snoozed threads stay out of sight until they wake (or raise
        // their hand, which wakes them); settled ones only count if they need you.
        let now = Date()
        var summary = NotchSummary()
        var waiting: [ShellThread] = [], busy: [ShellThread] = [], awake: [ShellThread] = []
        for t in candidates {
            let shelf = t.shelf(now: now)
            if shelf == .snoozed { summary.snoozed += 1; continue }
            awake.append(t)
            if shelf == .settled { summary.settled += 1 }
            if t.status.isBusy { summary.working += 1; busy.append(t); continue }
            // Settled threads only come back for a question (approvals, input, guest messages).
            let kind = NotchSummary.kind(of: t.status)
            guard kind != nil, shelf == .inbox || kind == .question else { continue }
            summary.add(t.status)
            waiting.append(t)
        }
        // Most urgent first (questions, plans, failures, then finishes), newest first within each.
        func rank(_ s: ThreadStatus) -> Int {
            switch NotchSummary.kind(of: s) {
            case .question?: 0
            case .plan?: 1
            case .failed?: 2
            default: 3
            }
        }
        func newest(_ a: ShellThread, _ b: ShellThread) -> Bool {
            a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.id < b.id
        }
        let inbox = waiting.sorted { rank($0.status) != rank($1.status) ? rank($0.status) < rank($1.status) : newest($0, $1) }
        // Busy threads stream updates constantly, so ordering them by `updatedAt` makes them
        // reshuffle. Order by when their run started instead (stable).
        func started(_ t: ShellThread) -> Date { t.startedAt ?? t.updatedAt }
        let working = busy.sorted { started($0) != started($1) ? started($0) > started($1) : $0.id < $1.id }
        detectTransitions(awake)
        checkEventRead()
        checkEventSettled()
        let listed = Array(inbox.prefix(Self.inboxCount))
        var visible = listed + working.prefix(Self.busyCount)
        // A pop-up's thread stays followed until it goes away, even if it's no row: a finish you
        // already saw in T3 (or never opened) resolves to idle, but still gets its few seconds.
        // Same for a finish that's waiting for T3's receipt, so it has a row when it shows.
        for id in [eventId, heldFinishId].compactMap({ $0 })
        where !visible.contains(where: { $0.id == id }) {
            if let t = awake.first(where: { $0.id == id }) { visible.append(t) }
        }

        syncDetailSubscriptions(Set(visible.map(\.id)))
        fetchEditCounts(visible)

        var rows = visible.map(row)
        var listedIds = Set(listed.map(\.id))
        if !Self.demo.threads.isEmpty {
            // Demo shows only fake threads, so screenshots never include real work.
            rows = Self.demo.threads
            summary = NotchSummary(snoozed: 2, settled: 14)
            let awake = rows.filter { !$0.settled } // settled demo rows count as settled, like real ones
            summary.settled += rows.count - awake.count
            awake.forEach { summary.add($0.status) }
            listedIds = Set(awake.filter { NotchSummary.kind(of: $0.status) != nil }.map(\.id))
            // Once, through the live path: a finish goes back to the pill after 7s, a card can be put away.
            if let id = Self.demo.eventId, threads.isEmpty, let t = rows.first(where: { $0.id == id }) { showEvent(t) }
        }
        if summary != self.summary { self.summary = summary }
        if let path = Self.dumpPath { dump(candidates, now: now, to: path) }
        if listedIds != inboxIds { objectWillChange.send(); inboxIds = listedIds }
        if rows != threads { threads = rows }
    }

    private func row(_ s: ShellThread) -> T3Thread {
        var t = T3Thread(
            id: s.id, title: s.title, project: projectName(s), status: s.status,
            startedAt: s.startedAt, updatedAt: s.updatedAt, runId: s.runId,
            model: s.model.map(Self.prettyModel), provider: s.provider, branch: s.branch, pullRequest: s.pullRequest
        )
        t.pr = s.pr
        t.settled = s.settled
        if s.status == .waiting, s.runtimeStatus == "idle", let done = s.latestRunCompletedAt {
            t.startedAt = done // parked on background work: T3 counts from when the run finished
        }
        t.usageLimited = s.usageLimited
        t.usageLimitResetAt = s.usageLimitResetAt
        guard let items = details[s.id]?.values.sorted(by: { $0.ordinal < $1.ordinal }) else { return t }

        // Finished messages only: a message being streamed changes every few tokens, and each
        // change would republish the list and redraw the notch ~10x/s for a preview nobody sees yet.
        t.lastMessage = items.last {
            $0.type == "assistant_message" && $0.status != "running" && !($0.text ?? "").isEmpty
        }?.text.flatMap(Self.firstLines)
        if let runId = s.runId {
            let run = items.filter { $0.runId == runId }
            t.filesChanged = run.filter { $0.type == "file_change" }.count
            t.toolCalls = run.filter { ["command_execution", "dynamic_tool", "web_search", "subagent"].contains($0.type) }.count
            // The run's checkpoint has the real per-file totals; until it lands, sum live edits.
            if let checkpoint = run.last(where: { $0.type == "checkpoint" && $0.linesAdded != nil }) {
                t.linesAdded = checkpoint.linesAdded ?? 0
                t.linesRemoved = checkpoint.linesRemoved ?? 0
            } else {
                let edits = run.filter { $0.type == "file_change" }
                t.linesAdded = edits.reduce(0) { $0 + ($1.linesAdded ?? 0) }
                t.linesRemoved = edits.reduce(0) { $0 + ($1.linesRemoved ?? 0) }
            }
            if t.status.isBusy {
                t.runningCommandId = run.last { $0.type == "command_execution" && $0.status == "running" }?.id
            }
        }

        if t.status.needsYou, let pendingId = s.pendingRequestId {
            t.request = items.last { $0.requestId == pendingId }.flatMap(Self.pendingRequest)
        }

        let live = t.status.isActive
        if t.status == .waiting, let task = s.waitingOn {
            (t.activity, t.activityIcon) = (task, "hourglass")
        } else if live, let item = items.last(where: { !Self.quietTypes.contains($0.type) }) {
            (t.activity, t.activityIcon) = Self.describe(item)
        } else if let message = t.lastMessage {
            (t.activity, t.activityIcon) = (Self.firstLine(message), "text.bubble")
        }
        return t
    }

    /// The thread that delegated `t` to its machine, if the notch follows that thread's machine.
    private func delegatingParent(of t: ShellThread) -> ShellThread? {
        guard let env = t.delegatedFromEnvironment, let id = t.delegatedFromThread else { return nil }
        if env == local?.environmentId { return shell[id] }
        return remotes[env] == nil ? nil : shell["\(env)/\(id)"]
    }

    /// `T3NOTCH_DUMP=path`: every thread the notch knows (top level), where it put it, and the
    /// summary, as JSON, for checking the notch against T3's own lists.
    private static let dumpPath = ProcessInfo.processInfo.environment["T3NOTCH_DUMP"]

    private func dump(_ threads: [ShellThread], now: Date, to path: String) {
        let rows: [[String: Any]] = threads.map { t in
            let slash = t.id.firstIndex(of: "/")
            let shelf = t.shelf(now: now)
            return [
                "environment": slash.map { String(t.id[..<$0]) } ?? (local?.environmentId ?? ""),
                "id": slash.map { String(t.id[t.id.index(after: $0)...]) } ?? t.id,
                "title": t.title,
                "status": t.status.label.isEmpty ? "idle" : t.status.label,
                "shelf": "\(shelf)",
                "working": shelf != .snoozed && t.status.isBusy,
            ]
        }
        let s = summary
        let json: [String: Any] = [
            "connected": allConnections.map { ["environment": $0.environmentId ?? "", "label": $0.label, "connected": $0.connected] },
            "summary": ["working": s.working, "questions": s.questions, "plans": s.plans, "failed": s.failed,
                        "done": s.done, "snoozed": s.snoozed, "settled": s.settled],
            "threads": rows,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// The project, and for another machine's thread, which machine ("api · MacBook Air").
    private func projectName(_ s: ShellThread) -> String {
        let project = projects[s.projectId] ?? ""
        guard let slash = s.id.firstIndex(of: "/"), let machine = remotes[String(s.id[..<slash])]?.label,
              !machine.isEmpty else { return project }
        return project.isEmpty ? machine : "\(project) · \(machine)"
    }

    /// Live "+N −M" before the run's checkpoint lands. The server strips the patch (`diffStr`)
    /// from file edits in every response, so read just that field from T3's local database,
    /// read-only, by item id. If T3 changes its storage this quietly yields nothing and the
    /// exact numbers still arrive with the checkpoint when the run ends.
    private func fetchEditCounts(_ visible: some Sequence<ShellThread>) {
        var wanted: [String: String] = [:] // itemId -> threadId
        for thread in visible {
            // T3's database here only has this Mac's threads.
            guard !thread.id.contains("/") else { continue }
            guard let runId = thread.runId, let items = details[thread.id]?.values else { continue }
            let run = items.filter { $0.runId == runId }
            if run.contains(where: { $0.type == "checkpoint" && $0.linesAdded != nil }) { continue }
            for edit in run where edit.type == "file_change" && edit.linesAdded == nil
                && edit.status == "completed" && !fetchedEdits.contains(edit.id) {
                wanted[edit.id] = thread.id
            }
        }
        guard !wanted.isEmpty else { return }
        fetchedEdits.formUnion(wanted.keys)
        let ids = Array(wanted.keys)
        Task {
            let counts = await Task.detached { EditStats.lineCounts(itemIds: ids) }.value
            for (itemId, (added, removed)) in counts {
                guard let threadId = wanted[itemId], details[threadId]?[itemId] != nil else { continue }
                details[threadId]?[itemId]?.linesAdded = added
                details[threadId]?[itemId]?.linesRemoved = removed
            }
            if !counts.isEmpty { scheduleRecompute() }
        }
    }

    // MARK: Live command output

    /// Stream the running command of `threadId` (nil stops). One stream at a time.
    func watchOutput(of threadId: String?) {
        let itemId = threadId.flatMap { id in threads.first { $0.id == id }?.runningCommandId }
        if let w = outputWatch, w.threadId == threadId, w.itemId == itemId { return }
        if let w = outputWatch {
            w.conn.sendRaw(["_tag": "Interrupt", "requestId": w.requestId, "interruptors": [] as [Any]])
            outputWatch = nil
        }
        guard let threadId, let itemId, let (conn, id) = route(threadId),
              conn.commandOutputStreaming, conn.isOpen else { return }
        outputText = ""
        let requestId = conn.send(tag: "orchestration.subscribeCommandOutput",
                                  payload: ["threadId": id, "itemId": itemId])
        outputWatch = (threadId, itemId, requestId, conn)
    }

    /// Terminal text -> last `n` visible lines: strip ANSI escapes, honor carriage returns.
    nonisolated static func tailLines(_ text: String, _ n: Int) -> [String] {
        let plain = text
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
        // Swift's isNewline also matches a lone "\r", which terminals use to *overwrite* a line
        // (progress bars). So split on real newlines only, then keep what follows the last "\r".
        let lines = plain.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in line.components(separatedBy: "\r").last ?? "" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(lines.suffix(n))
    }

    private static func pendingRequest(_ item: TurnItem) -> PendingRequest? {
        guard let id = item.requestId else { return nil }
        switch item.type {
        case "approval_request":
            let options = item.approvalOptions.isEmpty
                ? [ApprovalOption(decision: "decline", label: "Deny", warning: nil),
                   ApprovalOption(decision: "accept", label: "Approve", warning: nil)]
                : item.approvalOptions
            return .init(id: id, kind: .approval(prompt: item.prompt, reason: item.reason, options: options))
        case "user_input_request":
            return .init(id: id, kind: .questions(item.questions))
        default:
            return nil
        }
    }

    /// Fake threads for checking layouts without waiting for real events:
    /// `T3NOTCH_DEMO=approval|question|finished|settled|list` (list: PR markers, usage limit, every status),
    /// one per pill message: `working|done|failed|plan|asked-done`, and any mix with `counts:w6,d1,q1`.
    private static let demo: (threads: [T3Thread], eventId: String?) = {
        guard let mode = ProcessInfo.processInfo.environment["T3NOTCH_DEMO"] else { return ([], nil) }
        func make(_ id: String, _ title: String, _ status: ThreadStatus, started: Double = -200, updated: Double = -30) -> T3Thread {
            T3Thread(id: id, title: title, project: "custom-dock", status: status,
                     startedAt: Date().addingTimeInterval(started), updatedAt: Date().addingTimeInterval(updated),
                     model: "Opus 5.5", branch: "main")
        }
        switch mode {
        case "approval", "question":
            var t = make("demo", "Clean up old build artifacts", mode == "question" ? .awaitingInput : .pendingApproval)
            t.activity = "Waiting for your answer"
            t.activityIcon = "questionmark.bubble"
            t.request = mode == "question"
                ? .init(id: "demo", kind: .questions([Question(
                    id: "q", header: "Scope", text: "How far should the cleanup go? The build folder alone is 2 GB, /tmp also has old test fixtures.",
                    options: [.init(label: "Build folders only", value: "a", description: nil),
                              .init(label: "Everything in /tmp", value: "b", description: nil),
                              .init(label: "Skip it", value: "c", description: nil)],
                    multiSelect: false)]))
                : .init(id: "demo", kind: .approval(
                    prompt: "rm -rf .build BetterT3Notch.app && swift build -c release",
                    reason: "This command deletes files and could not be checked",
                    options: [.init(decision: "decline", label: "Decline", warning: nil),
                              .init(decision: "accept", label: "Approve", warning: nil)]))
            return ([t], "demo")
        case "finished":
            var t = make("demo", "Ship the notch performance pass", .completed)
            t.lastMessage = "Done. CPU is down from 12–15% to under 1% while threads run, SwiftUI is gone, and the springs are back on Core Animation. 33 tests pass."
            t.activity = t.lastMessage
            t.linesAdded = 812; t.linesRemoved = 431
            return ([t], "demo")
        case "settled": // an agent merged its own PR, then finished
            var t = make("demo", "Ship the notch performance pass", .completed)
            t.lastMessage = "Merged #42. CPU is down from 12–15% to under 1% while threads run. 33 tests pass."
            t.activity = t.lastMessage
            t.pr = PullRequestInfo(number: 42, url: "", state: "merged", isDraft: false,
                                   checks: .passing, review: .approved, conflicting: false)
            t.settled = true
            return ([t], "demo")
        case "working":
            let ts = (1...5).map { i -> T3Thread in
                var t = make("w\(i)", "Working thread \(i)", .working, started: Double(-60 * i))
                t.provider = "claudeAgent"
                return t
            }
            return (ts, nil)
        case "done", "failed", "plan":
            let status: ThreadStatus = mode == "done" ? .completed : mode == "failed" ? .failed : .planReady
            var t = make("d1", "Release notes for 2.4", status, updated: -120)
            t.provider = "claudeAgent"
            t.activity = mode == "plan" ? "Plan ready: 6 steps, starting with the empty states"
                : mode == "failed" ? "Tests failed: 3 of 412 in checkout" : "Drafted the notes and opened the PR."
            var w = make("w1", "Add dark mode to the dashboard", .working, started: -95)
            w.provider = "codex"
            return ([t, w], nil)
        case "asked-done": // a question whose card was put away, and a finished run
            var q = make("q1", "Clean up old build artifacts", .pendingApproval, updated: -40)
            q.provider = "claudeAgent"
            q.activity = "rm -rf .build BetterT3Notch.app"; q.activityIcon = "questionmark.bubble"
            q.request = .init(id: "demo", kind: .approval(prompt: "rm -rf .build BetterT3Notch.app", reason: nil,
                                                          options: [.init(decision: "decline", label: "Decline", warning: nil),
                                                                    .init(decision: "accept", label: "Approve", warning: nil)]))
            var d = make("d1", "Release notes for 2.4", .completed, updated: -300)
            d.provider = "codex"
            d.activity = "Drafted the notes and opened the PR."
            var w = make("w1", "Add dark mode to the dashboard", .working, started: -95)
            w.provider = "claudeAgent"
            return ([q, d, w], nil)
        case "list":
            var a = make("d1", "Fix checkout flow regression", .working, started: -754)
            a.provider = "codex"; a.model = "GPT-5.3 Codex"
            a.activity = "$ pnpm test --filter checkout"; a.activityIcon = "terminal"
            a.linesAdded = 128; a.linesRemoved = 37; a.toolCalls = 22
            a.pr = PullRequestInfo(number: 212, url: "", state: "open", isDraft: false,
                                   checks: .failing, review: .changesRequested, conflicting: true)
            var b = make("d2", "Upgrade auth library", .waiting, started: -1960)
            b.provider = "cursor"; b.model = "Composer 2"
            b.activity = "Subagent: audit session handling"; b.activityIcon = "person.2"
            b.pr = PullRequestInfo(number: 208, url: "", state: "open", isDraft: true,
                                   checks: .pending, review: .reviewRequired, conflicting: false)
            var c = make("d3", "Release notes for 2.4", .completed, updated: -300)
            c.provider = "claudeAgent"
            c.activity = "Drafted the notes and opened the PR."
            c.linesAdded = 64; c.linesRemoved = 3
            c.pr = PullRequestInfo(number: 205, url: "", state: "open", isDraft: false,
                                   checks: .passing, review: .approved, conflicting: false)
            var d = make("d4", "Migrate billing to the new API", .failed, updated: -5400)
            d.provider = "grok"; d.model = "Grok 5"
            d.usageLimited = true; d.usageLimitResetAt = Date().addingTimeInterval(72 * 60)
            var e = make("d5", "Plan the onboarding redesign", .planReady, updated: -900)
            e.provider = "opencode"; e.model = "Kimi K3"
            e.activity = "Plan ready: 6 steps, starting with the empty states"
            var f = make("d6", "Add dark mode to the dashboard", .working, started: -95)
            f.provider = "claudeAgent"
            f.activity = "Editing ThemeProvider.tsx"; f.activityIcon = "pencil"
            f.linesAdded = 37; f.linesRemoved = 12; f.toolCalls = 9
            return ([f, a, b, c, d, e], nil)
        default:
            // `counts:w6,d1,q1`: any mix for the collapsed pill. w working, q question, a approval,
            // p plan ready, f failed, d done.
            guard mode.hasPrefix("counts:") else { return ([], nil) }
            let statuses: [Character: ThreadStatus] = ["w": .working, "q": .awaitingInput, "a": .pendingApproval,
                                                       "p": .planReady, "f": .failed, "d": .completed]
            var ts: [T3Thread] = []
            for part in mode.dropFirst("counts:".count).split(separator: ",") {
                guard let letter = part.first, let status = statuses[letter], let n = Int(part.dropFirst()), n > 0 else { continue }
                for i in 0..<n {
                    var t = make("\(letter)\(i)", "Demo thread \(letter)\(i + 1)", status, started: Double(-60 * (i + 1)))
                    t.provider = "claudeAgent"
                    ts.append(t)
                }
            }
            return (ts, nil)
        }
    }()

    private static let quietTypes: Set<String> = ["checkpoint", "user_message", "notification", "system_notice"]

    private static func describe(_ item: TurnItem) -> (String?, String) {
        switch item.type {
        case "command_execution": (item.input.flatMap(firstLine).map { "$ \($0)" }, "terminal")
        case "file_change": (item.fileName.map { "Editing \(($0 as NSString).lastPathComponent)" }, "pencil")
        case "dynamic_tool": (item.title ?? item.toolName, "wrench.and.screwdriver")
        case "web_search": ("Searching the web", "globe")
        case "reasoning": ("Thinking…", "brain")
        case "subagent": (item.title.map { "Subagent: \($0)" } ?? "Running a subagent", "person.2")
        case "approval_request", "user_input_request", "secret_request":
            (item.question.flatMap(firstLine) ?? "Waiting for your answer", "questionmark.bubble")
        case "assistant_message":
            // While streaming, the first line grows token by token; don't redraw for each one.
            (item.status == "running" ? "Writing…" : item.text.flatMap(firstLine), "text.bubble")
        default: (item.title, "sparkles")
        }
    }

    private func syncDetailSubscriptions(_ wanted: Set<String>) {
        for conn in allConnections where conn.isOpen {
            for (threadId, requestId) in conn.threadRequests where !wanted.contains(key(threadId, conn)) {
                let k = key(threadId, conn)
                conn.sendRaw(["_tag": "Interrupt", "requestId": requestId, "interruptors": [] as [Any]])
                conn.threadRequests[threadId] = nil
                conn.requestThreads[requestId] = nil
                if let ids = details.removeValue(forKey: k)?.keys { fetchedEdits.subtract(ids) }
                commandOutput[k] = nil
                failed[k] = nil
            }
        }
        for k in wanted {
            guard let (conn, threadId) = route(k), conn.isOpen, conn.threadRequests[threadId] == nil else { continue }
            log.notice("subscribe thread \(k, privacy: .public)")
            let requestId = conn.send(tag: "orchestration.subscribeThread",
                                      payload: ["threadId": threadId, "acceptBoundedSnapshot": true])
            conn.threadRequests[threadId] = requestId
            conn.requestThreads[requestId] = threadId
        }
    }

    /// Sounds and pop-ups follow the *run*, not the pill: T3 hides "Completed" once you've
    /// looked at a thread, but a run you're watching finishing still deserves its click.
    private func detectTransitions(_ threads: [ShellThread]) {
        let now = Dictionary(threads.map { ($0.id, $0.phase) }, uniquingKeysWith: { a, _ in a })
        let prs = Dictionary(threads.compactMap { t in t.pr.map { (t.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let firstLoad = lastPhases.isEmpty
        let fresh = freshSnapshots
        defer {
            lastPhases = now
            lastPRs = prs
            limitChimed.formIntersection(now.keys) // forget threads that are gone
            freshSnapshots = []
        }
        guard !firstLoad else { return } // first snapshot: no peeks
        /// A thread we first hear of in a server's snapshot (another machine coming online, or
        /// this one back after a while) is how things stand, not something that just happened.
        func isNew(_ id: String) -> Bool {
            guard lastPhases[id] == nil else { return false }
            guard let slash = id.firstIndex(of: "/") else { return fresh.contains("") }
            return fresh.contains(String(id[..<slash]))
        }

        // PR news: checks went red, or a review decision arrived.
        for (id, pr) in prs where !isNew(id) {
            let before = lastPRs[id]
            if pr.checks == .failing && before?.checks != .failing {
                log.notice("checks failing: \(id, privacy: .public)")
                if Settings.sound(.pullRequest) { Chime.shared.play(.failed) }
            } else if pr.review != nil && pr.review != .reviewRequired && pr.review != before?.review {
                log.notice("review: \(id, privacy: .public)")
                if Settings.sound(.pullRequest) { Chime.shared.play(.needsYou) }
            }
        }

        // The "needs you" card goes away by itself once the request is answered (here or in T3).
        if let id = eventId, lastPhases[id] == .needsYou, now[id] != .needsYou {
            dismissEvent()
        }

        for (id, phase) in now where !isNew(id) {
            let before = lastPhases[id]
            let wasActive = before == .active || before == .needsYou
            // Already seen in T3 Code (its receipt came in the same update): the sound, no card.
            func seen(_ after: Date?) -> Bool {
                guard let after, let t = shell[id] else { return false }
                return t.isRead(after: after) && Self.t3InFront
            }
            switch phase {
            case .needsYou where before != .needsYou:
                let after = shell[id]?.readAfter
                if !seen(after) { show(id, .needsYou, for: nil, readAfter: after) } // sticky until answered or seen
                log.notice("needs you: \(id, privacy: .public)")
                if Settings.sound(.needsYou) { Chime.shared.play(.needsYou) }
                return
            case .completed where wasActive, .failed where wasActive:
                let after = shell[id]?.readAfter
                let kind: EventKind = phase == .failed ? .failed : .done
                if seen(after) {
                    // Watched it finish in T3 Code.
                } else if Self.t3InFront {
                    holdFinish(id, kind, readAfter: after)
                } else {
                    show(id, kind, for: 7, readAfter: after)
                }
                log.notice("\(phase == .failed ? "failed" : "done", privacy: .public): \(id, privacy: .public)")
                if Settings.sound(phase == .failed ? .failed : .done) { Chime.shared.play(phase == .failed ? .failed : .done) }
                return
            default:
                continue
            }
        }
    }

    // MARK: Read in T3 Code

    static let t3BundleId = "com.t3tools.t3code"
    static var t3InFront: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == t3BundleId }

    /// Opened in T3 Code (here, there, or already open): put the pop-up away. A "needs you" card
    /// shrinks to its island; a finish closes.
    private func checkEventRead() {
        // A finish still held for its receipt: seen in T3 Code now, so it never shows.
        if let id = heldFinishId, Self.t3InFront, let t = shell[id], let after = t.readAfter, t.isRead(after: after) {
            log.notice("seen in T3 while held: \(id, privacy: .public)")
            cancelHeldFinish()
        }
        guard let id = eventId, let after = eventReadAfter, let t = shell[id], t.isRead(after: after) else { return }
        if Self.t3InFront {
            log.notice("seen in T3: \(id, privacy: .public)")
            dismissEvent()
        } else {
            eventReadAway = true
        }
    }

    /// T3 Code is in front, maybe on this very thread: its receipt usually lands well within
    /// this beat (it sends one at once for an unseen finish), so the card doesn't flash open.
    private func holdFinish(_ id: String, _ kind: EventKind, readAfter: Date?) {
        heldFinish?.cancel()
        heldFinishId = id
        heldFinish = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled else { return }
            self.heldFinishId = nil
            // Gone, or already running again (a queued follow-up): nothing finished to show.
            guard let t = self.shell[id], t.phase == .completed || t.phase == .failed else { return }
            if let after = readAfter, t.isRead(after: after), Self.t3InFront { return }
            self.show(id, kind, for: 7, readAfter: readAfter)
        }
    }

    private func cancelHeldFinish() {
        heldFinish?.cancel()
        heldFinishId = nil
    }

    /// Click once when a usage-limited thread's limit resets (checked by the store's timer).
    private func checkLimitResets() {
        let now = Date()
        for t in threads where t.usageLimited {
            guard let reset = t.usageLimitResetAt, reset <= now, !limitChimed.contains(t.id) else { continue }
            limitChimed.insert(t.id)
            log.notice("limit reset: \(t.id, privacy: .public)")
            if Settings.sound(.limitReset) { Chime.shared.play(.done) }
        }
    }

    private func show(_ id: String, _ kind: EventKind, for seconds: Double?, readAfter: Date?) {
        eventKind = kind
        cancelHeldFinish()
        eventId = id
        eventReadAfter = readAfter
        eventReadAway = false
        eventShownAt = Date()
        eventSettled = seconds != nil && settlesCard(id)
        // Settled as it finished: the check, the box, then gone, without the full 7s.
        let after = eventSettled ? seconds.map { min($0, Self.settledCardSeconds) } : seconds
        eventDeadline = after.map { Date().addingTimeInterval($0) }
        clearEvent(after: after)
    }

    /// Once the box is in: just long enough to see it land.
    static let settledLinger = 1.1
    /// The check draws and sits, turns into the box, then a short beat and gone.
    static let settledCardSeconds = CheckBadge.settleSwap + settledLinger
    private var eventShownAt = Date.distantPast
    /// When the card closes on its own; settling only ever brings it closer.
    private var eventDeadline: Date?

    /// A finish card whose thread settles while it's up: it files itself away and goes early.
    private func checkEventSettled() {
        guard let id = eventId, !eventSettled, eventClearTask != nil, settlesCard(id) else { return }
        log.notice("settled while shown: \(id, privacy: .public)")
        eventSettled = true
        // The swap waits for the check's moment if the card only just opened.
        let untilSwap = max(0, CheckBadge.settleSwap - Date().timeIntervalSince(eventShownAt))
        var after = untilSwap + Self.settledLinger
        if let deadline = eventDeadline { after = min(after, max(0, deadline.timeIntervalSinceNow)) }
        eventDeadline = Date().addingTimeInterval(after)
        clearEvent(after: after)
    }

    /// Only a plain finish settles its card: a failure, a plan or a question still wants you.
    private func settlesCard(_ id: String) -> Bool {
        guard eventKind == .done || eventKind == .forced else { return false }
        let done: (Bool, ThreadStatus)? = shell[id].map { ($0.settled && $0.phase == .completed, $0.status) }
            ?? Self.demo.threads.first { $0.id == id }.map { ($0.settled, $0.status) }
        guard let (settled, status) = done else { return false }
        return settled && (status == .completed || status == .idle)
    }

    private func clearEvent(after seconds: Double?) {
        eventClearTask?.cancel()
        eventClearTask = nil
        guard let seconds else { return }
        eventClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismissEvent()
        }
    }

    // MARK: Helpers

    private static func firstLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// Message text flattened to a short paragraph (markdown noise stripped).
    nonisolated static func firstLines(_ s: String) -> String {
        var inCode = false
        let lines = s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                if line.hasPrefix("```") { inCode.toggle(); return false } // whole code blocks, not just fences
                return !inCode && !line.isEmpty && !line.hasPrefix("|")
            }
            // Headings and bullets: keep the words, drop the markers.
            .map { $0.replacingOccurrences(of: #"^(#{1,6}|[-*+])\s+"#, with: "", options: .regularExpression) }
        return lines.prefix(3).joined(separator: " ")
            // [text](url) -> text: a link is read, not clicked, here (and on the Lock Screen).
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)\s]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    /// "claude-opus-5-5" -> "Opus 5.5"; anything else is shown as-is.
    private static func prettyModel(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        let parts = id.dropFirst(7).split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    private static var userdata: URL {
        URL(fileURLWithPath: NSString(string: "~/.t3/userdata").expandingTildeInPath)
    }

    /// Where the running server listens, from the file it writes on startup.
    private static func serverOrigin() -> URL? {
        let file = ProcessInfo.processInfo.environment["T3NOTCH_RUNTIME_FILE"].map { URL(fileURLWithPath: $0) }
            ?? userdata.appendingPathComponent("server-runtime.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let origin = json["origin"] as? String else { return nil }
        if let pid = json["pid"] as? Int32, kill(pid, 0) != 0, errno == ESRCH { return nil } // stale file
        return URL(string: origin)
    }

    /// Orchestration protocol this client speaks (`ORCHESTRATION_PROTOCOL_VERSION` in t3code contracts).
    nonisolated static let protocolVersion = 2

    private enum ConnectError: Error { case serverDown, noToken, incompatible }
}

// MARK: - Connection events

extension ThreadStore: ConnectionDelegate {
    func connectionDidOpen(_ connection: Connection) {
        // Fresh thread snapshots drop fetched counts; fetch again.
        if connection.remoteId == nil { fetchedEdits = [] }
    }

    func connection(_ connection: Connection, received incoming: Incoming) {
        handle(incoming, from: connection)
        updateConnected()
    }

    func connectionDidDrop(_ connection: Connection, status: Int?) {
        if status == 401 || status == 403 { // revoked or expired: mint a new one
            if let id = connection.remoteId { remoteTokens.discard(id) } else { auth.discard() }
        }
        if status == 426, connection.remoteId == nil { // orchestration_protocol_incompatible
            incompatible = "T3 Code needs a newer orchestration protocol than \(Self.protocolVersion)"
        }
        // Their answers are lost with the socket: stop the spinners.
        connection.commandThreads.values.forEach { sending.remove($0) }
        connection.commandThreads = [:]
        if let watch = outputWatch, watch.conn === connection { outputWatch = nil }
        updateConnected()
        watchForStaleThreads(connection)
    }

    /// Don't leave "running" threads on screen if a server went away for good. Short blips
    /// (server restart, sleep/wake) get 6 s to come back; a server that answers but is still
    /// sending its snapshot keeps its last-known threads longer (no flicker after every wake),
    /// but never past 100 s: by then the connection has given up on that socket at least once.
    private func watchForStaleThreads(_ connection: Connection) {
        let id = ObjectIdentifier(connection)
        guard staleWatches.insert(id).inserted else { return }
        Task {
            defer { staleWatches.remove(id) }
            while true {
                try? await Task.sleep(for: .seconds(2))
                // Current again, or no longer the connection for that machine (unlinked or replaced).
                guard !connection.connected, let since = connection.downSince,
                      connection.remoteId.map({ remotes[$0] === connection }) ?? true else { return }
                let down = Date().timeIntervalSince(since)
                if down > 100 || (down > 6 && !connection.answering) {
                    dropThreads(of: connection)
                    return
                }
            }
        }
    }
}

// MARK: - Auth token

/// A read-only (`orchestration:read`) bearer token minted with T3's own CLI
/// (`t3 auth session issue`), cached in Application Support with 0600 permissions.
@MainActor
final class TokenStore {
    private var cached: String?
    private var lastMint = Date.distantPast

    /// Bump when the scopes change so an older, narrower token isn't reused.
    nonisolated private static let scopes = ["orchestration:read", "orchestration:operate"]

    private var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterT3Notch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("token-operate")
    }

    func token() async throws -> String? {
        if let cached { return cached }
        if let saved = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            cached = saved
            return saved
        }
        // Don't spam new sessions if something is persistently wrong.
        guard Date().timeIntervalSince(lastMint) > 60 else { return nil }
        lastMint = Date()
        guard let minted = await Self.mint() else { return nil }
        FileManager.default.createFile(atPath: file.path, contents: Data(minted.utf8),
                                       attributes: [.posixPermissions: 0o600])
        cached = minted
        return minted
    }

    func discard() {
        cached = nil
        try? FileManager.default.removeItem(at: file)
    }

    private static func mint() async -> String? {
        await Task.detached {
            let cli = NSString(string: "~/.t3/bin/t3").expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: cli) else { return nil }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["auth", "session", "issue"]
                + TokenStore.scopes.flatMap { ["--scope", $0] }
                + ["--ttl", "30d", "--label", "Better T3 Notch", "--token-only"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty || token.contains(" ") ? nil : token
        }.value
    }
}

// MARK: - Wire format (Effect RPC, JSON)

enum RunPhase: Sendable { case active, needsYou, completed, failed, other }

struct ShellThread: Sendable {
    /// The store's keys: the server's own ids, prefixed "<environmentId>/" for another machine.
    private(set) var id: String
    let title: String
    private(set) var projectId: String
    let startedAt: Date?
    let updatedAt: Date
    let runId, model, branch, pullRequest, pendingRequestId: String?
    var provider: String?
    let isChild, archived, deleted: Bool
    private(set) var parentId: String?
    let isSubagent: Bool
    /// The thread (on any machine) that delegated this one, which T3 lists it under.
    var delegatedFromEnvironment, delegatedFromThread: String?
    /// What this thread asks its parent for, if it's a live app-owned subagent with a request.
    let subagentRequest: ThreadStatus?
    /// T3's pill inputs (see `presentThreadShell` / `shellRuntime` in client-runtime models.ts).
    let hasPendingApprovals, hasPendingUserInput: Bool
    let runtimeStatus: String?
    let latestRunStatus: String?
    let latestRunCompletedAt: Date?
    let lastVisitedAt: Date?
    let blockedOnThreadWait, backgroundHoldsCompletion, planMode, hasActionableProposedPlan: Bool
    /// Guest messages waiting for the owner to send or dismiss (newer servers).
    let pendingGuestMessages: Int
    /// What a parked thread is waiting on ("Wait for Vercel web deploy").
    let waitingOn: String?
    let pr: PullRequestInfo?
    /// T3 keeps status "failed" for usage limits; the class says why.
    let usageLimited: Bool
    let usageLimitResetAt: Date?
    /// T3's sidebar shelves: settled by the user or auto-settle, or snoozed until a time.
    /// "settled" or "active" (the keep-active pin), or nil to let auto-settle decide.
    var settledOverride: String?
    /// Pinned threads never settle (they stay on top of T3's sidebar).
    var pinned = false
    var snoozedUntil: Date?
    var snoozedAt: Date?
    var pendingKind: String?
    var pendingCreatedAt: Date?
    /// Set by the store from children's requests.
    var childRequest: ThreadStatus? {
        didSet { if childRequest != oldValue { status = resolveStatus() } }
    }
    /// Cached: sorting ~400 threads reads it thousands of times per update.
    private(set) var status: ThreadStatus = .idle

    /// `resolveThreadStatusPill`, in the same order.
    func resolveStatus() -> ThreadStatus {
        if hasPendingApprovals || childRequest == .pendingApproval { return .pendingApproval }
        if hasPendingUserInput || childRequest == .awaitingInput { return .awaitingInput }
        if pendingGuestMessages > 0 { return .guestRequest }
        if (runtimeStatus == "running" && !blockedOnThreadWait) || runtimeStatus == "waiting" { return .working }
        if ["preparing", "starting", "queued"].contains(runtimeStatus) { return .connecting }
        if (runtimeStatus == "running" && blockedOnThreadWait) || backgroundHoldsCompletion { return .waiting }
        if latestRunStatus == "failed", lastVisitedAt.map({ v in latestRunCompletedAt.map { $0 > v } ?? true }) ?? true {
            return .failed
        }
        if planMode && runSettled && hasActionableProposedPlan { return .planReady }
        if let done = latestRunCompletedAt, let seen = lastVisitedAt, done > seen { return .completed }
        return .idle
    }

    mutating func refreshStatus() { status = resolveStatus() }

    /// T3 lists work delegated from a thread it can see (here or on another machine) under that
    /// thread, not on its own; the parent reads as Waiting meanwhile. A delegated task that
    /// needs you stays on its own, so its question never goes unseen.
    func isShownUnderParent(_ parent: ShellThread?) -> Bool {
        guard let parent, !parent.archived, !parent.deleted else { return false }
        return NotchSummary.kind(of: status) != .question // approvals, input, guest messages
    }

    /// The same thread, with its ids keyed for another machine (nil: this Mac, unchanged).
    func namespaced(_ environmentId: String?) -> ShellThread {
        guard let environmentId else { return self }
        var t = self
        t.id = "\(environmentId)/\(id)"
        t.projectId = "\(environmentId)/\(projectId)"
        t.parentId = parentId.map { "\(environmentId)/\($0)" }
        return t
    }

    /// When T3 Code counts the pop-up as seen: once its read receipt (`lastVisitedAt`) reaches
    /// this. T3 stamps a visit with the thread's `updatedAt`, which every event moves, so a
    /// receipt for a look from before the request (or the finish) is always earlier.
    var readAfter: Date? {
        switch phase {
        // T3's own unread rule: a finish is read once a visit reaches its completion.
        case .completed, .failed: latestRunCompletedAt
        // A request that's only a subagent's leaves this thread's `updatedAt` alone: no receipt.
        case .needsYou where hasPendingApprovals || hasPendingUserInput || pendingGuestMessages > 0:
            pendingCreatedAt ?? updatedAt
        default: nil
        }
    }

    func isRead(after: Date) -> Bool { lastVisitedAt.map { $0 >= after } ?? false }

    private var runSettled: Bool {
        !["preparing", "starting", "running", "waiting", "queued"].contains(runtimeStatus ?? "")
    }

    enum Shelf: Sendable { case inbox, snoozed, settled }

    /// `effectiveSettled` (threadSettled.ts): blocked or running work stays out; then the user's
    /// override; then a merged or closed PR settles it. T3 works the PR rule out on the fly and
    /// never stores it, so an agent that merges its own PR settles the thread with no override.
    /// (T3's "settle after N days" setting lives in the app, out of the notch's reach.)
    var settled: Bool {
        if pinned { return false }
        if hasPendingApprovals || hasPendingUserInput { return false }
        // T3 blocks a live session; "preparing", "waiting" and "queued" are the notch's names
        // for parts of one, so they keep it out too (the safe side: it stays visible).
        if ["preparing", "starting", "running", "waiting", "queued"].contains(runtimeStatus ?? "") { return false }
        // Parked on awaited background work: the runtime reads idle, but the run isn't over.
        if backgroundHoldsCompletion || blockedOnThreadWait { return false }
        if settledOverride == "settled" { return true }
        if settledOverride == "active" { return false }
        return pr?.state == "merged" || pr?.state == "closed"
    }

    /// Where T3's sidebar puts it: snoozed outranks settled, everything else is the inbox.
    func shelf(now: Date) -> Shelf {
        if isSnoozed(now: now) { return .snoozed }
        return settled ? .settled : .inbox
    }

    /// `effectiveSnoozed` (t3code client-runtime threadSettled.ts): until the wake time, unless
    /// the thread raised its hand since it was snoozed.
    func isSnoozed(now: Date) -> Bool {
        guard let until = snoozedUntil, until > now else { return false }
        return !raisedHandWhileSnoozed
    }

    /// `threadRaisedHandWhileSnoozed`: an approval, a *new* question, a subagent's request, a
    /// guest message, or a failure after the snooze. Finishing never wakes it.
    private var raisedHandWhileSnoozed: Bool {
        if let kind = pendingKind, kind != "user_input" { return true }
        if hasPendingUserInput || pendingKind == "user_input" {
            // Snoozing an existing question means "ask me later"; only a newer one wakes it.
            guard let snoozedAt, let asked = pendingCreatedAt, asked <= snoozedAt else { return true }
        }
        if childRequest != nil || pendingGuestMessages > 0 { return true }
        if latestRunStatus == "failed" {
            guard let snoozedAt else { return true }
            if (latestRunCompletedAt ?? updatedAt) > snoozedAt { return true }
        }
        return false
    }

    var phase: RunPhase {
        if status.needsYou { return .needsYou }
        if status.isBusy { return .active }
        if latestRunStatus == "failed" { return .failed }
        if latestRunStatus == "completed" { return .completed }
        return .other
    }
}

struct TurnItem: Sendable {
    let id: String
    let ordinal: Int
    let type: String
    let runId, title, toolName, input, fileName, text, question: String?
    var requestId, prompt, reason: String?
    var status: String?
    /// From `files[].additions/deletions` (checkpoint and file_change items).
    var linesAdded, linesRemoved: Int?
    var approvalOptions: [ApprovalOption] = []
    var questions: [Question] = []
}

enum ShellItem: Sendable {
    case snapshot(threads: [ShellThread], projects: [String: String])
    case projects([String: String])
    case threadUpdated(ShellThread)
    case threadRemoved(String)
}

enum ThreadItem: Sendable {
    case snapshot([TurnItem])
    case turnItem(TurnItem)
}

struct OutputFrame: Sendable {
    let replace: Bool
    let text: String
}

struct StreamValue: Sendable {
    var shell: ShellItem?
    var thread: ThreadItem?
    var output: OutputFrame?
}

enum Incoming: Sendable {
    case chunk(requestId: String, values: [StreamValue])
    case exit(requestId: String, ok: Bool, message: String?)
    case ignored

    static func parse(_ data: Data) -> Incoming? {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let requestId = (msg["requestId"] as? String) ?? (msg["requestId"] as? NSNumber)?.stringValue ?? ""
        switch msg["_tag"] as? String {
        case "Chunk":
            let values = (msg["values"] as? [[String: Any]] ?? []).map { v in
                StreamValue(shell: parseShell(v), thread: parseThread(v), output: parseOutput(v))
            }
            return .chunk(requestId: requestId, values: values)
        case "Exit":
            let exit = msg["exit"] as? [String: Any]
            let ok = exit?["_tag"] as? String == "Success"
            // Failure cause: [{_tag: "Fail", error: {message?...}}]
            let cause = (exit?["cause"] as? [[String: Any]])?.first
            let message = ((cause?["error"] as? [String: Any])?["message"] as? String)
                ?? (cause?["defect"] as? String)
            return .exit(requestId: requestId, ok: ok, message: message)
        default:
            return .ignored
        }
    }

    private static func parseShell(_ v: [String: Any]) -> ShellItem? {
        switch v["kind"] as? String {
        case "snapshot":
            guard let snap = v["snapshot"] as? [String: Any] else { return nil }
            var projects: [String: String] = [:]
            for p in snap["projects"] as? [[String: Any]] ?? [] {
                if let id = p["id"] as? String { projects[id] = p["title"] as? String ?? "" }
            }
            // Metadata-only refreshes (repository identity) carry no thread list.
            if v["resolvedRepositoryIdentityRoots"] != nil { return .projects(projects) }
            let threads = (snap["threads"] as? [[String: Any]] ?? []).compactMap(shellThread)
            return .snapshot(threads: threads, projects: projects)
        case "thread.updated":
            guard let t = (v["thread"] as? [String: Any]).flatMap(shellThread) else { return nil }
            return .threadUpdated(t)
        case "thread.removed":
            return (v["threadId"] as? String).map(ShellItem.threadRemoved)
        case "project.updated":
            guard let p = v["project"] as? [String: Any], let id = p["id"] as? String else { return nil }
            return .projects([id: p["title"] as? String ?? ""])
        default:
            return nil
        }
    }

    private static func parseOutput(_ v: [String: Any]) -> OutputFrame? {
        guard let kind = v["kind"] as? String, kind == "replace" || kind == "append",
              let text = v["text"] as? String else { return nil }
        return OutputFrame(replace: kind == "replace", text: text)
    }

    private static func parseThread(_ v: [String: Any]) -> ThreadItem? {
        switch v["kind"] as? String {
        case "snapshot":
            let items = ((v["projection"] as? [String: Any])?["turnItems"] as? [[String: Any]] ?? [])
                .compactMap(turnItem)
            return .snapshot(items)
        case "event":
            guard let e = v["event"] as? [String: Any], e["type"] as? String == "turn-item.updated",
                  let item = (e["payload"] as? [String: Any]).flatMap(turnItem) else { return nil }
            return .turnItem(item)
        default:
            return nil
        }
    }

    private static func shellThread(_ t: [String: Any]) -> ShellThread? {
        guard let id = t["id"] as? String else { return nil }
        let status = t["status"] as? String ?? "idle"
        let pending = t["pendingRuntimeRequest"] as? [String: Any]
        let pendingKind = pending?["kind"] as? String
        let lineage = t["lineage"] as? [String: Any]
        let isSubagent = lineage?["relationshipToParent"] as? String == "subagent"

        // shellRuntime(): background work that holds the run (see below) parks it at idle;
        // otherwise the activity run's status wins over the latest run's.
        let tasks = t["pendingBackgroundTasks"] as? [[String: Any]] ?? []
        // backgroundWorkHoldsCompletion(): awaited work of any kind, or a subagent or background
        // task. Commands and monitors (a dev server, its watchdog, a PR watch) hold only when
        // the agent marks them awaited, so a thread minding a PR isn't "working" forever.
        // T3 reads a kind it doesn't know as background_task, which holds.
        func holdsCompletion(_ task: [String: Any]) -> Bool {
            task["awaited"] as? Bool == true
                || !["command", "monitor"].contains(task["kind"] as? String ?? "")
        }
        let holds = tasks.contains(where: holdsCompletion)
        let parkAtIdle = holds && status != "failed"
        let hasRuntime = t["latestRunId"] is String || t["activeProviderThreadId"] is String || parkAtIdle
        let runtimeStatus: String? = !hasRuntime ? nil
            : parkAtIdle ? "idle" : (t["activityRunStatus"] as? String ?? status)
        let runtimeWorking = ["preparing", "starting", "running"].contains(runtimeStatus ?? "")

        let hasPendingApprovals = pending != nil && pendingKind != "user_input" && pendingKind != "auth_refresh"
        let hasPendingUserInput = pendingKind == "user_input"
            && ((pending?["blocking"] as? Bool) != false || !runtimeWorking)

        // latestRun as presentThreadShell() builds it.
        let hasLatestRun = t["latestRunId"] is String
        let terminal = ["completed", "failed", "interrupted", "cancelled", "idle"].contains(status)
        let completedAt: Date? = !hasLatestRun ? nil
            : t.keys.contains("latestRunCompletedAt") ? date(t["latestRunCompletedAt"])
            : terminal ? date(t["updatedAt"]) : nil

        // A live app-owned subagent's request surfaces on its parent (provider-native ones ask there already).
        let activity = t["activityRunStatus"]
        let childLive = activity is NSNull ? false
            : activity != nil ? true
            : ["preparing", "starting", "running", "waiting"].contains(status)
        let subagentRequest: ThreadStatus? = {
            guard let kind = pendingKind, kind != "auth_refresh", isSubagent,
                  t["creationSource"] as? String != "provider", childLive else { return nil }
            return kind == "user_input" ? .awaitingInput : .pendingApproval
        }()

        let pr = (t["pullRequests"] as? [[String: Any]])?.last
        let prText = (pr?["number"] as? NSNumber).map { n in
            ((pr?["snapshot"] as? [String: Any])?["state"] as? String).map { "#\(n) \($0)" } ?? "#\(n)"
        }
        var thread = ShellThread(
            id: id,
            title: t["title"] as? String ?? "Untitled",
            projectId: t["projectId"] as? String ?? "",
            startedAt: date(t["activityRunStartedAt"]) ?? date(t["latestRunStartedAt"]),
            updatedAt: date(t["updatedAt"]) ?? .distantPast,
            runId: (t["activeRunId"] as? String) ?? (t["latestRunId"] as? String),
            model: (t["modelSelection"] as? [String: Any])?["model"] as? String,
            branch: t["branch"] as? String,
            pullRequest: prText,
            pendingRequestId: pending?["id"] as? String,
            provider: provider(t),
            // T3's sidebar: forks (and handoffs) are threads of their own; only subagents and
            // side chats live under their parent.
            isChild: lineage?["parentThreadId"] as? String != nil && (isSubagent || lineage?["sideChat"] as? Bool == true),
            archived: t["archivedAt"] is String,
            deleted: t["deletedAt"] is String,
            parentId: lineage?["parentThreadId"] as? String,
            isSubagent: isSubagent,
            delegatedFromEnvironment: (t["delegatedFrom"] as? [String: Any])?["environmentId"] as? String,
            delegatedFromThread: (t["delegatedFrom"] as? [String: Any])?["threadId"] as? String,
            subagentRequest: subagentRequest,
            hasPendingApprovals: hasPendingApprovals,
            hasPendingUserInput: hasPendingUserInput,
            runtimeStatus: runtimeStatus,
            latestRunStatus: hasLatestRun ? (status == "idle" ? "completed" : status) : nil,
            latestRunCompletedAt: completedAt,
            lastVisitedAt: date(t["lastVisitedAt"]),
            blockedOnThreadWait: t["blockedOnThreadWait"] as? Bool ?? false,
            backgroundHoldsCompletion: holds,
            planMode: t["interactionMode"] as? String == "plan",
            hasActionableProposedPlan: t["hasActionableProposedPlan"] as? Bool ?? false,
            pendingGuestMessages: (t["pendingGuestMessageCount"] as? NSNumber)?.intValue ?? 0,
            waitingOn: tasks.first(where: holdsCompletion)?["description"] as? String,
            pr: pullRequest(t),
            usageLimited: status == "failed" && t["lastErrorClass"] as? String == "usage_limit",
            usageLimitResetAt: date(t["usageLimitResetAt"])
        )
        thread.settledOverride = t["settledOverride"] as? String
        thread.pinned = t["pinnedAt"] is String
        thread.snoozedUntil = date(t["snoozedUntil"])
        thread.snoozedAt = date(t["snoozedAt"])
        thread.pendingKind = pendingKind
        thread.pendingCreatedAt = date(pending?["createdAt"])
        thread.refreshStatus()
        return thread
    }

    /// Driver from the provider thread id ("provider-thread:provider:claudeAgent:…"), else
    /// guessed from the model id.
    private static func provider(_ t: [String: Any]) -> String? {
        if let id = t["activeProviderThreadId"] as? String,
           let r = id.range(of: #"provider:([A-Za-z]+):"#, options: .regularExpression) {
            return String(id[r].dropFirst("provider:".count).dropLast())
        }
        let model = ((t["modelSelection"] as? [String: Any])?["model"] as? String ?? "").lowercased()
        if model.hasPrefix("claude") { return "claudeAgent" }
        if model.hasPrefix("gpt") || model.hasPrefix("o3") || model.hasPrefix("o4") || model.contains("codex") { return "codex" }
        if model.hasPrefix("grok") { return "grok" }
        return nil
    }

    /// Latest PR the thread is tracking (stack-dismissed ones are hidden in T3 too).
    private static func pullRequest(_ t: [String: Any]) -> PullRequestInfo? {
        guard let pr = (t["pullRequests"] as? [[String: Any]])?.last(where: { $0["source"] as? String != "stack-dismissed" }),
              let number = (pr["number"] as? NSNumber)?.intValue else { return nil }
        let snap = pr["snapshot"] as? [String: Any]
        return PullRequestInfo(
            number: number,
            url: pr["url"] as? String ?? "",
            state: snap?["state"] as? String ?? "open",
            isDraft: snap?["isDraft"] as? Bool ?? false,
            checks: (snap?["checksState"] as? String).flatMap(PullRequestInfo.Checks.init(rawValue:)),
            review: (snap?["reviewDecision"] as? String).flatMap(PullRequestInfo.Review.init(rawValue:)),
            conflicting: snap?["mergeability"] as? String == "conflicting"
        )
    }

    private static func turnItem(_ i: [String: Any]) -> TurnItem? {
        guard let id = i["id"] as? String else { return nil }
        let question = ((i["questions"] as? [[String: Any]])?.first?["question"] as? String)
            ?? (i["prompt"] as? String) ?? (i["reason"] as? String)
        var item = TurnItem(
            id: id,
            ordinal: (i["ordinal"] as? NSNumber)?.intValue ?? 0,
            type: i["type"] as? String ?? "",
            runId: i["runId"] as? String,
            title: i["title"] as? String,
            toolName: i["toolName"] as? String,
            input: (i["input"] as? String).map { String($0.prefix(300)) },
            fileName: i["fileName"] as? String,
            text: (i["text"] as? String).map { String($0.prefix(1200)) },
            question: question
        )
        item.requestId = i["requestId"] as? String
        item.status = i["status"] as? String
        if let files = i["files"] as? [[String: Any]] { // empty = run changed nothing (+0 −0)
            item.linesAdded = files.reduce(0) { $0 + (($1["additions"] as? NSNumber)?.intValue ?? 0) }
            item.linesRemoved = files.reduce(0) { $0 + (($1["deletions"] as? NSNumber)?.intValue ?? 0) }
        } else if i["additions"] != nil || i["deletions"] != nil {
            item.linesAdded = (i["additions"] as? NSNumber)?.intValue
            item.linesRemoved = (i["deletions"] as? NSNumber)?.intValue
        } else if let diff = i["diffStr"] as? String, let counts = lineCounts(diffStr: diff) {
            // Live edits carry no totals until the run's checkpoint; count the patch ourselves.
            (item.linesAdded, item.linesRemoved) = counts
        }
        item.prompt = (i["prompt"] as? String).map { String($0.prefix(600)) }
        item.reason = i["reason"] as? String
        item.approvalOptions = (i["options"] as? [[String: Any]] ?? []).compactMap { o in
            guard let decision = o["decision"] as? String, let label = o["label"] as? String else { return nil }
            return ApprovalOption(decision: decision, label: label, warning: o["warning"] as? String)
        }
        item.questions = (i["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let qid = q["id"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> QuestionOption? in
                guard let label = o["label"] as? String else { return nil }
                return QuestionOption(label: label, value: o["value"] as? String ?? label,
                                      description: o["description"] as? String)
            }
            return Question(id: qid, header: q["header"] as? String ?? "",
                            text: q["question"] as? String ?? qid, options: options,
                            multiSelect: q["multiSelect"] as? Bool ?? false)
        }
        return item
    }

    /// +/- line counts from a file_change `diffStr`: Claude's tool result JSON
    /// (`structuredPatch` hunks, or `content` for a new file), else a plain unified diff.
    static func lineCounts(diffStr: String) -> (Int, Int)? {
        func count(_ lines: [Substring]) -> (Int, Int) {
            var added = 0, removed = 0
            for line in lines {
                if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 }
                else if line.hasPrefix("-") && !line.hasPrefix("---") { removed += 1 }
            }
            return (added, removed)
        }
        if let data = diffStr.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let hunks = json["structuredPatch"] as? [[String: Any]] ?? []
            if !hunks.isEmpty {
                return count(hunks.flatMap { ($0["lines"] as? [String] ?? []).map { Substring($0) } })
            }
            if json["type"] as? String == "create", let content = json["content"] as? String {
                return (content.split(separator: "\n", omittingEmptySubsequences: false).count, 0)
            }
            return nil
        }
        let lines = diffStr.split(separator: "\n")
        guard lines.contains(where: { $0.hasPrefix("@@") }) else { return nil }
        return count(lines)
    }

    // Shared: creating a formatter per timestamp (6 per thread × 400 threads per snapshot) was
    // the single biggest parse cost. ISO8601DateFormatter is thread-safe.
    private nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let whole = ISO8601DateFormatter()

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return fractional.date(from: s) ?? whole.date(from: s)
    }
}

/// The one thing the server won't hand out: each file edit's patch. Read-only lookups by id.
enum EditStats {
    static func lineCounts(itemIds: [String]) -> [String: (Int, Int)] {
        let path = NSString(string: "~/.t3/userdata/statev2.sqlite").expandingTildeInPath
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let placeholders = itemIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT turn_item_id, json_extract(payload_json, '$.diffStr')
        FROM orchestration_v2_projection_turn_items WHERE turn_item_id IN (\(placeholders))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, id) in itemIds.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), id, -1, transient) }
        var out: [String: (Int, Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let diff = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let counts = Incoming.lineCounts(diffStr: diff) else { continue }
            out[id] = counts
        }
        return out
    }
}
