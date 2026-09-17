import Foundation

struct TokenDay {
    let date: Date
    let tokens: Int
}

struct TokenModel {
    let name: String
    let tokens: Int
}

struct TokenHistory {
    let days: [TokenDay]
    let models: [TokenModel]
    /// Number of discovered JSONL files (including files with no recent usage).
    let fileCount: Int

    /// Synchronous disk IO: call from a background task, or use loadAsync.
    /// Includes today and the preceding six days in the user's current calendar.
    static func load(provider: String,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> TokenHistory {
        TokenHistoryParser.load(provider: provider.lowercased(), home: home)
    }

    /// Delivers on the main queue; scanning and parsing always run off the main thread.
    static func loadAsync(provider: String,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          completion: @escaping (TokenHistory) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = load(provider: provider, home: home)
            DispatchQueue.main.async { completion(result) }
        }
    }
}

private enum TokenHistoryParser {
    typealias Object = [String: Any]

    private struct Sample {
        let keys: [String]
        let date: Date
        let model: String
        var tokens: Int
        var counter: CounterRange? = nil
    }

    private struct CounterRange {
        let scope: String
        let lower: Int
        let upper: Int
    }

    private struct CachedFile {
        let size: Int
        let modified: Date
        let samples: [Sample]
    }

    // Independent home/provider caches prevent alternating dashboard loads from
    // invalidating one another. Each scope retains only its latest relevant files.
    private static let lock = NSLock()
    private static var caches: [String: [String: CachedFile]] = [:]

    static func load(provider: String, home: URL) -> TokenHistory {
        lock.lock()
        defer { lock.unlock() }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dates = (-6...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        guard let start = dates.first,
              let end = calendar.date(byAdding: .day, value: 1, to: today) else {
            return TokenHistory(days: [], models: [], fileCount: 0)
        }
        let roots: [String]
        switch provider {
        case "codex": roots = [".codex/sessions", ".codex/archived_sessions"]
        case "claude": roots = [".claude/projects"]
        default:
            return TokenHistory(days: dates.map { TokenDay(date: $0, tokens: 0) },
                                models: [], fileCount: 0)
        }

        let fm = FileManager.default
        let scope = provider + ":" + home.standardizedFileURL.path
        let cache = caches[scope] ?? [:]
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var files = Set<URL>()
        for root in roots {
            guard let enumerator = fm.enumerator(at: home.appendingPathComponent(root),
                                                includingPropertiesForKeys: resourceKeys,
                                                options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in enumerator where file.pathExtension.lowercased() == "jsonl" {
                files.insert(file.standardizedFileURL)
            }
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            guard let value = value as? String else { return nil }
            return fractional.date(from: value) ?? whole.date(from: value)
        }

        var nextCache: [String: CachedFile] = [:]
        var all: [Sample] = []
        var fileCount = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let values = try? file.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true else { continue }
            fileCount += 1
            let key = provider + ":" + file.path
            let size = values.fileSize ?? -1
            let modified = values.contentModificationDate ?? .distantPast
            // Optimization assumes normal filesystem/log timestamps. Imported logs
            // with artificially old mtimes are intentionally outside this fast scan.
            if values.contentModificationDate != nil, modified < start { continue }
            if let cached = cache[key], size >= 0, cached.size == size, cached.modified == modified {
                nextCache[key] = cached
                all.append(contentsOf: cached.samples)
                continue
            }
            let samples = parse(file: file, provider: provider, date: date)
            all.append(contentsOf: samples)
            // Do not cache a file that changed during the scan or could not be opened.
            if fm.isReadableFile(atPath: file.path), size >= 0,
               let after = try? fm.attributesOfItem(atPath: file.path),
               (after[.size] as? NSNumber)?.intValue == size,
               after[.modificationDate] as? Date == modified {
                nextCache[key] = CachedFile(size: size, modified: modified, samples: samples)
            }
        }
        caches[scope] = nextCache

        // Reconcile overlapping counter intervals across session copies before
        // deduplicating aliases or filtering days. Earlier endpoints preserve the
        // finer day/model attribution from the most complete available history.
        var coveredRanges: [String: [Range<Int>]] = [:]
        let counters = all.indices.filter { all[$0].counter != nil }.sorted {
            let lhs = all[$0].counter!, rhs = all[$1].counter!
            if lhs.upper != rhs.upper { return lhs.upper < rhs.upper }
            if lhs.lower != rhs.lower { return lhs.lower < rhs.lower }
            return $0 < $1
        }
        for index in counters {
            let range = all[index].counter!
            var covered = coveredRanges[range.scope] ?? []
            var lower = range.lower
            var tokens = range.upper - range.lower
            // Preserve gaps from truncated logs: a later, wider interval can
            // supply tokens on either side of a previously observed interval.
            while let previous = covered.last, previous.upperBound >= lower {
                tokens -= max(0, min(range.upper, previous.upperBound) - max(range.lower, previous.lowerBound))
                lower = min(lower, previous.lowerBound)
                covered.removeLast()
            }
            covered.append(lower..<range.upper)
            all[index].tokens = tokens
            coveredRanges[range.scope] = covered
        }

        // Union aliases before filtering dates: a streamed reply can straddle midnight,
        // and copied logs can contain only one of its message/request identifiers.
        var parents = Array(all.indices)
        func root(_ index: Int) -> Int {
            var i = index
            while parents[i] != i {
                parents[i] = parents[parents[i]]
                i = parents[i]
            }
            return i
        }
        var aliases: [String: Int] = [:]
        for (i, sample) in all.enumerated() {
            for key in sample.keys {
                if let other = aliases[key] { parents[root(i)] = root(other) }
                else { aliases[key] = i }
            }
        }
        var best: [Int: Sample] = [:]
        var firstDate: [Int: Date] = [:]
        for (i, sample) in all.enumerated() {
            let group = root(i)
            firstDate[group] = min(firstDate[group] ?? sample.date, sample.date)
            if best[group] == nil || sample.tokens > best[group]!.tokens { best[group] = sample }
        }
        var daily: [Date: Int] = [:]
        var models: [String: Int] = [:]
        for (group, sample) in best {
            let timestamp = firstDate[group] ?? sample.date
            guard timestamp >= start, timestamp < end, sample.tokens > 0 else { continue }
            let day = calendar.startOfDay(for: timestamp)
            daily[day] = add(daily[day] ?? 0, sample.tokens)
            models[sample.model] = add(models[sample.model] ?? 0, sample.tokens)
        }
        return TokenHistory(days: dates.map { TokenDay(date: $0, tokens: daily[$0] ?? 0) },
                            models: models.map { TokenModel(name: $0.key, tokens: $0.value) }
                                .sorted { $0.tokens == $1.tokens ? $0.name < $1.name : $0.tokens > $1.tokens },
                            fileCount: fileCount)
    }

    private static func parse(file: URL, provider: String,
                              date: (Any?) -> Date?) -> [Sample] {
        var samples: [Sample] = []
        var session = file.path
        var model = "Unknown"
        var previous = 0
        var epoch = "initial"
        var seen = Set<String>()
        lines(file) { data, lineNumber in
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? Object else { return }
            let type = object["type"] as? String ?? ""
            if provider == "claude" {
                guard type == "assistant", let message = object["message"] as? Object,
                      let usage = message["usage"] as? Object,
                      let timestamp = date(object["timestamp"]) else { return }
                // Provider message/request IDs are assumed globally unique. With
                // neither ID available, keep rows separate instead of guessing an
                // identity from their model, timestamp, or identical token count.
                var keys: [String] = []
                if let id = nonempty(message["id"]) { keys.append("message:" + id) }
                if let id = nonempty(object["requestId"]) ?? nonempty(object["request_id"]) {
                    keys.append("request:" + id)
                }
                if keys.isEmpty, let id = nonempty(object["uuid"]) { keys.append("uuid:" + id) }
                if keys.isEmpty { keys = [file.path + ":" + String(lineNumber)] }
                // Anthropic's input count excludes cache reads/writes. Thinking is
                // already included in output; nested cache creation is a breakdown.
                let tokens = ["input_tokens", "output_tokens", "cache_read_input_tokens",
                              "cache_creation_input_tokens"].reduce(0) { add($0, number(usage[$1]) ?? 0) }
                samples.append(Sample(keys: keys, date: timestamp,
                                      model: nonempty(message["model"]) ?? "Unknown", tokens: tokens))
                return
            }

            guard let payload = object["payload"] as? Object else { return }
            if type == "session_meta" {
                let id = nonempty(payload["session_id"]) ?? nonempty(payload["id"]) ?? session
                if id != session { previous = 0; epoch = "initial"; seen.removeAll(); model = "Unknown" }
                session = id
                if let name = nonempty(payload["model"]) { model = name }
                return
            }
            if type == "turn_context" {
                if let name = nonempty(payload["model"]) { model = name }
                return
            }
            var cumulative: Int?
            var last: Int?
            var responseID: String?
            if type == "token_usage_record" {
                cumulative = total(payload["thread_token_usage"] as? Object)
                last = total(payload["usage"] as? Object)
                responseID = nonempty(payload["response_id"])
            } else if type == "event_msg", payload["type"] as? String == "token_count",
                      let info = payload["info"] as? Object {
                cumulative = total(info["total_token_usage"] as? Object)
                last = total(info["last_token_usage"] as? Object)
            } else { return }

            let stamp = object["timestamp"] as? String ?? ""
            // Exact replay protection also prevents a replayed older counter from
            // being mistaken for a reset. Rate-limit-only events have no usage.
            let replayParts: [String] = [session, type, stamp, String(cumulative ?? -1),
                                         String(last ?? -1), responseID ?? ""]
            let replay = replayParts.joined(separator: ":")
            guard seen.insert(replay).inserted else { return }
            let tokens: Int
            var counter: CounterRange?
            var keys: [String]
            if let current = cumulative {
                if current < previous {
                    // Observed local counter resets start at the last request's usage.
                    // Ignore unexplained regressions rather than inventing new usage.
                    guard current == last else { return }
                    epoch = stamp
                    previous = 0
                }
                // A truncated/imported session may begin with a lifetime counter.
                // With no earlier baseline, attribute only its last known request.
                tokens = previous == 0 ? min(current, last ?? current) : current - previous
                counter = CounterRange(scope: session + ":" + epoch, lower: current - tokens, upper: current)
                previous = current
                keys = ["counter:" + session + ":" + epoch + ":" + String(current)]
            } else {
                guard let usage = last else { return }
                tokens = usage
                keys = ["event:" + session + ":" + stamp + ":" + String(usage)]
            }
            if let id = responseID { keys.append("response:" + id) }
            // Read counters even outside the date range (or without a valid date)
            // to establish the baseline before attributing subsequent increments.
            guard tokens > 0, let timestamp = date(object["timestamp"]) else { return }
            samples.append(Sample(keys: keys, date: timestamp,
                                  model: nonempty(payload["model"]) ?? model, tokens: tokens, counter: counter))
        }
        return samples
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func number(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let value = n.doubleValue
        guard value.isFinite, value >= 0, value < Double(Int.max), value.rounded(.down) == value else { return nil }
        return n.intValue
    }

    private static func total(_ usage: Object?) -> Int? {
        guard let usage = usage else { return nil }
        if let total = number(usage["total_tokens"]) { return total }
        let input = number(usage["input_tokens"])
        let output = number(usage["output_tokens"])
        guard input != nil || output != nil else { return nil }
        // Codex cache and reasoning counts are subsets of input/output.
        return add(input ?? 0, output ?? 0)
    }

    private static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }

    /// Stream lines instead of loading transcripts into memory. Oversized or
    /// malformed lines are skipped; an incomplete final write is retried next load.
    private static func lines(_ file: URL, consume: (Data, Int) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let limit = 16 * 1024 * 1024
        var pending = Data()
        var dropping = false
        var lineNumber = 0
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            var start = chunk.startIndex
            for index in chunk.indices where chunk[index] == 10 {
                let part = chunk[start..<index]
                lineNumber += 1
                if !dropping, pending.count + part.count <= limit {
                    pending.append(part)
                    if !pending.isEmpty { consume(pending, lineNumber) }
                }
                pending.removeAll(keepingCapacity: true)
                dropping = false
                start = chunk.index(after: index)
            }
            let tail = chunk[start..<chunk.endIndex]
            if !dropping, pending.count + tail.count <= limit { pending.append(tail) }
            else { pending.removeAll(keepingCapacity: true); dropping = true }
        }
        if !dropping, !pending.isEmpty { consume(pending, lineNumber + 1) }
    }
}
