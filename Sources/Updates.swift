import Foundation
import Combine

struct AppUpdate: Equatable, Sendable {
    let tag: String
    var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
    var url: URL { URL(string: "https://github.com/deniskrainovic/agents-panel/releases/tag/")!.appendingPathComponent(tag) }
}

enum GitHubUpdates {
    static func fetch(installedVersion: String?, session: URLSession = .shared) async throws -> AppUpdate? {
        guard let installedVersion, let installed = Version(installedVersion) else { return nil }
        let endpoint = URL(string: "https://api.github.com/repos/deniskrainovic/agents-panel/releases/latest")!
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AgentsPanel/\(installedVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let tag = release.tag_name
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !release.draft, !release.prerelease,
              let latest = Version(version), installed.parts.lexicographicallyPrecedes(latest.parts) else { return nil }
        return AppUpdate(tag: tag)
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    private struct Version {
        let parts: [Int]
        init?(_ value: String) {
            let components = value.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 3 else { return nil }
            var parsed: [Int] = []
            for component in components {
                guard !component.isEmpty,
                      component.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      component.count == 1 || component.first != "0",
                      let number = Int(component) else { return nil }
                parsed.append(number)
            }
            parts = parsed
        }
    }
}

@MainActor final class UpdateChecker: ObservableObject {
    @Published private(set) var available: AppUpdate?
    private(set) var isChecking = false
    private let fetch: @Sendable () async throws -> AppUpdate?
    private let now: @Sendable () -> Date
    init(fetch: @escaping @Sendable () async throws -> AppUpdate? = {
        try await GitHubUpdates.fetch(installedVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetch = fetch
        self.now = now
    }
    private var lastAttempt: Date?
    private var timer: Timer?
    private var started = false
    private static let interval: TimeInterval = 24 * 60 * 60

    func start() {
        guard !started else { return }
        started = true
        Task { await checkIfDue() }
    }

    func checkIfDue() async {
        let date = now()
        guard !isChecking else { return }
        if let lastAttempt, date.timeIntervalSince(lastAttempt) < Self.interval {
            scheduleNextCheck()
            return
        }
        isChecking = true
        lastAttempt = date
        defer {
            isChecking = false
            scheduleNextCheck()
        }
        do { available = try await fetch() }
        catch { /* Keep a known update visible and retry at the next daily check. */ }
    }

    private func scheduleNextCheck() {
        guard started, let lastAttempt else { return }
        timer?.invalidate()
        let delay = max(1, Self.interval - now().timeIntervalSince(lastAttempt))
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
    }

    deinit { timer?.invalidate() }
}
