import Foundation
import Testing
@testable import BetterT3Notch

@Suite struct RemoteTests {
    @Test func linksParseFromTheCLI() {
        let json = """
        [{"environmentId":"11111111-2222-4333-8444-555555555555","label":"Alex’s MacBook Air",
          "urls":["https://env-1.relay.example.com"],"status":"reachable"},
         {"environmentId":"x'; rm -rf ~; '","label":"Hostile","urls":["https://example.com"]},
         {"environmentId":"11111111","label":"No address","urls":[]}]
        """
        let list = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        #expect(RemoteAccess.parseLinks(list) == [
            LinkedEnvironment(environmentId: "11111111-2222-4333-8444-555555555555", label: "Alex’s MacBook Air",
                              urls: ["https://env-1.relay.example.com"]),
        ])
    }

    @Test func tokensOnlyGoOverPrivateRoutes() {
        #expect(RemoteAccess.isPrivate(URL(string: "https://env-1.relay.example.com")!))
        #expect(RemoteAccess.isPrivate(URL(string: "http://100.100.1.2:3773")!))
        #expect(RemoteAccess.isPrivate(URL(string: "http://alexs-macbook-air.tail0000.ts.net:3773")!))
        #expect(!RemoteAccess.isPrivate(URL(string: "http://192.168.1.20:3773")!))
        #expect(!RemoteAccess.isPrivate(URL(string: "http://100.200.1.1:3773")!))
        #expect(!RemoteAccess.isPrivate(URL(string: "ftp://100.100.1.2")!))
        #expect(!RemoteAccess.isPrivate(URL(string: "http://100.100.1.1.example.com:3773")!))
        #expect(!RemoteAccess.isPrivate(URL(string: "http://100.100.1:3773")!))
    }

    @Test func labelsBecomeTailscaleNames() {
        #expect(RemoteAccess.slug("Alex’s MacBook Air") == "alexs-macbook-air")
        #expect(RemoteAccess.slug("alexs-linux-box") == "alexs-linux-box")
        #expect(RemoteAccess.slug("  Dev box (2) ") == "dev-box-2")
    }

    @Test func theNamedMachineIsTriedFirst() {
        let status: [String: Any] = ["Peer": [
            "a": ["HostName": "alexs-linux-box", "DNSName": "alexs-linux-box.tail.ts.net.", "Online": true,
                  "TailscaleIPs": ["100.1.1.1"], "sshHostKeys": ["k"]],
            "b": ["HostName": "alexs-macbook-air", "DNSName": "alexs-macbook-air.tail.ts.net.", "Online": true,
                  "TailscaleIPs": ["100.2.2.2"], "sshHostKeys": ["k"]],
            "c": ["HostName": "phone", "DNSName": "phone.tail.ts.net.", "Online": true, "TailscaleIPs": ["100.3.3.3"]],
            "d": ["HostName": "vps", "DNSName": "vps.tail.ts.net.", "Online": false,
                  "TailscaleIPs": ["100.4.4.4"], "sshHostKeys": ["k"]],
        ]]
        let hosts = RemoteAccess.candidates(label: "Alex’s MacBook Air", tailscaleStatus: status)
        // Offline machines and ones without Tailscale SSH are skipped.
        #expect(hosts.map(\.address) == ["100.2.2.2", "100.1.1.1"])
        #expect(hosts.first?.name == "alexs-macbook-air")
    }

    @Test func visitOutputParses() {
        #expect(RemoteAccess.parseVisit("environment:abc\nt3tok_123\n") == .init(environmentId: "abc", token: "t3tok_123"))
        #expect(RemoteAccess.parseVisit("environment:other\n") == .init(environmentId: "other", token: nil))
        #expect(RemoteAccess.parseVisit("environment:\n") == .init(environmentId: nil, token: nil))
    }

    @Test func labelsCantBreakTheQuoting() {
        #expect(RemoteAccess.sessionLabel(machine: "Alex’s MacBook Pro") == "Better T3 Notch (Alex’s MacBook Pro)")
        #expect(RemoteAccess.sessionLabel(machine: "it's $(rm -rf ~) `x` \"y\"") == "Better T3 Notch (its (rm -rf ) x y)")
    }

    /// The script really runs: in a fake home with T3's environment id and a stand-in `t3`.
    @Test func remoteScriptMintsOnlyOnTheRightMachine() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("notch-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let userdata = home.appendingPathComponent(".t3/userdata")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: userdata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "env-1\n".write(to: userdata.appendingPathComponent("environment-id"), atomically: true, encoding: .utf8)
        let t3 = bin.appendingPathComponent("t3")
        try "#!/bin/sh\necho \"tok:$*\" | tr ' ' '_'\n".write(to: t3, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: t3.path)

        func run(_ want: String) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // ssh hands the command to the login shell, which runs it like `sh -c <command>`.
            p.arguments = ["-c", RemoteAccess.remoteScript(want: want, label: "Better T3 Notch (Alex’s Mac)")]
            p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let out = Pipe()
            p.standardOutput = out
            try! p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        let minted = RemoteAccess.parseVisit(run("env-1"))
        #expect(minted.environmentId == "env-1")
        #expect(minted.token == "tok:auth_session_issue_--token-only_--ttl_365d_--label_Better_T3_Notch_(Alex’s_Mac)_--scope_orchestration:read_--scope_orchestration:operate")
        #expect(RemoteAccess.parseVisit(run("env-2")) == .init(environmentId: "env-1", token: nil))
    }

    @Test func anotherMachinesThreadsAreKeyedByEnvironment() {
        let values: [String: Any] = ["_tag": "Chunk", "requestId": "1", "values": [[
            "kind": "thread.updated",
            "thread": ["id": "t1", "projectId": "p1", "title": "Child", "status": "idle",
                       "createdAt": "2026-11-17T00:00:00.000Z", "updatedAt": "2026-11-17T00:00:00.000Z",
                       "lineage": ["parentThreadId": "t0", "relationshipToParent": "subagent"]],
        ]]]
        let data = try! JSONSerialization.data(withJSONObject: values)
        guard case .chunk(_, let parsed)? = Incoming.parse(data),
              case .threadUpdated(let thread)? = parsed.first?.shell else { Issue.record("no thread"); return }
        let remote = thread.namespaced("env-9")
        #expect(remote.id == "env-9/t1")
        #expect(remote.projectId == "env-9/p1")
        #expect(remote.parentId == "env-9/t0")
        #expect(remote.status == thread.status)
        // This Mac's threads keep their own ids.
        #expect(thread.namespaced(nil).id == "t1")
    }
}
