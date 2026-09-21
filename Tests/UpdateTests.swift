import Foundation

private final class ReleaseProtocol: URLProtocol {
    static var responseCode = 200
    static var body = Data()
    static var failure: Error?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let error = Self.failure {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum UpdateTests {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReleaseProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ReleaseProtocol.body = Data(#"{"tag_name":"v1.0.10","draft":false,"prerelease":false}"#.utf8)
        let update = try await GitHubUpdates.fetch(installedVersion: "1.0.9", session: session)
        guard update?.version == "1.0.10" else { fatalError("Newer release 1.0.10 must be offered to installed 1.0.9") }
        precondition(update?.url.absoluteString == "https://github.com/deniskrainovic/agents-panel/releases/tag/v1.0.10")
        print("PASS: newer numeric version offers the matching release page")
        for (name, installed, tag, expected) in [
            ("patch update", "1.0.9", "v1.0.10", true),
            ("patch jump", "1.0.1", "v1.0.99", true),
            ("minor update with patch reset", "1.9.99", "v1.10.0", true),
            ("minor jump", "1.2.50", "v1.20.0", true),
            ("major update with minor and patch reset", "1.99.99", "v2.0.0", true),
            ("major jump", "1.99.99", "v10.0.0", true),
            ("first stable version", "0.99.99", "v1.0.0", true),
            ("zero major minor update", "0.9.99", "v0.10.0", true),
            ("equal version", "1.0.10", "v1.0.10", false),
            ("older patch", "1.0.10", "v1.0.9", false),
            ("older minor with higher patch", "1.10.0", "v1.9.99", false),
            ("older major with higher minor and patch", "2.0.0", "v1.99.99", false),
            ("numeric major ordering", "10.0.0", "v9.99.99", false),
            ("tag without v prefix", "1.0.9", "1.0.10", true),
            ("beta suffix", "1.0.9", "v1.0.10-beta.1", false),
            ("release candidate", "1.0.9", "v2.0.0-rc.1", false),
            ("unsupported build metadata", "1.0.9", "v1.0.10+build.1", false),
            ("leading zero", "1.0.9", "v01.0.10", false),
            ("missing patch", "1.0.9", "v1.1", false),
            ("extra component", "1.0.9", "v1.0.10.1", false),
            ("empty component", "1.0.9", "v1..10", false),
            ("negative number", "1.0.9", "v2.0.-1", false),
            ("integer overflow", "1.0.9", "v1.0.999999999999999999999", false),
            ("trailing whitespace", "1.0.9", "v1.0.10 ", false),
            ("invalid tag path", "1.0.9", "v1.0.10/../../other", false),
            ("invalid installed version", "unknown", "v1.0.10", false)
        ] {
            ReleaseProtocol.body = try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": false, "prerelease": false])
            let value = try await GitHubUpdates.fetch(installedVersion: installed, session: session)
            precondition((value != nil) == expected, "Failed \(name): installed \(installed), tag \(tag)")
            if let value { precondition(value.url.lastPathComponent == tag, "Link must preserve the actual release tag") }
        }
        let missingInstalledVersion = try await GitHubUpdates.fetch(installedVersion: nil, session: session)
        precondition(missingInstalledVersion == nil, "Do not guess the version of an unbundled executable")
        print("PASS: 26 version cases covering major, minor, patch, equal, older, and invalid releases")
        for (draft, prerelease) in [(true, false), (false, true)] {
            ReleaseProtocol.body = try JSONSerialization.data(withJSONObject: ["tag_name": "v2.0.0", "draft": draft, "prerelease": prerelease])
            let value = try await GitHubUpdates.fetch(installedVersion: "1.0.9", session: session)
            precondition(value == nil, "Do not offer draft or prerelease builds")
        }
        for code in [403, 404, 429, 500] {
            ReleaseProtocol.responseCode = code
            do {
                _ = try await GitHubUpdates.fetch(installedVersion: "1.0.9", session: session)
                fatalError("Accepted failed GitHub response \(code)")
            } catch {}
        }
        ReleaseProtocol.responseCode = 200
        ReleaseProtocol.body = Data("not-json".utf8)
        do {
            _ = try await GitHubUpdates.fetch(installedVersion: "1.0.9", session: session)
            fatalError("Accepted malformed response")
        } catch {}
        ReleaseProtocol.failure = URLError(.notConnectedToInternet)
        do {
            _ = try await GitHubUpdates.fetch(installedVersion: "1.0.9", session: session)
            fatalError("Accepted offline response")
        } catch {}
        ReleaseProtocol.failure = nil
        print("PASS: numeric ordering, stable releases, exact links, HTTP and network failures")
        let probe = UpdateProbe()
        let checker = UpdateChecker(fetch: { try probe.fetch() }, now: { probe.date })
        checker.start()
        checker.start()
        for _ in 0..<100 {
            if probe.calls == 1 && !checker.isChecking { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(probe.calls == 1 && checker.available?.version == "1.0.10", "Startup must check for a newer release")
        probe.advance(by: 86_399)
        await checker.checkIfDue()
        precondition(probe.calls == 1, "Do not check again before 24 hours")
        probe.advance(by: 1)
        await checker.checkIfDue()
        precondition(probe.calls == 2, "Check again when 24 hours have elapsed")
        print("PASS: startup and daily checks")
        probe.fail = true
        probe.advance(by: 86_400)
        await checker.checkIfDue()
        precondition(checker.available?.version == "1.0.10" && !checker.isChecking, "Offline check must retain a known update without blocking")
        await checker.checkIfDue()
        precondition(probe.calls == 3, "Failures must not trigger repeated immediate retries")
        probe.fail = false
        probe.result = nil
        probe.advance(by: 86_400)
        await checker.checkIfDue()
        precondition(checker.available == nil && probe.calls == 4, "Successful no-update result must clear a withdrawn update")
        let gate = UpdateGate()
        let waiting = UpdateChecker(fetch: { await gate.fetch() })
        let first = Task { await waiting.checkIfDue() }
        while !waiting.isChecking { await Task.yield() }
        await waiting.checkIfDue()
        while await gate.calls == 0 { await Task.yield() }
        let calls = await gate.calls
        precondition(calls == 1, "Overlapping checks must share the in-flight request")
        await gate.release()
        await first.value
        precondition(!waiting.isChecking && waiting.available?.version == "1.0.10")
        print("PASS: quiet failures, retained updates, recovery, and in-flight coalescing")
    }
}

private final class UpdateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_000_000)
    private var count = 0
    // Mutated only by the main-actor test, between completed requests.
    var fail = false
    var result: AppUpdate? = AppUpdate(tag: "v1.0.10")
    var date: Date { lock.lock(); defer { lock.unlock() }; return time }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func advance(by interval: TimeInterval) { lock.lock(); time.addTimeInterval(interval); lock.unlock() }
    func fetch() throws -> AppUpdate? {
        lock.lock(); defer { lock.unlock() }
        count += 1
        if fail { throw URLError(.notConnectedToInternet) }
        return result
    }
}

private actor UpdateGate {
    private var continuation: CheckedContinuation<AppUpdate?, Never>?
    private(set) var calls = 0
    func fetch() async -> AppUpdate? {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: AppUpdate(tag: "v1.0.10")); continuation = nil }
}
