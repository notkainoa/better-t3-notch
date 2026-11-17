import Foundation
import os

private let log = Logger(subsystem: "me.kainoa.better-t3-notch", category: "remote")

/// Another machine this Mac's T3 Code is linked to (Settings → Connections).
struct LinkedEnvironment: Equatable, Sendable {
    let environmentId: String
    let label: String
    /// Where it answers, tried in order: its T3 Connect address, or a Tailscale / LAN one.
    let urls: [String]
}

/// What a T3 server says about itself at `/.well-known/t3/environment` (public, no token).
struct ServerDescriptor: Sendable {
    let id, serverVersion: String?
    let protocolVersion: Int?
    let commandOutputStreaming: Bool

    static func fetch(_ origin: URL, timeout: TimeInterval = 60) async -> ServerDescriptor? {
        var request = URLRequest(url: origin.appendingPathComponent(".well-known/t3/environment"))
        request.timeoutInterval = timeout
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let caps = json["capabilities"] as? [String: Any]
        return ServerDescriptor(id: json["environmentId"] as? String,
                                serverVersion: json["serverVersion"] as? String,
                                protocolVersion: (json["orchestrationProtocolVersion"] as? NSNumber)?.intValue,
                                commandOutputStreaming: caps?["commandOutputStreaming"] as? Bool ?? false)
    }
}

/// Threads on the user's other machines, with nothing installed there.
///
/// - Which machines: the ones this Mac's T3 Code is linked to (`t3 environment list`), with the
///   addresses T3 reaches them at (T3 Connect's tunnel, usually).
/// - Getting in: a token minted once per machine by running T3's own CLI there over SSH
///   (Tailscale SSH: no keys, no prompt), the same `t3 auth session issue` the notch runs here.
///   It shows up on that machine as "Better T3 Notch (this Mac)" under Authorized clients.
enum RemoteAccess {
    static let tokenTTL = "365d"

    // MARK: Which machines

    /// The linked machines, from T3's CLI (works whether or not the server is up). Nil if the
    /// CLI couldn't say, so the caller keeps what it had.
    static func linkedEnvironments() async -> [LinkedEnvironment]? {
        let cli = NSString(string: "~/.t3/bin/t3").expandingTildeInPath
        guard let out = await run(cli, ["environment", "list", "--json"], timeout: 30),
              let list = try? JSONSerialization.jsonObject(with: out) as? [[String: Any]] else { return nil }
        return parseLinks(list)
    }

    nonisolated static func parseLinks(_ list: [[String: Any]]) -> [LinkedEnvironment] {
        list.compactMap { link in
            // Ids are UUIDs, and one goes into the script run over SSH: nothing else gets through.
            guard let id = link["environmentId"] as? String, !id.isEmpty,
                  id.allSatisfy({ $0.isHexDigit || $0 == "-" }),
                  let urls = link["urls"] as? [String], !urls.isEmpty else { return nil }
            return LinkedEnvironment(environmentId: id, label: link["label"] as? String ?? id, urls: urls)
        }
    }

    /// The first of the machine's addresses that answers as that machine, in a protocol we speak.
    static func origin(for link: LinkedEnvironment) async -> (URL, ServerDescriptor)? {
        for string in link.urls {
            guard let url = URL(string: string), isPrivate(url) else { continue }
            guard let d = await ServerDescriptor.fetch(url, timeout: 10) else { continue }
            guard d.id == link.environmentId else {
                log.notice("\(string, privacy: .public) answers as another environment")
                continue
            }
            guard d.protocolVersion == nil || d.protocolVersion == ThreadStore.protocolVersion else {
                log.notice("\(link.label, privacy: .public) speaks protocol \(d.protocolVersion ?? 0)")
                continue
            }
            return (url, d)
        }
        return nil
    }

    /// Whether the token can go there unread: https, or plain http only over Tailscale (which
    /// encrypts it) or to this Mac. Never over a plain LAN.
    nonisolated static func isPrivate(_ url: URL) -> Bool {
        if url.scheme == "https" { return true }
        guard url.scheme == "http", let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".ts.net") { return true }
        // Tailscale's addresses: 100.64.0.0/10.
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    // MARK: Finding the machine on the tailnet

    struct Host: Equatable, Sendable {
        /// What ssh connects to (a Tailscale address).
        let address: String
        let name: String
    }

    /// The machines on the tailnet that take SSH, the likeliest one for `label` first.
    nonisolated static func candidates(label: String, tailscaleStatus: [String: Any]) -> [Host] {
        let peers = (tailscaleStatus["Peer"] as? [String: [String: Any]] ?? [:]).values
        let want = slug(label)
        let hosts: [(Host, Bool)] = peers.compactMap { p in
            guard p["Online"] as? Bool == true, p["sshHostKeys"] != nil,
                  let address = (p["TailscaleIPs"] as? [String])?.first else { return nil }
            let name = p["HostName"] as? String ?? ""
            let dns = (p["DNSName"] as? String ?? "").split(separator: ".").first.map(String.init) ?? ""
            let matches = !want.isEmpty && (slug(name) == want || slug(dns) == want)
            return (Host(address: address, name: dns.isEmpty ? name : dns), matches)
        }
        // Name matches first, then the rest in a stable order.
        return hosts.sorted { a, b in a.1 != b.1 ? a.1 : a.0.name < b.0.name }.map(\.0)
    }

    /// "Alex’s MacBook Air" -> "alexs-macbook-air", the way Tailscale names machines.
    nonisolated static func slug(_ s: String) -> String {
        let folded = s.lowercased().replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
        let dashed = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
        return dashed.split(separator: "-").joined(separator: "-")
    }

    private static func tailscaleStatus() async -> [String: Any]? {
        let paths = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
                     "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let cli = paths.first(where: FileManager.default.isExecutableFile(atPath:)),
              let out = await run(cli, ["status", "--json"], timeout: 15) else { return nil }
        return try? JSONSerialization.jsonObject(with: out) as? [String: Any]
    }

    // MARK: Minting

    /// What one SSH visit found: the machine's environment id, and a token if it's the one we want.
    struct Visit: Equatable, Sendable {
        let environmentId: String?
        let token: String?
    }

    /// Runs on the other machine (any POSIX login shell, fish included, since it's all inside
    /// `sh -c '…'`): say which environment this is, and only if it's `want`, mint a token with
    /// T3's own CLI.
    nonisolated static func remoteScript(want: String, label: String) -> String {
        let script = """
        id=$(cat "$HOME/.t3/userdata/environment-id" 2>/dev/null); echo "environment:$id"; \
        [ "$id" = "\(want)" ] || exit 0; \
        for t in "$HOME/.t3/bin/t3" "$HOME/.local/bin/t3"; do if [ -x "$t" ]; then \
        exec "$t" auth session issue --token-only --ttl \(tokenTTL) --label "\(label)" \
        --scope orchestration:read --scope orchestration:operate; fi; done; exit 127
        """
        return "sh -c '\(script)'"
    }

    nonisolated static func parseVisit(_ output: String) -> Visit {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let env = lines.first { $0.hasPrefix("environment:") }.map { String($0.dropFirst("environment:".count)) }
        let token = lines.last { !$0.isEmpty && !$0.hasPrefix("environment:") && !$0.contains(" ") }
        return Visit(environmentId: env?.isEmpty == false ? env : nil, token: token)
    }

    /// The label the token gets on the other machine: which Mac's notch it is.
    nonisolated static func sessionLabel(machine: String) -> String {
        // Only characters that can't break out of the quoting in `remoteScript`.
        let safe = machine.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || " -_.’()".unicodeScalars.contains($0)
        }
        let name = String(String.UnicodeScalarView(safe)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Better T3 Notch" : "Better T3 Notch (\(name))"
    }

    /// SSH into `host` and, if it's `want`'s machine, mint a token there.
    static func visit(_ host: Host, want: String) async -> Visit? {
        let label = sessionLabel(machine: Host.currentName)
        let args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                    "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                    // Its own known_hosts: first contact is trusted (it's on the tailnet), and the
                    // user's file is left alone.
                    "-o", "StrictHostKeyChecking=accept-new",
                    // No shared master connection: its background process would keep the output
                    // open and the mint would never finish.
                    "-o", "ControlMaster=no", "-o", "ControlPath=none",
                    // Quoted: ssh splits this option at spaces, and the path has "Application Support".
                    "-o", "UserKnownHostsFile=\"\(TokenFiles.directory.appendingPathComponent("known_hosts").path)\"",
                    "\(NSUserName())@\(host.address)", remoteScript(want: want, label: label)]
        // Any exit status: the right machine without a working `t3` still says which it is.
        guard let out = await run("/usr/bin/ssh", args, timeout: 30, requireSuccess: false) else { return nil }
        return parseVisit(String(decoding: out, as: UTF8.self))
    }

    /// A fresh token for `link`'s machine, or nil if no machine on the tailnet could mint one.
    /// Remembers which host was which, so later mints go straight there.
    static func mint(for link: LinkedEnvironment) async -> String? {
        var hosts: [Host] = []
        if let known = TokenFiles.host(for: link.environmentId) { hosts.append(known) }
        if let status = await tailscaleStatus() {
            // Machines already known to be another environment go last, so a label that doesn't
            // match its Tailscale name still gets found on a busy tailnet.
            let elsewhere = TokenFiles.addressesKnown(except: link.environmentId)
            let found = candidates(label: link.label, tailscaleStatus: status).filter { !hosts.contains($0) }
            hosts += found.filter { !elsewhere.contains($0.address) } + found.filter { elsewhere.contains($0.address) }
        }
        for host in hosts {
            guard let visit = await visit(host, want: link.environmentId) else { continue }
            if let env = visit.environmentId { TokenFiles.setHost(host, for: env) }
            guard visit.environmentId == link.environmentId else { continue }
            if let token = visit.token {
                log.notice("minted a token on \(host.name, privacy: .public) for \(link.label, privacy: .public)")
                return token
            }
            log.notice("\(host.name, privacy: .public) is \(link.label, privacy: .public) but couldn't mint (no t3 CLI?)")
            return nil
        }
        log.notice("no machine on the tailnet is \(link.label, privacy: .public)")
        return nil
    }

    // MARK: Processes

    /// Run a tool and return its stdout, or nil if it failed or took longer than `timeout`.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval,
                    requireSuccess: Bool = true) async -> Data? {
        await Task.detached {
            guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            return p.terminationStatus == 0 || !requireSuccess ? data : nil
        }.value
    }
}

extension RemoteAccess.Host {
    /// This Mac's name ("Alex’s MacBook Pro"), for the token's label over there.
    static var currentName: String { Foundation.Host.current().localizedName ?? "Mac" }
}

/// Tokens for the other machines (one file each) and which tailnet host each machine is, in
/// Application Support, owner-only.
enum TokenFiles {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterT3Notch/remote", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    private static func file(_ environmentId: String, _ ext: String) -> URL? {
        // Environment ids are UUIDs; anything else never becomes a path.
        guard environmentId.allSatisfy({ $0.isHexDigit || $0 == "-" }), !environmentId.isEmpty else { return nil }
        return directory.appendingPathComponent("\(environmentId).\(ext)")
    }

    static func token(for environmentId: String) -> String? {
        guard let url = file(environmentId, "token"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let token = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func setToken(_ token: String?, for environmentId: String) {
        guard let url = file(environmentId, "token") else { return }
        guard let token else { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    static func host(for environmentId: String) -> RemoteAccess.Host? {
        guard let url = file(environmentId, "host"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = s.split(separator: "\n").map(String.init)
        guard let address = parts.first, !address.isEmpty else { return nil }
        return .init(address: address, name: parts.count > 1 ? parts[1] : address)
    }

    /// The addresses of the machines recorded as some other environment.
    static func addressesKnown(except environmentId: String) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "host" && $0.deletingPathExtension().lastPathComponent != environmentId }
            .compactMap { host(for: $0.deletingPathExtension().lastPathComponent)?.address })
    }

    static func setHost(_ host: RemoteAccess.Host, for environmentId: String) {
        guard let url = file(environmentId, "host") else { return }
        try? Data("\(host.address)\n\(host.name)".utf8).write(to: url, options: .atomic)
    }
}

/// A remote machine's token: cached on disk, minted over SSH when missing or refused, and never
/// retried faster than a growing backoff (a machine that's off shouldn't mean SSH every 15 s).
@MainActor
final class RemoteTokens {
    private var cached: [String: String] = [:]
    private var nextTry: [String: Date] = [:]
    private var backoff: [String: TimeInterval] = [:]
    private var minting: [String: Task<String?, Never>] = [:]
    private var mintedAt: [String: Date] = [:]

    func token(for link: LinkedEnvironment) async -> String? {
        let id = link.environmentId
        if let token = cached[id] { return token }
        if let token = TokenFiles.token(for: id) { cached[id] = token; return token }
        if let running = minting[id] { return await running.value }
        guard Date() >= nextTry[id] ?? .distantPast else { return nil }
        let task = Task { await RemoteAccess.mint(for: link) }
        minting[id] = task
        let token = await task.value
        minting[id] = nil
        if let token {
            nextTry[id] = nil
            mintedAt[id] = Date()
            cached[id] = token
            TokenFiles.setToken(token, for: id)
        } else {
            waitLonger(id)
        }
        return token
    }

    private func waitLonger(_ id: String) {
        let wait = min((backoff[id] ?? 30) * 2, 30 * 60)
        backoff[id] = wait
        nextTry[id] = Date().addingTimeInterval(wait)
    }

    /// The machine refused it (revoked, or expired): forget it so the next connect mints again.
    func discard(_ environmentId: String) {
        cached[environmentId] = nil
        TokenFiles.setToken(nil, for: environmentId)
        // A token refused right after it was minted means something else is wrong: back off
        // rather than add a new session over there on every reconnect.
        if let minted = mintedAt[environmentId], Date().timeIntervalSince(minted) < 5 * 60 {
            waitLonger(environmentId)
        } else {
            backoff[environmentId] = nil
        }
    }

    /// Back from sleep, or the links changed: try minting again right away.
    func resetBackoff() {
        nextTry = [:]
        backoff = [:]
    }
}
