# UI and responsiveness

Read when changing `Sources/App.swift` or `Sources/ClankerIcon.swift`.

## Boundaries

- `Store` owns observable state on the main actor; `Panel` renders it; `AppDelegate` owns the status item and transient popover.
- Tab selection uses already-loaded provider state. Keep it independent of network requests, transcript scans, and Keychain access.
- Keep synchronous ServiceManagement calls off the main actor. Render cached login-item status and coalesce overlapping status checks.
- Run transcript scans off the main actor, including cache reads that can acquire the parser lock.

## Interaction

- The entire padded tab rectangle must respond to clicks. Preserve `.contentShape(Rectangle())` inside the button label, after its frame and padding. A transparent background alone does not establish the full hit area.
- For click-target bugs, verify clicks in the empty space around the icon and text; programmatically changing selection does not test hit detection.
- Preserve the two provider tabs, percent-used labels, reset countdowns, and distinction between local token history and account-wide limits.
- Keep the footer reachable when content overflows; the usage sections scroll.
- Preserve manual refresh, the 15-minute refresh interval, and refresh after wake unless the task changes that behavior.

## Launch at login

- At startup, request launch at login once when no saved preference exists. Existing installations without a saved preference initialize this default on their first launch of this implementation.
- Persist a successful request and explicit manual opt-outs. Later launches and panel openings only read the actual system status, respecting changes made through the app or System Settings.
- Registration and status reads run off the main thread. Coalesce overlapping operations. If macOS approval is required, explain where to approve it without showing a false enabled state; a failed registration may retry at a later startup.

## Release notifications

- `UpdateChecker` owns app-wide release state separately from provider usage. Check at startup and after each 24-hour interval; wake checks only run when due and coalesce with any in-flight request.
- `Updates.swift` reads the installed bundle version and the public GitHub latest-release endpoint without credentials. Compare three numeric components; ignore older/equal versions, drafts, prereleases, and invalid versions.
- `UpdateNotice` observes the checker directly and shows a lavender release link between the footer's usage status and settings, on both tabs. Keep the link absent when no update is known; do not replace usage errors or interrupt the user on update-check failures.
- A failed request retains a previously known update; a successful no-update response clears it. Installations remain manual through the release page.

## Icons

- `ClankerIcon.swift` defines the shared pixel robot artwork. The menu bar image is a template image so macOS can adapt its color.
- `MakeIcon.swift` generates the app icon from that same artwork. Update the shared sprite rather than creating a separate menu bar design.
