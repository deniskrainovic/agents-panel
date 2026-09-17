# AgentsPanel

AgentsPanel is a native macOS menu bar app inspired by Omarchy’s agents panel, showing subscription limits and local token usage for Codex and Claude Code only.

- Package manager: Swift Package Manager; SwiftUI and AppKit; macOS 13+.
- Run commands from this directory.
- Build and package: `./build.sh` creates `../AgentsPanel.app` with local ad-hoc signing.
- Compile only: `swift build`. There is no separate typecheck command.

Read only the guide relevant to the task:

- [UI and responsiveness](docs/agents/ui.md): panel behavior, hit targets, threading, and icons.
- [Usage data and credentials](docs/agents/usage-data.md): provider integration and token accounting.
- [Verification](docs/agents/testing.md): fixture tests, UI checks, and live diagnostics.
- [Packaging and documentation](docs/agents/packaging.md): app identity, signing, distribution, and README constraints.
