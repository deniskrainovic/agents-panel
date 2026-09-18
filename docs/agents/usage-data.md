# Usage data and credentials

Read when changing `Sources/Providers.swift` or `Sources/TokenHistory.swift`.

## Subscription limits

- Codex uses the installed app-server and `account/rateLimits/read`. Monitoring must not create a thread or start a model turn.
- Prefer the Codex entry in `rateLimitsByLimitId`, with the legacy response as fallback. Determine window labels from their duration; the primary window can be weekly.
- Claude runs the installed CLI with `--safe-mode --no-session-persistence -p "/usage" --output-format json`. Parse `usage_report.rate_limits.limits` from the built-in command result; never prompt the model to estimate usage or parse session cost as subscription limits.
- Claude Code owns authentication. AgentsPanel must not read Keychain items, credential files, or OAuth tokens, refresh tokens, or call the Claude usage endpoint directly.
- Run Claude in a temporary directory with hooks/plugins disabled and session persistence off. Preserve cancellation, output bounds, the 25-second deadline, and child-process cleanup for both providers.
- Do not display raw CLI diagnostics or store full usage reports: they may contain account metadata or local activity details. Tests use synthetic CLI output.
- Require a built-in usage result with zero model turns and zero inference time. Missing or unsupported structured reports require a clear error; no model-prompt fallback.
- The report supplies session, weekly, and model-specific limits, but no plan tier; display "Subscription" rather than guessing the account plan.
- Unavailable or failed usage is not zero usage. Show the error and identify any retained values as a previous successful update.

## Local history

- Scan Codex sessions and archived sessions, and Claude project logs. Keep prompt and response content local; retain usage summaries rather than transcript text in caches.
- Report today plus the previous six calendar days in the user’s local calendar. Model totals must cover the same period.
- Deduplicate cumulative Codex counters and repeated Claude response records. Cache reads and writes belong in Claude input totals; Codex cached input and reasoning output are already subsets of its totals.
- Preserve cache separation by home directory and provider, and invalidation for changed, removed, or truncated files.
- The current parser skips files modified before the reporting period. Account for this when testing imported logs with preserved timestamps.
- Token history represents this Mac. Do not infer account-wide subscription percentages or billing charges from those totals.
