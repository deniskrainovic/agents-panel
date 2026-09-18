import Foundation

private actor AuthenticationGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func release() { for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}
private actor RenewableLogin {
    var expired = false
    func setExpired(_ value: Bool) { expired = value }
    func fetch() throws -> Subscription {
        if expired { throw ProviderError.authentication("Renew your login in Claude Code, then refresh.") }
        return Subscription(plan: "Subscription", windows: [], updatedAt: Date(), source: "Fixture")
    }
}
private final class HistoryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func scan(_ provider: String) -> TokenHistory {
        lock.lock(); defer { lock.unlock() }
        counts[provider, default: 0] += 1
        return TokenHistory(days: [TokenDay(date: Date(), tokens: counts[provider]!)], models: [], fileCount: 1)
    }
}
@main enum StoreRefreshTests {
    @MainActor static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }
    @MainActor static func main() async {
        let gate = AuthenticationGate()
        let fixture = HistoryFixture()
        let store = Store(fetchSubscription: { _ in
            await gate.wait()
            return Subscription(plan: "Fixture", windows: [], updatedAt: Date(), source: "Fixture")
        }, readHistory: { fixture.scan($0) })
        store.refresh()
        store.refresh()
        store.refresh()
        guard await eventually({ store.histories.count == 2 }) else { fatalError("Initial scan failed") }
        precondition(store.histories.values.allSatisfy { $0.days.first?.tokens == 1 }, "Overlapping scans were not coalesced")
        precondition(store.loading.count == 2)
        store.refresh()
        guard await eventually({ store.histories[.claude]?.days.first?.tokens == 2 && store.histories[.codex]?.days.first?.tokens == 2 }) else {
            print("FAIL: pending authentication prevented a second local history refresh")
            exit(1)
        }
        precondition(store.loading.count == 2)
        await gate.release()
        guard await eventually({ store.loading.isEmpty }) else { fatalError("Provider completion failed") }
        print("PASS: local histories refresh while authentication is pending")
        let login = RenewableLogin()
        let recovery = Store(fetchSubscription: { _ in try await login.fetch() }, readHistory: { fixture.scan($0) })
        recovery.refresh()
        guard await eventually({ recovery.loading.isEmpty && recovery.historyLoading.isEmpty }) else { fatalError("Initial login failed") }
        precondition(recovery.subscriptions[.claude] != nil)
        await login.setExpired(true)
        recovery.refresh()
        guard await eventually({ recovery.loading.isEmpty && recovery.historyLoading.isEmpty }) else { fatalError("Expiry did not complete") }
        precondition(recovery.errors[.claude] != nil && recovery.subscriptions[.claude] != nil)
        precondition(recovery.histories[.claude]?.days.first?.tokens == 4)
        await login.setExpired(false)
        recovery.refresh()
        guard await eventually({ recovery.loading.isEmpty && recovery.historyLoading.isEmpty }) else { fatalError("Renewal did not complete") }
        precondition(recovery.errors[.claude] == nil && recovery.subscriptions[.claude] != nil)
        print("PASS: expired login retains previous data, local history updates, and renewed login clears the error")
    }
}
