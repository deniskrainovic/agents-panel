import Foundation
import Darwin
@main struct ProviderFixtureTest {
    static func main() async throws {
        for mode in ["modern", "legacy", "bad", "error", "exit"] {
            setenv("PROVIDER_TEST_MODE", mode, 1)
            do {
                let value = try await Providers.fetch("codex")
                precondition(mode == "modern" || mode == "legacy")
                precondition(value.plan == "pro" && value.windows.count == 2)
                precondition(value.windows[0].name == "Weekly" && value.windows[0].usedPercent == 42)
                precondition(value.windows[1].name == "5-hour session" && value.windows[1].resetsAt == nil)
                let roundTrip = try JSONDecoder().decode(Subscription.self, from: JSONEncoder().encode(value))
                precondition(roundTrip.windows.count == 2)
            } catch {
                precondition(["bad", "error", "exit"].contains(mode))
                precondition(!error.localizedDescription.contains("SECRET"))
            }
            print("PASS \(mode)")
        }
        let claude = try await Providers.fetch("claude")
        precondition(claude.source == "Claude Code CLI")
        precondition(claude.windows.map(\.name) == ["5-hour session", "Weekly", "Weekly · Fable"])
        precondition(claude.windows.map(\.usedPercent) == [1.5, 32, 55])
        precondition(claude.windows.allSatisfy { $0.resetsAt != nil })
        print("PASS Claude CLI subscription windows")
        for mode in ["expired", "exit", "missing", "boolean", "bad-date", "broken", "inference", "oversized"] {
            setenv("CLAUDE_TEST_MODE", mode, 1)
            do { _ = try await Providers.fetch("claude"); fatalError("Accepted invalid Claude output: \(mode)") }
            catch { precondition(!error.localizedDescription.contains("SECRET")) }
        }
        setenv("CLAUDE_TEST_MODE", "null-date", 1)
        let noReset = try await Providers.fetch("claude")
        precondition(noReset.windows.first?.resetsAt == nil)
        setenv("CLAUDE_TEST_MODE", "valid", 1)
        let recovered = try await Providers.fetch("claude")
        precondition(recovered.windows.count == 3)
        print("PASS Claude errors, missing limits, malformed output, null resets, safe errors, and recovery")
        for mode in ["wrapper", "wrapper-exit"] {
            try? FileManager.default.removeItem(atPath: "claude-child.pid")
            setenv("CLAUDE_TEST_MODE", mode, 1)
            let wrapperTask = Task { try await Providers.fetch("claude") }
            for _ in 0..<2000 {
                if FileManager.default.fileExists(atPath: "claude-child.pid") { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            wrapperTask.cancel()
            do { _ = try await wrapperTask.value; fatalError("Wrapper cancellation failed") }
            catch is CancellationError { }
            try await Task.sleep(nanoseconds: 300_000_000)
            let descendant = Int32(try String(contentsOfFile: "claude-child.pid"))!
            let leaked = kill(descendant, 0) == 0
            if leaked { kill(descendant, SIGKILL) }
            precondition(!leaked, "Cancelling Claude left its worker process running")
        }
        print("PASS Claude wrapper descendant cleanup")
        setenv("CLAUDE_TEST_MODE", "hang", 1)
        let claudeTask = Task { try await Providers.fetch("claude") }
        try await Task.sleep(nanoseconds: 300_000_000)
        claudeTask.cancel()
        do { _ = try await claudeTask.value; fatalError("Claude cancellation failed") }
        catch is CancellationError { }
        let claudeDeadline = Date()
        do { _ = try await Providers.fetch("claude"); fatalError("Claude timeout failed") }
        catch ProviderError.timeout { }
        precondition(Date().timeIntervalSince(claudeDeadline) >= 25)
        try await Task.sleep(nanoseconds: 300_000_000)
        let claudePID = Int32(try String(contentsOfFile: "claude.pid"))!
        precondition(kill(claudePID, 0) == -1 && errno == ESRCH)
        print("PASS Claude cancellation, deadline, and forced process cleanup")

        setenv("PROVIDER_TEST_MODE", "hang", 1)
        let start = Date()
        let task = Task { try await Providers.fetch("codex") }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do { _ = try await task.value; fatalError("Expected cancellation") }
        catch is CancellationError { }
        precondition(Date().timeIntervalSince(start) < 2)
        print("PASS cancellation")
        let timeoutStart = Date()
        do { _ = try await Providers.fetch("codex"); fatalError("Expected timeout") }
        catch ProviderError.timeout { }
        let elapsed = Date().timeIntervalSince(timeoutStart)
        precondition(elapsed >= 24 && elapsed < 27)
        print("PASS deadline \(elapsed)s")
        try await Task.sleep(nanoseconds: 300_000_000)
        let pid = Int32(try String(contentsOfFile: "mock.pid"))!
        precondition(kill(pid, 0) == -1 && errno == ESRCH)
        print("PASS subprocess cleanup")
    }
}
