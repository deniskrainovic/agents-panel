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
        let fixture: [String: Any] = [
            "five_hour": ["utilization": 0.5, "resets_at": "2026-09-18T12:00:00.123Z"],
            "seven_day": ["utilization": 37, "resets_at": "2026-09-19T12:00:00Z"],
            "seven_day_oauth_apps": NSNull(),
            "seven_day_breakdown": ["rows": [], "as_of": "2026-09-17T12:00:00Z"],
            "seven_day_opus": NSNull(),
            "limits": [["scope": ["model": ["display_name": "Fable"]], "kind": "weekly_scoped", "percent": 15, "resets_at": NSNull()]]
        ]
        let claude = try Providers.parseClaudeUsage(fixture, credentials: ["subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"])
        precondition(claude.plan == "Max 5X")
        precondition(claude.windows.count == 3)
        precondition(claude.windows[0].name == "5-hour session" && claude.windows[0].usedPercent == 0.5)
        precondition(claude.windows[0].resetsAt != nil && claude.windows[1].resetsAt != nil)
        precondition(claude.windows[2].name == "Weekly · Fable")
        do {
            _ = try Providers.parseClaudeUsage([:], credentials: [:])
            fatalError("Missing usage must not become zero")
        } catch ProviderError.unavailable { }
        print("PASS Claude schema, nulls, dates, metadata, scoped limits, fractional percentages")
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
