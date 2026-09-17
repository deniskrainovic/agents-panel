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

## Icons

- `ClankerIcon.swift` defines the shared pixel robot artwork. The menu bar image is a template image so macOS can adapt its color.
- `MakeIcon.swift` generates the app icon from that same artwork. Update the shared sprite rather than creating a separate menu bar design.
