import Foundation
import Darwin

struct UsageWindow: Codable {
    let name: String
    let usedPercent: Double
    let resetsAt: Date?
}

struct Subscription: Codable {
    let plan: String
    let windows: [UsageWindow]
    let updatedAt: Date
    let source: String
}

enum ProviderError: LocalizedError {
    case unsupported(String)
    case unavailable(String)
    case authentication(String)
    case timeout(String)
    case transport(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name): return "Unsupported provider: \(name). Choose codex or claude."
        case .unavailable(let message), .authentication(let message),
             .transport(let message), .invalidResponse(let message): return message
        case .timeout(let provider): return "\(provider) usage request timed out after 25 seconds. Check your connection and try again."
        }
    }
}

enum Providers {
    static func fetch(_ provider: String) async throws -> Subscription {
        try Task.checkCancellation()
        let name = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "codex", "claude":
            let isClaude = name == "claude"
            let cancellation = ProviderCancellation()
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(with: Result { try isClaude ? ClaudeCLI.fetch(cancellation) : fetchCodex(cancellation) })
                    }
                }
            }, onCancel: { cancellation.cancel() })
        default: throw ProviderError.unsupported(provider)
        }
    }

    private static func codexExecutable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex",
            "\(home)/.volta/bin/codex", "\(home)/.cargo/bin/codex"
        ]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/codex" }
        let nvm = ProcessInfo.processInfo.environment["NVM_DIR"] ?? "\(home)/.nvm"
        let versions = "\(nvm)/versions/node"
        let nodes = (try? FileManager.default.contentsOfDirectory(atPath: versions)) ?? []
        candidates += nodes.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(versions)/\($0)/bin/codex" }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ProviderError.unavailable("Codex was not found. Install the ChatGPT/Codex app or the Codex CLI and sign in with codex login.")
        }
        return URL(fileURLWithPath: path)
    }

    // JSONL protocol: https://developers.openai.com/codex/app-server
    // This connection never creates a thread or starts a model turn.
    private static func fetchCodex(_ cancellation: ProviderCancellation) throws -> Subscription {
        let executable = try codexExecutable()
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" +
            (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        // Discard diagnostics; they may contain account information. No stderr pipe can fill.
        process.standardError = FileHandle.nullDevice
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try? output.fileHandleForReading.close()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        try cancellation.check()
        do { try process.run() } catch {
            throw ProviderError.unavailable("Could not start Codex app-server. Update or reinstall Codex and check that the executable can run.")
        }
        // Parent must release the child's ends so EOF is detectable.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let writer = input.fileHandleForWriting.fileDescriptor
        let reader = output.fileHandleForReading.fileDescriptor
        guard fcntl(writer, F_SETNOSIGPIPE, 1) != -1,
              fcntl(writer, F_SETFL, O_NONBLOCK) != -1,
              fcntl(reader, F_SETFL, O_NONBLOCK) != -1 else {
            throw ProviderError.transport("Could not configure the Codex connection. Restart AgentsPanel and retry.")
        }
        func checkDeadline() throws {
            try cancellation.check()
            if ProcessInfo.processInfo.systemUptime >= deadline { throw ProviderError.timeout("Codex") }
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try checkDeadline()
                    let count = Darwin.write(writer, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                        var descriptor = pollfd(fd: writer, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&descriptor, 1, 50)
                    } else { throw ProviderError.transport("Codex closed its input. Update Codex and retry.") }
                }
            }
        }
        var buffer = Data()
        func response(_ id: Int) throws -> [String: Any] {
            while true {
                try checkDeadline()
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if line.isEmpty { continue }
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        throw ProviderError.invalidResponse("Codex returned invalid JSON. Update Codex and retry.")
                    }
                    guard (message["id"] as? Int) == id else { continue }
                    if message["error"] != nil {
                        // Never surface server error text, which may contain sensitive data.
                        throw ProviderError.authentication("Codex could not read account usage. Run codex login with a ChatGPT subscription account, check your connection, and update Codex if needed.")
                    }
                    guard let result = message["result"] as? [String: Any] else {
                        throw ProviderError.invalidResponse("Codex returned no result. Update Codex and retry.")
                    }
                    return result
                }
                var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0 else { throw ProviderError.transport("Could not read Codex output. Restart AgentsPanel and retry.") }
                if ready == 0 { continue }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(reader, &bytes, bytes.count)
                if count > 0 {
                    buffer.append(contentsOf: bytes.prefix(count))
                    if buffer.count > 4 * 1024 * 1024 {
                        throw ProviderError.invalidResponse("Codex returned an oversized response. Update Codex and retry.")
                    }
                } else if count == 0 {
                    throw ProviderError.transport("Codex app-server exited before returning usage. Run codex login and check your Codex installation.")
                } else if errno != EAGAIN && errno != EINTR {
                    throw ProviderError.transport("The Codex connection failed. Restart AgentsPanel and retry.")
                }
            }
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "agent_panel", "title": "AgentsPanel", "version": "1.0"]]])
        _ = try response(1)
        try send(["method": "initialized", "params": [:]])
        try send(["id": 2, "method": "account/rateLimits/read"])
        let result = try response(2)
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        guard let bucket = (buckets?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any]) else {
            throw ProviderError.invalidResponse("Codex did not provide subscription limits. Sign in with a ChatGPT subscription account using codex login.")
        }
        var windows: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let value = bucket[key], !(value is NSNull) else { continue }
            guard let window = value as? [String: Any], let used = number(window["usedPercent"]), used >= 0 else {
                throw ProviderError.invalidResponse("Codex returned an invalid usage window. Update Codex and retry.")
            }
            let duration = number(window["windowDurationMins"])
            let name: String
            switch duration {
            case 300: name = "5-hour session"
            case 10080: name = "Weekly"
            case let minutes? where minutes > 0: name = "\(minutes.formatted()) minute window"
            default: name = key.capitalized + " window"
            }
            let reset = try unixReset(window["resetsAt"])
            windows.append(UsageWindow(name: name, usedPercent: used, resetsAt: reset))
        }
        guard !windows.isEmpty else { throw ProviderError.unavailable("Codex returned no usage windows for this account. Check your subscription and Codex login.") }
        return Subscription(plan: nonempty(bucket["planType"]) ?? "Unknown plan", windows: windows, updatedAt: Date(), source: "Codex app-server")
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func unixReset(_ value: Any?) throws -> Date? {
        guard let value = value, !(value is NSNull) else { return nil }
        guard let seconds = number(value), seconds >= 0 else { throw ProviderError.invalidResponse("Codex returned an invalid reset date. Update Codex and retry.") }
        return Date(timeIntervalSince1970: seconds)
    }
}

final class ProviderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}
