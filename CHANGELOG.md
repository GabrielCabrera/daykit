# Changelog

All notable changes to `daykit` are documented in this file.

## [0.2.1] - 2026-11-22

### Security & Hardening
- **Fail-Closed Boolean Flags (`CLIParser`):** Reject `--<bool-flag>=<value>` forms (including `--dry-run=true`, `--yes=true`, `--all-day=true`, and `--json=true`) with `INVALID_ARGUMENT` (exit `2`) instead of silently evaluating them as `false`.
- **Fail-Closed Empty Allowlists (`Domain`, `DaykitApp`):** Distinguish unset `DAYKIT_WRITABLE_CALENDARS` / `DAYKIT_WRITABLE_LISTS` from explicitly empty values (`""` or `" , "`), blocking all mutations (`POLICY_DENIED`, exit `3`) when configured with zero permitted targets.
- **Symlink & FIFO Audit Log Guards (`AuditLogger`):** Validate parent directories with `lstat` (`S_ISDIR`), open audit logs with `O_NOFOLLOW | O_NONBLOCK`, and verify `fstat` (`S_ISREG` and `st_uid == getuid()`) before `fchmod`/`write`.
- **Complete `--plain` Sanitization (`OutputFormatter`, `DaykitApp`):** Strip ANSI CSI/OSC and ASCII control characters across `briefing` calendar titles, `doctor` source names/policy/notes, `cal add`/`rem add`/`rem done` lines, and `--plain` error output.
- **Overflow-Safe Duration & Alarm Arithmetic (`DateParsing`, `LiveEventKitStore`):** Enforce checked multiplication/addition (`maxDurationSeconds` 10-year cap) in `parseDuration` and overflow-free `TimeInterval` scaling for event alarms.
- **CI/CD Hardening (`.github/workflows/`):** Add explicit `permissions: contents: read` in `ci.yml`, pin `actions/checkout` by commit SHA, resolve `refs/tags/${TAG}` explicitly in `git archive`, and disallow `--clobber` overwrites on published releases.

## [0.2.0] - 2026-11-20

### Added
- **Relative Dates with Time (`DateParsing`):** Added wall-clock time support for relative day expressions such as `"today 18:30"`, `"tomorrow 09:00"`, `"+2d 14:15"`, and `"tomorrowT09:00"`.
- **Calendar & Reminder Updates and Deletions (`cal update|delete`, `rem update|delete`):**
  - `rem update`: partial updates for `--title`, `--list` (move with allowlist check on both source and destination), `--due` / `--clear-due`, `--priority`, `--notes` / `--clear-notes`, and `--url` / `--clear-url`.
  - `cal update`: partial updates with `--start`/`--end`/`--duration`, `--all-day`/`--no-all-day` transition validation, `--calendar` move, `--clear-location|notes|url|alarms`, and recurrence safety (`EventInstanceRef` canonical IDs + mandatory `--span this|future` on recurring/detached events).
  - `cal delete` & `rem delete`: guarded permanent deletion requiring `--yes` (never required on `--dry-run`) plus `--span this|future` on recurring/detached calendar events.
- **Pre-Mutation JSONL Audit Log (`AuditLogger`):** Live `update` and `delete` commands write a `0600` before-snapshot JSONL record to `~/.local/state/daykit/audit.jsonl` (`$XDG_STATE_HOME/daykit/audit.jsonl` or `DAYKIT_AUDIT_LOG`, disableable via `DAYKIT_DISABLE_AUDIT_LOG=1`).
- **Automated Release Workflow (`.github/workflows/release.yml`):** Publishes `daykit-vX.Y.Z-source.tar.gz` + `SHA256SUMS` upon pushing signed version tags matching `Sources/DaykitCore/Domain.swift` and `Resources/Info.plist`.

## [0.1.0] - 2026-11-20

### Added
- Initial open-source release of `daykit` (`briefing`, `cal calendars|today|week|list|add`, `rem lists|list|overdue|today|add|done`, `doctor`) with zero external Swift dependencies, embedded `Info.plist`, `schema_version: 1` JSON envelopes, `DAYKIT_READ_ONLY=1`, writable allowlists, `--dry-run`, `SKILL.md`, and Swift Testing CI on `macos-latest`.
