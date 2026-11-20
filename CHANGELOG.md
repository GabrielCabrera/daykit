# Changelog

All notable changes to `daykit` are documented in this file.

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
