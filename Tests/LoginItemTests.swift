import Foundation

@main enum LoginItemTests {
    @MainActor static func waitForStatus(_ store: Store) async {
        for _ in 0..<400 {
            if !store.loginItemBusy { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        fatalError("Login item status did not settle")
    }

    @MainActor static func main() async {
        let suite = "AgentsPanel.LoginItemTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = LoginFixture()
        let store = Store(readLoginStatus: { fixture.read() }, setLoginStatus: { try fixture.set($0) }, loginDefaults: defaults)
        store.refreshLoginStatus(enableByDefault: true)
        store.refreshLoginStatus(enableByDefault: true)
        await waitForStatus(store)
        precondition(store.launchAtLoginEnabled == true && fixture.writes == [true], "First launch must enable launch at login")
        precondition(!fixture.usedMainThread, "System registration must run off the main thread")
        print("PASS: first launch enables login item in the background and coalesces repeated calls")
        store.launchAtLogin()
        await waitForStatus(store)
        precondition(store.launchAtLoginEnabled == false && fixture.writes == [true, false])
        let restarted = Store(readLoginStatus: { fixture.read() }, setLoginStatus: { try fixture.set($0) }, loginDefaults: defaults)
        restarted.refreshLoginStatus(enableByDefault: true)
        await waitForStatus(restarted)
        precondition(restarted.launchAtLoginEnabled == false && fixture.writes == [true, false], "Restart must preserve an explicit opt-out")
        restarted.refreshLoginStatus()
        await waitForStatus(restarted)
        precondition(fixture.writes == [true, false], "Opening the panel must not register a login item")
        restarted.launchAtLogin()
        await waitForStatus(restarted)
        precondition(restarted.launchAtLoginEnabled == true && fixture.writes == [true, false, true])
        print("PASS: opt-out survives restart, status refresh stays read-only, and manual re-enable works")

        defaults.removePersistentDomain(forName: suite)
        let existing = LoginFixture(enabled: true)
        let alreadyEnabled = Store(readLoginStatus: { existing.read() }, setLoginStatus: { try existing.set($0) }, loginDefaults: defaults)
        alreadyEnabled.refreshLoginStatus(enableByDefault: true)
        await waitForStatus(alreadyEnabled)
        precondition(alreadyEnabled.launchAtLoginEnabled == true && existing.writes.isEmpty, "Do not re-register an enabled login item")
        existing.simulateSystemStatus(false)
        let systemDisabled = Store(readLoginStatus: { existing.read() }, setLoginStatus: { try existing.set($0) }, loginDefaults: defaults)
        systemDisabled.refreshLoginStatus(enableByDefault: true)
        await waitForStatus(systemDisabled)
        precondition(systemDisabled.launchAtLoginEnabled == false && existing.writes.isEmpty, "Respect later changes made in System Settings")
        print("PASS: existing login items and subsequent System Settings changes are preserved")

        defaults.removePersistentDomain(forName: suite)
        let approval = LoginFixture()
        approval.needsApproval = true
        let pending = Store(readLoginStatus: { approval.read() }, setLoginStatus: { try approval.set($0) }, loginDefaults: defaults)
        pending.refreshLoginStatus(enableByDefault: true)
        await waitForStatus(pending)
        precondition(pending.launchAtLoginEnabled == false && pending.settingsError?.contains("System Settings") == true, "Explain required macOS approval without claiming enabled")
        let pendingRestart = Store(readLoginStatus: { approval.read() }, setLoginStatus: { try approval.set($0) }, loginDefaults: defaults)
        pendingRestart.refreshLoginStatus(enableByDefault: true)
        await waitForStatus(pendingRestart)
        precondition(approval.writes == [true], "Do not repeatedly request registration while approval is pending")
        approval.simulateSystemStatus(true)
        pendingRestart.refreshLoginStatus()
        await waitForStatus(pendingRestart)
        precondition(pendingRestart.launchAtLoginEnabled == true)
        print("PASS: pending macOS approval is reported honestly and does not repeat registration")

        defaults.removePersistentDomain(forName: suite)
        let failing = LoginFixture()
        failing.failWrites = true
        let failed = Store(readLoginStatus: { failing.read() }, setLoginStatus: { try failing.set($0) }, loginDefaults: defaults)
        failed.refreshLoginStatus(enableByDefault: true)
        await waitForStatus(failed)
        precondition(failed.launchAtLoginEnabled == false && failed.settingsError != nil && !failed.loginItemBusy)
        failing.failWrites = false
        let retry = Store(readLoginStatus: { failing.read() }, setLoginStatus: { try failing.set($0) }, loginDefaults: defaults)
        retry.refreshLoginStatus(enableByDefault: true)
        await waitForStatus(retry)
        precondition(retry.launchAtLoginEnabled == true && failing.writes == [true, true], "A failed registration may retry on the next launch")
        print("PASS: failed registration releases the UI and can recover on a later launch")
    }
}

private final class LoginFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    init(enabled: Bool = false) { self.enabled = enabled }
    // Only changed between completed background operations.
    var needsApproval = false
    var failWrites = false
    func simulateSystemStatus(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
    private var changes: [Bool] = []
    private var mainThread = false
    var writes: [Bool] { lock.lock(); defer { lock.unlock() }; return changes }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    func read() -> Bool { lock.lock(); defer { lock.unlock() }; mainThread = mainThread || Thread.isMainThread; return enabled }
    func set(_ value: Bool) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        mainThread = mainThread || Thread.isMainThread
        changes.append(value)
        if failWrites { throw NSError(domain: "LoginFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Registration failed"]) }
        enabled = value && !needsApproval
        return enabled
    }
}
