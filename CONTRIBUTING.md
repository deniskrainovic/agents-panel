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

## Releases

`version.json` is the source of truth for the app version and build number. To prepare a release, run this with the next version (example):

```sh
python3 scripts/version.py --set 1.0.10
```

This increments the build number automatically and rejects invalid, unchanged, or older versions. Review and commit the changes, then push the commit and its matching tag:

```sh
git add version.json
git commit -m "Prepare release $(python3 scripts/version.py)"
git tag "v$(python3 scripts/version.py)"
git push --atomic origin main "v$(python3 scripts/version.py)"
```

Run these from `main` with the intended release changes already committed. The tag is the release trigger: an ordinary branch push never publishes a release. No manual edits to `build.sh` or manual ZIP uploads are needed.

For a version-tag push, CI checks that the tag matches `version.json`, runs tests and builds for both architectures, and verifies the versions embedded in both apps. Only when both jobs succeed does it create a GitHub Release with the two app ZIPs, SHA-256 checksums, and generated release notes. It uploads everything to a draft before publishing it. GitHub determines the latest release automatically; the README's `/releases/latest` link follows that release.

Treat release tags as immutable. If tests or builds fail, no release is created. Fix the issue and prepare a new version/tag. If upload or publication fails after a draft was created, inspect that draft; either finish publishing it after verifying its assets, or delete the incomplete draft and rerun the failed job. The workflow intentionally refuses to overwrite an existing release.

## Continuous integration

GitHub Actions runs on pushes, pull requests, and manual dispatch. Each run tests and builds separately on Apple Silicon and Intel, verifies the app's architecture and signature, and uploads architecture-specific ZIP files. Download these from the completed workflow's Artifacts section, extract the app ZIP, then move the app into Applications. Workflow artifacts are retained for 14 days. Tagged releases also keep their ZIPs as release assets. Each ZIP contains one architecture, not a universal binary.

The workflow uses GitHub's [standard macOS runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). Third-party action references are pinned to commits and maintained by Dependabot. No repository secrets are needed.

Keep build output, credentials, private keys, and local usage logs out of commits. Preserve the short README and its screenshot. See [AGENTS.md](AGENTS.md) for the focused implementation guides.
