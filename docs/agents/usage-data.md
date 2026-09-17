# Usage data and credentials

Read when changing `Sources/Providers.swift` or `Sources/TokenHistory.swift`.

## Subscription limits

- Codex uses the installed app-server and `account/rateLimits/read`. Monitoring must not create a thread or start a model turn.
- Prefer the Codex entry in `rateLimitsByLimitId`, with the legacy response as fallback. Determine window labels from their duration; the primary window can be weekly.
- Claude uses its existing OAuth login from the `Claude Code-credentials` Keychain item, with the credentials-file fallback implemented in `Providers.swift`.
- Preserve read-only credential handling: do not rename Claude’s Keychain item, rotate its refresh token, or change its access controls as part of fetching usage.
- Keep credential values and raw credential-bearing responses out of logs, fixtures, screenshots, and error messages. Use synthetic credentials in tests.
- Send Claude credentials only to the provider’s HTTPS endpoint; retain redirect rejection, request timeouts, and Codex child-process cleanup.
- Unavailable or failed usage is not zero usage. Show the error and identify any retained values as a previous successful update.

## Local history

- Scan Codex sessions and archived sessions, and Claude project logs. Keep prompt and response content local; retain usage summaries rather than transcript text in caches.
- Report today plus the previous six calendar days in the user’s local calendar. Model totals must cover the same period.
- Deduplicate cumulative Codex counters and repeated Claude response records. Cache reads and writes belong in Claude input totals; Codex cached input and reasoning output are already subsets of its totals.
- Preserve cache separation by home directory and provider, and invalidation for changed, removed, or truncated files.
- The current parser skips files modified before the reporting period. Account for this when testing imported logs with preserved timestamps.
- Token history represents this Mac. Do not infer account-wide subscription percentages or billing charges from those totals.
