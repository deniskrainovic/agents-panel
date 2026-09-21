# Verification

Read when changing executable behavior or validating a fix.

## Commands

Run from the project root:

| Change | Check |
| --- | --- |
| Update detection or scheduling | `./test.sh`; `./test.sh --ui` for footer changes |
| Provider or history parsing | `./test.sh` |
| Rendering or responsiveness | `./test.sh --ui` and the relevant manual interaction |
| Release metadata or pipeline | `python3 Tests/VersionTests.py`, workflow lint, and a build with metadata inspection |
| App packaging or icons | `./build.sh`, then inspect the built app |
| Documentation only | Check links and referenced files; no app rebuild needed |

- Login-item tests inject an isolated preferences suite and fake system service; they cover default registration, persisted opt-outs, manual re-enabling, pending approval, background execution, and recovery without changing real login items.
- Update tests use an isolated URL session and synthetic clock to cover numeric versions, stable-only releases, exact release links, HTTP/offline failures, startup/daily scheduling, retained notices, and overlapping checks. They make no real GitHub requests.
- Tests are standalone executables, not a SwiftPM test target. `swift test` is not the project’s test entry point.
- `./test.sh` requires Python 3 for the provider fixture runner. It uses synthetic records and includes a 25-second timeout test for each provider.
- It also verifies that local history refreshes continue during pending authentication and overlapping local scans are coalesced, using injected fixtures without accessing credentials.
- `./test.sh --ui` needs an active macOS desktop session. It exercises the real popover while an injected login-status lookup is slow, checking response time, background execution, and coalescing.
- The UI test changes selection programmatically. It does not establish that the full visual tab is clickable; verify that separately for hit-target changes.
- Add regression coverage for accounting, provider lifecycle, or state-transition bugs at the seam that reproduces them. Do not add implementation-mirroring tests for simple copy or artwork edits.

## Live checks and screenshots

CI runs `./test.sh` and `./build.sh` on Apple Silicon and Intel macOS runners. The desktop responsiveness check remains manual because it needs an active desktop session. See [CONTRIBUTING.md](../../CONTRIBUTING.md) for workflow artifacts and local setup.

- `"../AgentsPanel.app/Contents/MacOS/AgentsPanel" --check` reads real subscription data and prints aggregate usage. It requires connectivity and installed, signed-in Codex and Claude Code CLIs. It is not a substitute for fixture tests. Claude checks use the built-in `/usage` command with zero model turns.
- `"../AgentsPanel.app/Contents/MacOS/AgentsPanel" --render-preview /absolute/path.png` renders labeled sample data. Add `--claude` for the Claude tab. Add `--update-preview` to show a synthetic update link on either tab. This does not capture the macOS menu bar.
- Inspect screenshots before delivery. Keep unrelated windows, account details, and credentials out of screenshots intended for publication.
- Report which checks actually ran. Distinguish simulated latency, live-service results, and manual interaction checks.
