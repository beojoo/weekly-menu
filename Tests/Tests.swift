import Foundation
import Darwin

@main struct Tests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        guard value() else { fatalError("FAIL: \(name)") }
        print("PASS: \(name)")
    }
    static func window(_ used: Any = 28, _ duration: Int = 10080, reset: Any = 2_000_000_000) -> [String: Any] {
        ["usedPercent": used, "windowDurationMins": duration, "resetsAt": reset]
    }
    static func main() throws {
        setbuf(stdout, nil)
        let now = Date(timeIntervalSince1970: 1_000_000)
        for (seconds, text) in [(342000, "3일23시간"), (66720, "18시간32분"), (2520, "42분"),
                                (86400, "1일0시간"), (86399, "23시간59분"), (3600, "1시간0분"),
                                (3599, "59분"), (59, "0분"), (0, "0분"), (-60, "0분")] {
            expect(ResetTime.text(until: now.addingTimeInterval(Double(seconds)), now: now) == text, "reset \(seconds) → \(text)")
        }
        expect(UsageWindow(window())!.remainingPercent == 72, "100 − used = remaining")
        expect(UsageWindow(window(28.2))!.remainingPercent == 71, "fractional remaining rounds down")
        expect(UsageWindow(window(-3))!.remainingPercent == 100, "upper clamp")
        expect(UsageWindow(window(123))!.remainingPercent == 0, "lower clamp")
        expect(UsageWindow(window(true)) == nil, "reject boolean percentage")
        expect(UsageWindow(window(2, reset: NSNull())) == nil, "missing reset stays unavailable")
        expect(UsageWindow(window(2, 1440)) == nil, "daily quota cannot become Weekly")
        let result: [String: Any] = ["rateLimitsByLimitId": [
            "codex": ["primary": window(), "secondary": window(7, 300)],
            "codex_spark": ["primary": window(99)]]]
        let snapshot = try UsageSnapshot(result: result, now: now)
        expect(snapshot.weekly.remainingPercent == 72 && snapshot.fiveHour?.remainingPercent == 93, "duration mapping, reversed primary/secondary")
        let weeklyOnly = try UsageSnapshot(result: ["rateLimits": ["primary": window(), "secondary": NSNull()]])
        expect(weeklyOnly.fiveHour == nil, "weekly-only account does not invent 5H")
        do {
            _ = try UsageSnapshot(result: ["rateLimitsByLimitId": ["spark": ["primary": window()]], "rateLimits": ["primary": window()]])
            fatalError("wrong bucket accepted")
        } catch { expect(error as? UsageError == .unavailable, "explicit non-Codex bucket rejected") }
        expect(Set(ReadOnlyMethod.allCases.map(\.rawValue)) == Set(["initialize", "initialized", "account/read", "account/rateLimits/read"]), "outbound protocol allowlist")

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temp.path)
        defer { try? FileManager.default.removeItem(at: temp) }
        let log = temp.appendingPathComponent("private.jsonl")
        let audit = Audit(path: log.path)
        expect(audit.isEnabled, "new private diagnostic file accepted")
        let attrs = try FileManager.default.attributesOfItem(atPath: log.path)
        expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "diagnostic permissions are 0600")
        let sentinel = Data("keep existing data".utf8)
        let existing = temp.appendingPathComponent("existing")
        try sentinel.write(to: existing)
        expect(!Audit(path: existing.path).isEnabled, "existing file rejected")
        expect(try! Data(contentsOf: existing) == sentinel, "existing content preserved")
        let link = temp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        expect(!Audit(path: link.path).isEnabled, "symbolic link rejected")
        expect(try! Data(contentsOf: existing) == sentinel, "symlink target preserved")
        let hard = temp.appendingPathComponent("hard")
        try FileManager.default.linkItem(at: existing, to: hard)
        expect(!Audit(path: hard.path).isEnabled, "hard link rejected")
        expect(!Audit(path: "relative.jsonl").isEnabled, "relative diagnostic path rejected")
        let shared = temp.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: shared.path)
        expect(!Audit(path: shared.appendingPathComponent("log").path).isEnabled, "writable shared directory rejected")
        do {
            try CodexTrust.check(URL(fileURLWithPath: "/usr/bin/true"), identifier: "codex")
            fatalError("unrelated signer accepted")
        } catch { expect(true, "unrelated signed executable rejected") }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--verify-codex" {
            try CodexTrust.validate(URL(fileURLWithPath: CommandLine.arguments[2]))
            expect(true, "installed official Codex signature accepted")
        }
        let executable = temp.appendingPathComponent("fake-codex")
        let transcript = temp.appendingPathComponent("transcript.jsonl")
        // Fragmented JSONL plus unsolicited notification exercise the transport, not just the parser.
        let script = """
        #!/usr/bin/python3
        import json,sys,os
        for line in sys.stdin:
            r=json.loads(line)
            with open(\(String(reflecting: transcript.path)), 'a') as f: f.write(json.dumps({'method':r['method'],'pid':os.getpid(),'params':r.get('params')})+'\\n')
            if 'id' not in r: continue
            m=r['method']
            data={} if m=='initialize' else {'account':{'type':'chatgpt'}} if m=='account/read' else {'rateLimits':{'primary':{'usedPercent':28,'windowDurationMins':10080,'resetsAt':2000000000}}}
            sys.stdout.write('{"method":"test/notification"}\\n');sys.stdout.flush()
            s=json.dumps({'id':r['id'],'result':data})+'\\n'
            sys.stdout.write(s[:12]);sys.stdout.flush();sys.stdout.write(s[12:]);sys.stdout.flush()
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let protected = AppServer(audit: Audit())
        var rejected: UsageError?
        protected.fetch(executable: executable) { if case .failure(let error) = $0 { rejected = error } }
        let rejectDeadline = Date().addingTimeInterval(3)
        while rejected == nil && Date() < rejectDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        expect(rejected == .unavailable, "unsigned helper rejected before launch")
        expect(!FileManager.default.fileExists(atPath: transcript.path), "untrusted helper never executed")
        protected.stop()
        var validations = 0
        let service = AppServer(audit: Audit(), validateExecutable: { _ in validations += 1 })
        for i in 1...2 {
            var response: Result<UsageSnapshot, UsageError>?
            service.fetch(executable: executable) { response = $0 }
            let end = Date().addingTimeInterval(25)
            while response == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            expect((try? response?.get().weekly.remainingPercent) == 72, "persistent RPC fetch \(i)")
        }
        service.stop()
        expect(validations == 1, "signature verification only at helper launch")
        let rows = try String(contentsOf: transcript, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        expect(Set(rows.compactMap { $0["pid"] as? Int }).count == 1, "two refreshes reuse one child")
        expect(rows.compactMap { $0["method"] as? String } == ["initialize", "initialized", "account/read", "account/rateLimits/read", "account/read", "account/rateLimits/read"], "only read RPCs, initialize once")
        expect(rows.filter { $0["method"] as? String == "account/read" }.allSatisfy { ($0["params"] as? [String: Any])?["refreshToken"] as? Bool == false }, "never force token refresh")
        var absent: UsageError?
        service.fetch(executable: nil) { if case .failure(let error) = $0 { absent = error } }
        let end = Date().addingTimeInterval(2)
        while absent == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        expect(absent == .notRunning, "missing Codex error")
        for (source, expected, label) in [
            (script.replacingOccurrences(of: "{'account':{'type':'chatgpt'}}", with: "{'account':None}"), UsageError.notSignedIn, "signed-out session"),
            (script.replacingOccurrences(of: "'type':'chatgpt'", with: "'type':'apiKey'"), UsageError.unavailable, "API-key-only session has no subscription quota"),
            (script.replacingOccurrences(of: "'windowDurationMins':10080", with: "'windowDurationMins':1440"), UsageError.unavailable, "missing weekly window")
        ] {
            try source.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let client = AppServer(audit: Audit(), validateExecutable: { _ in })
            var failure: UsageError?
            client.fetch(executable: executable) { if case .failure(let error) = $0 { failure = error } }
            let deadline = Date().addingTimeInterval(3)
            while failure == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            expect(failure == expected, label)
            client.stop()
        }
        // An unresponsive backend must not block Quit until its request deadline.
        try "#!/usr/bin/python3\nimport time\ntime.sleep(30)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let stalled = AppServer(audit: Audit(), validateExecutable: { _ in })
        stalled.fetch(executable: executable) { _ in }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let stopTime = Date()
        stalled.stop()
        expect(Date().timeIntervalSince(stopTime) < 2, "Quit interrupts an unresponsive backend")
        print("\(checks) checks passed")
    }
}
