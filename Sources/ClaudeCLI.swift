import Foundation
import Darwin

enum ClaudeCLI {
    private typealias Object = [String: Any]

    static func fetch(_ cancellation: ProviderCancellation) throws -> Subscription {
        let executable = try executableURL()
        let process = Process()
        let output = Pipe()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentsPanel-Claude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        process.executableURL = executable
        // Only execute the built-in command. No hooks/plugins or saved conversation.
        process.arguments = ["--safe-mode", "--no-session-persistence", "-p", "/usage", "--output-format", "json"]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" +
            (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        // CLI diagnostics can contain account information; never display them.
        process.standardError = FileHandle.nullDevice
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        var processGroup: pid_t?
        func check() throws {
            try cancellation.check()
            if ProcessInfo.processInfo.systemUptime >= deadline { throw ProviderError.timeout("Claude") }
        }
        defer {
            if let group = processGroup {
                // Foundation gives launched tasks their own process group on
                // macOS. Verify it before signaling, then include CLI workers
                // even if the original wrapper has already exited.
                kill(-group, SIGTERM)
                let grace = ProcessInfo.processInfo.systemUptime + 0.2
                while kill(-group, 0) == 0 && ProcessInfo.processInfo.systemUptime < grace {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if kill(-group, 0) == 0 { kill(-group, SIGKILL) }
            } else if process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        try check()
        do { try process.run() } catch {
            throw ProviderError.unavailable("Could not start Claude Code. Update or reinstall the Claude CLI, then retry.")
        }
        let group = getpgid(process.processIdentifier)
        // A short-lived wrapper may already have exited. Its Foundation-created
        // group still has this ID while any descendants retain the output pipe.
        if group == process.processIdentifier || (group == -1 && errno == ESRCH) {
            processGroup = process.processIdentifier
        }
        try? output.fileHandleForWriting.close()
        let reader = output.fileHandleForReading.fileDescriptor
        guard fcntl(reader, F_SETFL, O_NONBLOCK) != -1 else {
            throw ProviderError.transport("Could not read the Claude Code process. Restart AgentsPanel and retry.")
        }
        var data = Data()
        while true {
            try check()
            var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw ProviderError.transport("Could not read Claude Code usage. Retry later.") }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(reader, &bytes, bytes.count)
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
                guard data.count <= 4 * 1024 * 1024 else {
                    throw ProviderError.invalidResponse("Claude Code returned oversized usage data. Update Claude Code and retry.")
                }
            } else if count == 0 { break }
            else if errno != EAGAIN && errno != EINTR {
                throw ProviderError.transport("The Claude Code connection failed. Retry later.")
            }
        }
        while process.isRunning { try check(); Thread.sleep(forTimeInterval: 0.01) }
        try check()
        guard process.terminationStatus == 0 else {
            throw ProviderError.unavailable("Claude Code could not read usage. Run claude -p \"/usage\" in Terminal; sign in with /login or update Claude Code if needed.")
        }
        return try parse(data)
    }

    private static func executableURL() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                     "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude", "\(home)/.volta/bin/claude"]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        let versions = (ProcessInfo.processInfo.environment["NVM_DIR"] ?? "\(home)/.nvm") + "/versions/node"
        let nodes = (try? FileManager.default.contentsOfDirectory(atPath: versions)) ?? []
        paths += nodes.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(versions)/\($0)/bin/claude" }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ProviderError.unavailable("Claude Code CLI was not found. Install Claude Code and sign in with claude auth login.")
        }
        return URL(fileURLWithPath: path)
    }

    private static func parse(_ data: Data) throws -> Subscription {
        guard let decoded = try? JSONSerialization.jsonObject(with: data) else {
            throw ProviderError.invalidResponse("Claude Code returned invalid usage data. Update Claude Code and retry.")
        }
        let rows = (decoded as? [Object]) ?? (decoded as? Object).map { [$0] } ?? []
        guard let result = rows.last(where: { $0["type"] as? String == "result" }) else {
            throw ProviderError.invalidResponse("Claude Code returned no usage result. Update Claude Code and retry.")
        }
        guard result["is_error"] as? Bool == false else {
            throw ProviderError.authentication("Claude Code could not read your subscription. Renew your login with /login in Claude Code, then refresh.")
        }
        guard result["local_command"] as? String == "usage",
              number(result["num_turns"]) == 0, number(result["duration_api_ms"]) == 0 else {
            throw ProviderError.invalidResponse("Claude Code did not return built-in usage data. Update Claude Code and retry.")
        }
        let report = rows.reversed().first { ($0["local_command_run"] as? Object)?["command"] as? String == "usage" }?["usage_report"] as? Object
        guard let rateLimits = report?["rate_limits"] as? Object,
              let limits = rateLimits["limits"] as? [Object], !limits.isEmpty else {
            throw ProviderError.unavailable("Claude Code returned no subscription limits. Run claude -p \"/usage\" in Terminal and check your subscription login; update Claude Code if needed.")
        }
        var windows: [UsageWindow] = []
        for limit in limits {
            guard let kind = limit["kind"] as? String else {
                throw ProviderError.invalidResponse("Claude Code returned an invalid usage window. Update Claude Code and retry.")
            }
            let name: String
            switch kind {
            case "session": name = "5-hour session"
            case "weekly_all": name = "Weekly"
            case "weekly_scoped":
                guard let scope = limit["scope"] as? Object, let model = scope["model"] as? Object,
                      let displayName = model["display_name"] as? String, !displayName.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ProviderError.invalidResponse("Claude Code returned an unnamed model limit. Update Claude Code and retry.")
                }
                name = "Weekly · " + displayName
            default: continue
            }
            guard let used = number(limit["percent"]), used >= 0 else {
                throw ProviderError.invalidResponse("Claude Code returned an invalid usage percentage. Update Claude Code and retry.")
            }
            windows.append(UsageWindow(name: name, usedPercent: used, resetsAt: try resetDate(limit["resets_at"])))
        }
        guard !windows.isEmpty else { throw ProviderError.unavailable("Claude Code returned no supported subscription limits. Update Claude Code and retry.") }
        // The usage report exposes limits, not the account's plan name or tier.
        return Subscription(plan: "Subscription", windows: windows, updatedAt: Date(), source: "Claude Code CLI")
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    private static func resetDate(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw ProviderError.invalidResponse("Claude Code returned an invalid reset time.") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { throw ProviderError.invalidResponse("Claude Code returned an invalid reset time.") }
        return date
    }
}
