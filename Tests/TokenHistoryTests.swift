import Foundation

// Standalone test executable; intentionally requires no package test target.
// swiftc -swift-version 5 Sources/TokenHistory.swift Tests/TokenHistoryTests.swift -o /tmp/token-history-tests
@main
struct TokenHistoryTests {
    static let fm = FileManager.default
    static let calendar = Calendar.current
    static let today = calendar.startOfDay(for: Date())
    static let formatter = ISO8601DateFormatter()

    static func timestamp(_ offset: Int, _ seconds: Int = 3600) -> String {
        formatter.string(from: calendar.date(byAdding: .day, value: offset, to: today)!
            .addingTimeInterval(TimeInterval(seconds)))
    }

    static func event(_ total: Int, _ last: Int, _ day: Int = 0, _ second: Int = 3600) -> [String: Any] {
        ["type": "event_msg", "timestamp": timestamp(day, second),
         "payload": ["type": "token_count", "info": [
            "total_token_usage": ["total_tokens": total],
            "last_token_usage": ["total_tokens": last]]]]
    }

    static func message(_ id: String?, _ request: String?, _ output: Int,
                        _ day: Int = 0, _ second: Int = 3600) -> [String: Any] {
        var m: [String: Any] = ["model": "claude-test", "usage": [
            "input_tokens": 10, "output_tokens": output,
            "cache_creation_input_tokens": 20, "cache_read_input_tokens": 30,
            "output_tokens_details": ["thinking_tokens": 999],
            "cache_creation": ["ephemeral_1h_input_tokens": 20]]]
        if let id = id { m["id"] = id }
        var o: [String: Any] = ["type": "assistant", "timestamp": timestamp(day, second), "message": m]
        if let request = request { o["requestId"] = request }
        return o
    }

    static func write(_ home: URL, _ path: String, _ rows: [[String: Any]]) throws -> URL {
        let file = home.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(10)
        }
        try data.write(to: file)
        return file
    }

    static func total(_ history: TokenHistory) -> Int { history.days.reduce(0) { $0 + $1.tokens } }

    static func main() throws {
        let home = fm.temporaryDirectory.appendingPathComponent("token-parser-tests-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        // Also compile-check the default memberwise initializers used by previews.
        let preview = TokenHistory(days: [TokenDay(date: today, tokens: 1)],
                                   models: [TokenModel(name: "preview", tokens: 1)], fileCount: 1)
        precondition(total(preview) == 1)
        precondition(TokenHistory.load(provider: "invalid", home: home).days.count == 7)

        let meta: [String: Any] = ["type": "session_meta", "payload": ["id": "fixture-session"]]
        let context: [String: Any] = ["type": "turn_context", "payload": ["model": "codex-test"]]
        let modern: [String: Any] = ["type": "token_usage_record", "timestamp": timestamp(0, 3700),
            "payload": ["response_id": "response-1", "usage": ["total_tokens": 20],
                        "thread_token_usage": ["total_tokens": 1_000_070]]]
        let codexRows = [meta, context,
                         event(1_000_000, 100, -7), // baseline outside window
                         event(1_000_030, 30, -6), // inclusive first day
                         event(1_000_030, 30, -6, 3700), // repeated cumulative count
                         event(1_000_050, 20), modern,
                         event(1_000_070, 20, 0, 3701), // mirrors modern record
                         event(5, 5, 0, 3800), // actual counter reset
                         event(5, 5, 0, 3801),
                         event(12, 7, 0, 3900),
                         event(112, 100, 1)] // future calendar day excluded
        let codexFile = try write(home, ".codex/sessions/a.jsonl", codexRows)
        _ = try write(home, ".codex/archived_sessions/copied.jsonl", codexRows)
        _ = try write(home, ".codex/archived_sessions/other.jsonl", [
            ["type": "session_meta", "payload": ["id": "archived-other"]], context,
            event(9, 9)])
        let old = try write(home, ".codex/sessions/old.jsonl", [event(99999, 99999)])
        try fm.setAttributes([.modificationDate: today.addingTimeInterval(-10 * 86400)], ofItemAtPath: old.path)
        _ = try write(home, ".codex/sessions/truncated-history.jsonl", [
            ["type": "session_meta", "payload": ["id": "truncated-session"]], context,
            event(9_000_000, 11)])
        var codex = TokenHistory.load(provider: "codex", home: home)
        precondition(codex.fileCount == 5)
        precondition(total(codex) == 102, "Codex expected 102, got \(total(codex))")
        precondition(codex.days.first!.tokens == 30)
        precondition(codex.models.count == 1 && codex.models[0].tokens == 102)
        precondition(codex.days.map(\.date) == (-6...0).map { calendar.date(byAdding: .day, value: $0, to: today)! })

        let claudeRows = [message("message-a", "request-a", 1),
                          message("message-a", "request-a", 8),
                          message("message-a", nil, 4),
                          message(nil, "request-a", 6),
                          message("message-b", "request-b", 2, -6),
                          message("old", "old-request", 5000, -7),
                          message("future", "future-request", 5000, 1),
                          message("midnight", "midnight-request", 1, -1, 86399),
                          message("midnight", "midnight-request", 3, 0, 0)]
        let claudeFile = try write(home, ".claude/projects/p/a.jsonl", claudeRows)
        _ = try write(home, ".claude/projects/p/subagents/copy.jsonl", claudeRows)
        var claude = TokenHistory.load(provider: "claude", home: home)
        precondition(total(claude) == 193, "Claude expected 193, got \(total(claude))")
        precondition(claude.days[5].tokens == 63, "Midnight stream uses earliest timestamp")
        precondition(claude.models[0].tokens == 193)
        precondition(claude.fileCount == 2)
        precondition(total(TokenHistory.load(provider: "codex", home: home)) == 102)
        precondition(total(TokenHistory.load(provider: "claude", home: home)) == 193)

        // Missing both IDs: distinct lines must not silently collapse by timestamp.
        _ = try write(home, ".claude/projects/no-id.jsonl", [message(nil, nil, 1), message(nil, nil, 1)])
        claude = TokenHistory.load(provider: "claude", home: home)
        precondition(total(claude) == 315)
        // Append plus malformed/incomplete records must invalidate the cached summary.
        let handle = try FileHandle(forWritingTo: claudeFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("malformed\n".utf8))
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: message("new", "new-request", 10)))
        try handle.write(contentsOf: Data("\n{\"type\":".utf8))
        try handle.close()
        precondition(total(TokenHistory.load(provider: "claude", home: home)) == 385)
        // Deletion and truncation are visible on the next scan.
        try fm.removeItem(at: codexFile)
        try fm.removeItem(at: home.appendingPathComponent(".codex/archived_sessions/copied.jsonl"))
        codex = TokenHistory.load(provider: "codex", home: home)
        precondition(total(codex) == 20 && codex.fileCount == 3)
        _ = try write(home, ".codex/sessions/truncated-history.jsonl", [])
        precondition(total(TokenHistory.load(provider: "codex", home: home)) == 9)
        let overlapHome = home.appendingPathComponent("overlap")
        let overlapRows = [meta, context, event(10, 10, -2), event(20, 10, -1), event(30, 10)]
        _ = try write(overlapHome, ".codex/sessions/full.jsonl", overlapRows)
        precondition(total(TokenHistory.load(provider: "codex", home: overlapHome)) == 30)
        _ = try write(overlapHome, ".codex/archived_sessions/partial.jsonl", [meta, context, event(10, 10, -2), event(30, 10)])
        let overlap = TokenHistory.load(provider: "codex", home: overlapHome)
        precondition(total(overlap) == 30, "Partial copy inflated total: \(total(overlap))")
        precondition(Array(overlap.days.suffix(3)).map(\.tokens) == [10, 10, 10])
        precondition(overlap.models[0].tokens == 30)
        precondition(total(TokenHistory.load(provider: "codex", home: overlapHome)) == 30)
        let gapHome = home.appendingPathComponent("counter-gap")
        _ = try write(gapHome, ".codex/sessions/truncated.jsonl", [meta, context, event(100, 10, -1)])
        _ = try write(gapHome, ".codex/archived_sessions/full.jsonl", [meta, context, event(200, 200)])
        precondition(total(TokenHistory.load(provider: "codex", home: gapHome)) == 200, "A truncated counter must not hide an earlier uncovered interval")
        print("PASS: memberwise initializers, seven calendar days, old baseline, cumulative duplicates, resets, modern/legacy overlap, archived copies, first lifetime counter, old mtime skip, Claude aliases/max usage, cache components, midnight, missing IDs, malformed tails, append/delete/truncate.")

        if CommandLine.arguments.contains("--live") {
            for pass in 1...2 {
                for provider in ["codex", "claude"] {
                    let start = Date()
                    let history = TokenHistory.load(provider: provider)
                    print("LIVE pass=\(pass) provider=\(provider) seconds=\(String(format: "%.3f", Date().timeIntervalSince(start))) files=\(history.fileCount) tokens7days=\(total(history)) models=\(history.models.count)")
                }
            }
        }
    }
}
