import AppKit
import SwiftUI

@main enum SwitchResponsivenessTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { await run(); exit(0) }
        NSApp.run()
    }

    @MainActor static func run() async {
        let probe = SlowLoginStatus()
        let updates = UpdateChecker(fetch: { AppUpdate(tag: "v1.0.10") })
        await updates.checkIfDue()
        let store = Store(readLoginStatus: { probe.read() }, updates: updates)
        store.refreshLoginStatus()
        store.refreshLoginStatus()
        for agent in Agent.allCases {
            store.subscriptions[agent] = Subscription(plan: "Test", windows: (agent == .codex ? ["Weekly"] : ["5-hour session", "Weekly", "Weekly · Fable"]).map { UsageWindow(name: $0, usedPercent: 40, resetsAt: Date().addingTimeInterval(3600)) }, updatedAt: Date(), source: "Fixture")
            store.histories[agent] = TokenHistory(days: (0..<7).map { TokenDay(date: Calendar.current.date(byAdding: .day, value: -$0, to: Date())!, tokens: 1000) }, models: (0..<(agent == .codex ? 3 : 4)).map { TokenModel(name: "\(agent.rawValue)-\($0)", tokens: 7000) }, fileCount: 1)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "Test"
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Panel(store: store))
        popover.contentSize = NSSize(width: 440, height: 720)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: item.button!.bounds, of: item.button!, preferredEdge: .minY)
        let view = popover.contentViewController!.view
        try? await Task.sleep(nanoseconds: 100_000_000)
        var durations: [Double] = []
        for index in 0..<12 {
            let start = ProcessInfo.processInfo.systemUptime
            store.selected = index.isMultiple(of: 2) ? .claude : .codex
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 10_000_000)
            view.layoutSubtreeIfNeeded()
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            durations.append(elapsed)
            print(String(format: "switch %d: %.3fs", index + 1, elapsed))
            fflush(stdout)
        }
        let worst = durations.max() ?? 0
        print(String(format: "worst switch: %.3fs", worst))
        try? await Task.sleep(nanoseconds: 450_000_000)
        precondition(store.launchAtLoginEnabled == true, "Background status did not arrive")
        precondition(probe.calls == 1, "Repeated refreshes must share the in-flight query")
        precondition(!probe.ranOnMainThread, "System query ran on the UI thread")
        guard worst < 0.25 else { print("FAIL: tab switching blocked the main thread"); exit(1) }
        print("PASS: 12 real panel updates remained responsive")
    }
}

private final class SlowLoginStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var onMain = false
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var ranOnMainThread: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
    func read() -> Bool {
        lock.lock()
        count += 1
        onMain = onMain || Thread.isMainThread
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.4)
        return true
    }
}
