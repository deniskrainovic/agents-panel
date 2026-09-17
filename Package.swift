// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AgentsPanel", platforms: [.macOS(.v13)], products: [.executable(name: "AgentsPanel", targets: ["AgentsPanel"])], targets: [.executableTarget(name: "AgentsPanel", path: "Sources")])
