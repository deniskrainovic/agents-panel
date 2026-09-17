import Foundation
@main struct ProviderLiveTest {
    static func main() async {
        for provider in CommandLine.arguments.dropFirst() {
            let start = Date()
            do {
                let subscription = try await Providers.fetch(provider)
                print("\(provider): OK plan=\(subscription.plan) source=\(subscription.source)")
                for window in subscription.windows {
                    print("  \(window.name): \(window.usedPercent)% reset=\(window.resetsAt?.description ?? "unavailable")")
                }
            } catch { print("\(provider): ERROR \(error.localizedDescription)") }
            print("elapsed=\(Date().timeIntervalSince(start))s")
        }
    }
}
