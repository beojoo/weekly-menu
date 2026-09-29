import Foundation
import Darwin

/// One serial worker, one persistent child, no HTTP client and no credential handling.
/// poll() blocks only while awaiting an explicitly requested RPC response (max 20 seconds).
final class AppServer {
    private let queue = DispatchQueue(label: "local.weeklymenu.rpc", qos: .utility)
    private var process: Process?
    private let processLock = NSLock()
    private var cancellableProcess: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var requestID = 0
    var onDisconnect: (() -> Void)?
    let audit: Audit

    private let validateExecutable: (URL) throws -> Void
    init(audit: Audit, validateExecutable: @escaping (URL) throws -> Void = CodexTrust.validate) {
        self.audit = audit
        self.validateExecutable = validateExecutable
    }

    func fetch(executable: URL?, completion: @escaping (Result<UsageSnapshot, UsageError>) -> Void) {
        queue.async {
            do {
                guard let executable else { self.stopConnection(); throw UsageError.notRunning }
                if self.process?.isRunning != true { try self.start(executable) }
                let deadline = ProcessInfo.processInfo.systemUptime + 20
                let account = try self.request(.account, params: ["refreshToken": false], deadline: deadline)
                guard let info = account["account"] as? [String: Any] else { throw UsageError.notSignedIn }
                guard let type = info["type"] as? String,
                      ["chatgpt", "chatgptAuthTokens"].contains(type) else { throw UsageError.unavailable }
                let result = try self.request(.limits, deadline: deadline)
                let snapshot = try UsageSnapshot(result: result)
                var childStats: [String: Any] = [:]
                if let pid = self.process?.processIdentifier {
                    var info = proc_taskinfo()
                    if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
                        var timebase = mach_timebase_info_data_t()
                        mach_timebase_info(&timebase)
                        childStats["cpuSeconds"] = Double(info.pti_total_user + info.pti_total_system)
                            * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
                        childStats["rssBytes"] = info.pti_resident_size
                    }
                }
                self.audit.record("snapshot", [
                    "childResources": childStats,
                    "weeklyUsed": snapshot.weekly.usedPercent,
                    "weeklyRemaining": snapshot.weekly.remainingPercent,
                    "weeklyResetsAt": snapshot.weekly.resetsAt.timeIntervalSince1970,
                    "fiveHourRemaining": snapshot.fiveHour.map { $0.remainingPercent as Any } ?? NSNull(),
                    "childPID": self.process?.processIdentifier ?? 0,
                    "title": snapshot.title()
                ])
                DispatchQueue.main.async { completion(.success(snapshot)) }
            } catch {
                let failure = error as? UsageError ?? .unavailable
                // Auth / absent-window errors do not require a new process on the next refresh.
                if !(error is UsageError) { self.stopConnection() }
                self.audit.record("fetchError", ["reason": failure.rawValue])
                DispatchQueue.main.async { completion(.failure(failure)) }
            }
        }
    }

    func stop() {
        // Interrupt a blocked read before synchronizing; Quit never waits for a network timeout.
        processLock.lock()
        if cancellableProcess?.isRunning == true { cancellableProcess?.terminate() }
        processLock.unlock()
        queue.sync { stopConnection() }
    }

    private func start(_ executable: URL) throws {
        stopConnection()
        try validateExecutable(executable)
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        let child = Process()
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        child.executableURL = executable
        child.arguments = ["app-server", "--stdio", "-c", "analytics.enabled=false",
                           "-c", "otel.exporter=\"none\"", "-c", "otel.trace_exporter=\"none\""]
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = FileHandle.nullDevice
        child.currentDirectoryURL = executable.deletingLastPathComponent()
        child.terminationHandler = { [weak self] ended in
            guard let self else { return }
            self.queue.async {
                guard self.process === ended else { return }
                self.stopConnection()
                self.audit.record("serverExit")
                DispatchQueue.main.async { self.onDisconnect?() }
            }
        }
        do { try child.run() } catch { throw UsageError.notRunning }
        process = child
        processLock.lock(); cancellableProcess = child; processLock.unlock()
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        let noSignal: Int32 = 1
        _ = fcntl(input!.fileDescriptor, F_SETNOSIGPIPE, noSignal)
        audit.record("serverStart", ["childPID": child.processIdentifier])
        _ = try request(.initialize, params: [
            "clientInfo": ["name": "weekly_menu", "title": "Weekly Menu", "version": "1.1.2"],
            "capabilities": ["experimentalApi": false]
        ], deadline: deadline)
        try send(.initialized)
    }

    private func stopConnection() {
        process?.terminationHandler = nil
        try? input?.close()
        try? output?.close()
        if process?.isRunning == true { process?.terminate() }
        processLock.lock(); cancellableProcess = nil; processLock.unlock()
        process = nil; input = nil; output = nil
        buffer.removeAll(keepingCapacity: false)
    }

    private func send(_ method: ReadOnlyMethod, id: Int? = nil, params: [String: Any]? = nil) throws {
        guard let input else { throw TransportError.closed }
        var message: [String: Any] = ["method": method.rawValue]
        if let id { message["id"] = id }
        if let params { message["params"] = params }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        // Only method names are audited: no account, auth, response body, or environment data.
        audit.record("rpc", ["method": method.rawValue])
        try input.write(contentsOf: data)
    }

    private func request(_ method: ReadOnlyMethod, params: [String: Any]? = nil, deadline: TimeInterval) throws -> [String: Any] {
        requestID += 1
        let id = requestID
        try send(method, id: id, params: params)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let message = try nextMessage(deadline: deadline)
            guard let responseID = message["id"] as? Int, responseID == id else { continue }
            if let error = message["error"] as? [String: Any] {
                let text = (error["message"] as? String ?? "").lowercased()
                if text.contains("not signed in") || text.contains("unauthorized") || text.contains("401") {
                    throw UsageError.notSignedIn
                }
                throw UsageError.unavailable
            }
            guard let result = message["result"] as? [String: Any] else { throw TransportError.invalid }
            return result
        }
        throw TransportError.timeout
    }

    private func nextMessage(deadline: TimeInterval) throws -> [String: Any] {
        guard let output else { throw TransportError.closed }
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw TransportError.invalid
                }
                return object
            }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let wait = Int32(max(1, min(20_000, (deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
            let result = Darwin.poll(&descriptor, 1, wait)
            if result == 0 { throw TransportError.timeout }
            if result < 0 { if errno == EINTR { continue }; throw TransportError.closed }
            if descriptor.revents & Int16(POLLIN) == 0 { throw TransportError.closed }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw TransportError.closed }
            buffer.append(contentsOf: bytes[..<count])
            guard buffer.count <= 1_048_576 else { throw TransportError.invalid }
        }
        throw TransportError.timeout
    }

    private enum TransportError: Error { case closed, timeout, invalid }
}

/// Opt-in, local-only verification log. Disabled in normal use.
final class Audit {
    private let lock = NSLock()
    private let handle: FileHandle?
    init(path: String? = nil) {
        if let path {
            handle = Self.createPrivateFile(path)
        } else { handle = nil }
    }
    var isEnabled: Bool { handle != nil }

    private static func createPrivateFile(_ path: String) -> FileHandle? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // Resolve directory aliases (e.g. /var -> /private/var), not the final file.
        guard let resolved = realpath(url.deletingLastPathComponent().path, nil) else { return nil }
        defer { free(resolved) }
        let components = String(cString: resolved).split(separator: "/").map(String.init)
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        for component in components {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(directory)
            guard next >= 0 else { return nil }
            directory = next
        }
        defer { Darwin.close(directory) }
        var folder = stat()
        guard fstat(directory, &folder) == 0, folder.st_uid == geteuid(),
              folder.st_mode & 0o022 == 0 else { return nil }
        let fd = openat(directory, url.lastPathComponent,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { return nil } // Existing files/symlinks are never opened.
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              fchmod(fd, 0o600) == 0 else {
            Darwin.close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        guard let handle else { return }
        lock.lock(); defer { lock.unlock() }
        var value = fields
        value["event"] = event
        value["at"] = Date().timeIntervalSince1970
        value["appPID"] = ProcessInfo.processInfo.processIdentifier
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            value["cpuSeconds"] = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            value["peakRSSBytes"] = usage.ru_maxrss
        }
        if var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            data.append(10); try? handle.write(contentsOf: data)
        }
    }
}
