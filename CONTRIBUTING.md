# Working on AgentsPanel

Requires macOS 13 or later, Swift 5.9 or later, Python 3, and the Xcode command-line tools. There are no third-party package dependencies.

From the repository root:

```sh
./test.sh
./build.sh
open ../AgentsPanel.app
```

The build creates an app for the current Mac's architecture. Drag it into Applications to install it. Builds are ad-hoc signed, not notarized by Apple; macOS may require approval to open them. Subscription limits use your installed, signed-in Codex and Claude Code CLIs. AgentsPanel does not read Claude credentials. Claude Code must support the structured `/usage` report and `--safe-mode`; this integration was verified with version 2.1.276. If a login expires, renew it in the CLI and refresh AgentsPanel.

Tests use synthetic usage records and mock processes. They do not require Codex, Claude, accounts, API keys, or signing secrets. `swift test` is not this project's test entry point.

With an active macOS desktop session, run `./test.sh --ui` to check popover responsiveness. This desktop check and live subscription checks are manual, outside CI.

## Continuous integration

GitHub Actions runs on pushes, pull requests, and manual dispatch. Each run tests and builds separately on Apple Silicon and Intel, verifies the app's architecture and signature, and uploads architecture-specific ZIP files. Download these from the completed workflow's Artifacts section, extract the app ZIP, then move the app into Applications. Artifacts are retained for 14 days; they are not GitHub Releases or universal binaries.

The workflow uses GitHub's [standard macOS runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). Third-party action references are pinned to commits and maintained by Dependabot. No repository secrets are needed.

Keep build output, credentials, private keys, and local usage logs out of commits. Preserve the short README and its screenshot. See [AGENTS.md](AGENTS.md) for the focused implementation guides.
