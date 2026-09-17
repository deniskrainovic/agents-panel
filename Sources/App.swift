import AppKit
import SwiftUI
import ServiceManagement

enum Agent: String, CaseIterable, Identifiable {
    case codex, claude
    var id: String { rawValue }
    var title: String { self == .codex ? "Codex" : "Claude Code" }
    var symbol: String { self == .codex ? "terminal.fill" : "asterisk" }
    var tint: Color { self == .codex ? Color(red: 0.70, green: 0.73, blue: 1) : Color(red: 0.94, green: 0.66, blue: 0.52) }
}

@MainActor final class Store: ObservableObject {
    private let fetchSubscription: @Sendable (String) async throws -> Subscription
    private let readHistory: @Sendable (String) -> TokenHistory
    private let readLoginStatus: @Sendable () -> Bool
    @Published private(set) var launchAtLoginEnabled: Bool?
    @Published private(set) var loginItemBusy = false
    init(readLoginStatus: @escaping @Sendable () -> Bool = { LoginItemAccess.isEnabled() },
         fetchSubscription: @escaping @Sendable (String) async throws -> Subscription = { try await Providers.fetch($0) },
         readHistory: @escaping @Sendable (String) -> TokenHistory = { TokenHistory.load(provider: $0) }) {
        self.fetchSubscription = fetchSubscription
        self.readHistory = readHistory
        self.readLoginStatus = readLoginStatus
    }
    @Published var selected = Agent(rawValue: UserDefaults.standard.string(forKey: "selected") ?? "codex") ?? .codex {
        didSet { UserDefaults.standard.set(selected.rawValue, forKey: "selected") }
    }
    @Published var subscriptions: [Agent: Subscription] = [:]
    @Published var histories: [Agent: TokenHistory] = [:]
    @Published var errors: [Agent: String] = [:]
    @Published var loading: Set<Agent> = []
    @Published private(set) var historyLoading: Set<Agent> = []
    @Published var settingsError: String?
    private var timer: Timer?
    func start() {
        refreshLoginStatus()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func refresh() {
        for agent in Agent.allCases {
            if !historyLoading.contains(agent) {
                historyLoading.insert(agent)
                let scan = readHistory
                Task {
                    histories[agent] = await Task.detached(priority: .utility) { scan(agent.rawValue) }.value
                    historyLoading.remove(agent)
                }
            }
            guard !loading.contains(agent) else { continue }
            loading.insert(agent)
            Task {
                do {
                    subscriptions[agent] = try await fetchSubscription(agent.rawValue)
                    errors[agent] = nil
                } catch { errors[agent] = error.localizedDescription }
                loading.remove(agent)
            }
        }
    }
    func refreshLoginStatus() {
        guard !loginItemBusy else { return }
        loginItemBusy = true
        let read = readLoginStatus
        Task {
            launchAtLoginEnabled = await Task.detached(priority: .utility) { read() }.value
            loginItemBusy = false
        }
    }
    func launchAtLogin() {
        guard let enabled = launchAtLoginEnabled, !loginItemBusy else { return }
        loginItemBusy = true
        Task {
            do {
                launchAtLoginEnabled = try await Task.detached(priority: .utility) {
                    try LoginItemAccess.setEnabled(!enabled)
                }.value
            } catch { settingsError = error.localizedDescription }
            loginItemBusy = false
        }
    }
    func openUsage() {
        NSWorkspace.shared.open(URL(string: selected == .codex ? "https://chatgpt.com/codex/settings/usage" : "https://claude.ai/settings/usage")!)
    }
}

// ServiceManagement makes synchronous system-service calls. Never invoke it
// while rendering a SwiftUI view or handling a tab selection on the main actor.
private enum LoginItemAccess {
    static func isEnabled() -> Bool { SMAppService.mainApp.status == .enabled }
    static func setEnabled(_ enabled: Bool) throws -> Bool {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
        return isEnabled()
    }
}

private let panelBackground = Color(red: 0.095, green: 0.10, blue: 0.13)
private let secondary = Color(red: 0.61, green: 0.64, blue: 0.71)

struct Panel: View {
    @ObservedObject var store: Store
    var agent: Agent { store.selected }
    var subscription: Subscription? { store.subscriptions[agent] }
    var history: TokenHistory? { store.histories[agent] }
    var busy: Bool { store.loading.contains(agent) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: agent.symbol).font(.system(size: 23, weight: .medium)).foregroundStyle(agent.tint)
                    .frame(width: 46, height: 46).background(agent.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(agent.title).font(.system(size: 22, weight: .semibold))
                    Text(subscription?.plan.uppercased() ?? "SUBSCRIPTION TRACKER").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.6).foregroundStyle(secondary)
                }
                Spacer()
                Circle().fill(store.errors[agent] != nil ? Color.orange : (subscription == nil ? secondary : Color.green)).frame(width: 6, height: 6)
                Text(store.errors[agent] != nil ? "OFFLINE" : (subscription == nil ? "CONNECTING" : "CONNECTED"))
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(0.7).foregroundStyle(secondary)
            }.padding(.bottom, 22)
            HStack(spacing: 4) {
                ForEach(Agent.allCases) { item in
                    Button { store.selected = item } label: {
                        HStack(spacing: 7) { Image(systemName: item.symbol); Text(item.title) }
                            .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 11)
                            .contentShape(Rectangle())
                            .background(agent == item ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(agent == item ? Color.white : secondary)
                    }.buttonStyle(.plain).accessibilityAddTraits(agent == item ? .isSelected : [])
                }
            }.padding(4).background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 11))
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionTitle("SUBSCRIPTION LIMITS", trailing: "USED")
                        if let value = subscription {
                            ForEach(Array(value.windows.enumerated()), id: \.offset) { _, window in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack { Text(window.name).font(.system(size: 13, weight: .medium)); Spacer(); Text(String(format: "%.0f%%", window.usedPercent)).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(agent.tint) }
                                    meter(window.usedPercent / 100, color: window.usedPercent >= 90 ? .orange : agent.tint, height: 5)
                                    TimelineView(.periodic(from: .now, by: 60)) { context in
                                        Text(resetText(window.resetsAt, now: context.date)).font(.system(size: 11)).foregroundStyle(secondary)
                                    }
                                }.accessibilityElement(children: .combine)
                            }
                            if value.windows.isEmpty { Text("No subscription limits were reported for this account.").font(.system(size: 12)).foregroundStyle(secondary) }
                        } else if busy {
                            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Reading your subscription…").font(.system(size: 12)).foregroundStyle(secondary) }.padding(.vertical, 12)
                        }
                        if let error = store.errors[agent] {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(subscription == nil ? "Connection needed" : "Showing last successful update", systemImage: "exclamationmark.circle").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                                Text(error).font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                                Button("Open usage page", action: store.openUsage).font(.system(size: 11)).buttonStyle(.link)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    Divider().overlay(Color.white.opacity(0.04))
                    VStack(alignment: .leading, spacing: 15) {
                        sectionTitle("TOKENS BY DAY", trailing: "LAST 7 DAYS")
                        if let history {
                            let maxTokens = max(history.days.map(\.tokens).max() ?? 0, 1)
                            ForEach(history.days, id: \.date) { day in
                                HStack(spacing: 12) {
                                    Text(Calendar.current.isDateInToday(day.date) ? "Today" : day.date.formatted(.dateTime.weekday(.abbreviated)))
                                        .frame(width: 38, alignment: .leading).foregroundStyle(Calendar.current.isDateInToday(day.date) ? Color.white : secondary)
                                    meter(Double(day.tokens) / Double(maxTokens), color: Calendar.current.isDateInToday(day.date) ? agent.tint : agent.tint.opacity(0.42), height: 5)
                                    Text(compact(day.tokens)).monospacedDigit().frame(width: 61, alignment: .trailing).foregroundStyle(Calendar.current.isDateInToday(day.date) ? Color.white : secondary)
                                }.font(.system(size: 11, design: .monospaced)).accessibilityElement(children: .combine)
                            }
                        } else { Text("Reading local usage…").font(.system(size: 12)).foregroundStyle(secondary) }
                    }
                    Divider().overlay(Color.white.opacity(0.04))
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("TOKENS BY MODEL", trailing: compact(history?.models.reduce(0) { $0 + $1.tokens } ?? 0))
                        if let history, !history.models.isEmpty {
                            ForEach(history.models, id: \.name) { model in
                                HStack { Text(model.name).lineLimit(1).help(model.name); Spacer(); Text(compact(model.tokens)).monospacedDigit().foregroundStyle(agent.tint) }
                                    .font(.system(size: 11, design: .monospaced)).padding(.horizontal, 12).padding(.vertical, 11)
                                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                            }
                        } else { Text("No recorded tokens in the last 7 days.").font(.system(size: 12)).foregroundStyle(secondary) }
                        Text("Token totals are from this Mac, including cached tokens. Subscription limits apply across your account.")
                            .font(.system(size: 10)).foregroundStyle(secondary).lineSpacing(3)
                    }
                }.padding(.vertical, 22)
            }.scrollIndicators(.hidden)
            Divider()
            HStack(spacing: 10) {
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                    .buttonStyle(.plain).disabled(store.historyLoading.contains(agent)).help("Refresh usage").accessibilityLabel("Refresh usage").keyboardShortcut("r", modifiers: .command)
                if busy { Text("Updating…") }
                else if let date = subscription?.updatedAt { Text("Updated \(date.formatted(date: .omitted, time: .shortened))") }
                else { Text("Refreshes every 15 minutes") }
                Spacer()
                Menu {
                    Button("Open \(agent.title) usage", action: store.openUsage)
                    Button(store.launchAtLoginEnabled == nil ? "Checking launch at login…" : (store.launchAtLoginEnabled == true ? "✓ Launch at login" : "Launch at login"), action: store.launchAtLogin)
                        .disabled(store.loginItemBusy || store.launchAtLoginEnabled == nil)
                    Divider()
                    Button("Quit AgentsPanel") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).frame(width: 23).help("Settings").accessibilityLabel("Settings")
            }.font(.system(size: 10)).foregroundStyle(secondary).padding(.top, 15)
        }.padding(24).frame(width: 440, height: 720).background(panelBackground).foregroundStyle(Color(red: 0.91, green: 0.92, blue: 0.97)).preferredColorScheme(.dark)
            .alert("Login item", isPresented: Binding(get: { store.settingsError != nil }, set: { if !$0 { store.settingsError = nil } })) { Button("OK") { store.settingsError = nil } } message: { Text(store.settingsError ?? "") }
    }
    func sectionTitle(_ title: String, trailing: String) -> some View {
        HStack { Text(title).tracking(1.3); Spacer(); Text(trailing).tracking(0.5) }.font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(secondary)
    }
    func meter(_ fraction: Double, color: Color, height: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.085))
                Capsule().fill(color).frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }.frame(height: height).accessibilityHidden(true)
    }
}

func compact(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return String(n)
}
func resetText(_ date: Date?, now: Date) -> String {
    guard let date else { return "Reset time unavailable" }
    let seconds = Int(date.timeIntervalSince(now))
    if seconds <= 0 { return "Reset due · refresh to update" }
    if seconds >= 86400 { return "Resets in \(seconds / 86400)d \((seconds % 86400) / 3600)h" }
    if seconds >= 3600 { return "Resets in \(seconds / 3600)h \((seconds % 3600) / 60)m" }
    return "Resets in \(max(1, seconds / 60))m"
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var item: NSStatusItem!
    let popover = NSPopover()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = ClankerIcon.menuBar()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.toolTip = "AgentsPanel · Codex & Claude Code"
        popover.contentViewController = NSHostingController(rootView: Panel(store: store))
        popover.contentSize = NSSize(width: 440, height: 720)
        popover.behavior = .transient
        popover.animates = true
        store.start()
        if CommandLine.arguments.contains("--show") { toggle() }
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            store.refreshLoginStatus()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

#if !PANEL_TESTING
@main enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            let store = Store()
            let agent: Agent = CommandLine.arguments.contains("--claude") ? .claude : .codex
            store.selected = agent
            store.subscriptions[agent] = Subscription(plan: "Pro · Preview data", windows: [UsageWindow(name: "5-hour session", usedPercent: 28, resetsAt: Date().addingTimeInterval(8400)), UsageWindow(name: "Weekly", usedPercent: 63, resetsAt: Date().addingTimeInterval(350000))], updatedAt: Date(), source: "Preview")
            let tokens = [3400000, 8100000, 0, 4700000, 12400000, 6200000, 9800000]
            let days = (0..<7).map { TokenDay(date: Calendar.current.date(byAdding: .day, value: $0 - 6, to: Date())!, tokens: tokens[$0]) }
            store.histories[agent] = TokenHistory(days: days, models: [TokenModel(name: agent == .codex ? "gpt-6-astra" : "claude-opus-4-6", tokens: 32900000), TokenModel(name: agent == .codex ? "gpt-5.6-sol" : "claude-sonnet-4-6", tokens: 11700000)], fileCount: 10)
            let view = NSHostingView(rootView: Panel(store: store))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 440, height: 720)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                }
            }
            return
        }
        if CommandLine.arguments.contains("--check") {
            Task {
                for agent in Agent.allCases {
                    do {
                        let value = try await Providers.fetch(agent.rawValue)
                        print("\(agent.title): \(value.plan); \(value.windows.map { "\($0.name)=\($0.usedPercent)%" }.joined(separator: ", "))")
                    } catch { print("\(agent.title): \(error.localizedDescription)") }
                    let history = await Task.detached { TokenHistory.load(provider: agent.rawValue) }.value
                    print("Local history: \(history.fileCount) files; \(history.days.count) days; \(history.models.count) models; \(history.days.reduce(0) { $0 + $1.tokens }) tokens")
                }
                exit(0)
            }
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

#endif
