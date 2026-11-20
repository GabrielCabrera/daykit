# daykit

Native, zero-dependency macOS CLI for Apple Calendar and Reminders (`EventKit`), built with an **agent-first** JSON contract and structural mutation guardrails.

- **Single Swift 6 binary** linking only Apple system frameworks (`Foundation`, `EventKit`, `CoreGraphics`)
- **Zero telemetry / zero network calls** — everything runs locally against `EKEventStore`
- **Embedded `Info.plist`** (`dev.gabrielcabrera.daykit`) verified in CI without an `.app` bundle
- **Agent-safe by default**: schema-versioned JSON (`schema_version: 1`), `--dry-run`, `DAYKIT_READ_ONLY=1`, writable calendar/list allowlists, opt-in briefing notes, and prompt-injection notices

## Requirements

- macOS 15 (Sequoia) or later
- Apple Swift 6.0+ (included in Xcode Command Line Tools — no full `Xcode.app` required to build or run tests)

## Installation

```bash
git clone https://github.com/GabrielCabrera/daykit.git
cd daykit
./install.sh
```

By default, `./install.sh` compiles the release binary and links `~/.local/bin/daykit`.
Ensure `~/.local/bin` is on your `PATH`, then authorize Calendar/Reminders access from a local interactive terminal (Ghostty / Terminal.app):

```bash
daykit doctor --request-access all
```

To uninstall:

```bash
./install.sh --uninstall
```

## Commands (`v0.1.0`)

```bash
# Diagnostics (never prompts unless --request-access is passed; always exits 0)
daykit doctor
daykit doctor --request-access all

# Combined agent briefing (overdue reminders + today's items + upcoming events)
daykit briefing
daykit briefing --days 3 --max-overdue 25
daykit briefing --include-notes --plain

# Calendar
daykit cal calendars
daykit cal today
daykit cal week --calendar Work
daykit cal list --from 2026-11-20 --to +3d
daykit cal add --title "1:1 Sync" --start "2026-11-21T10:00" --duration 30m --alarm 15m --dry-run
daykit cal add --title "Offsite" --start 2026-11-24 --end 2026-11-25 --all-day --calendar "iCloud/Personal"

# Reminders
daykit rem lists
daykit rem overdue
daykit rem today
daykit rem list --all --list Inbox
daykit rem add --title "Pay invoice" --due 2026-11-22 --priority high --dry-run
daykit rem done --id "<REMINDER_ID>"
```

Global flags: `--json` (default), `--plain` (human-readable without ANSI escapes), `--version` (`-V`), `--help` (`-h`).

## JSON Contract & Exit Codes

All structured responses use `snake_case` and `schema_version: 1`:
- **Success (`stdout`, empty `stderr`):** `{"schema_version":1,"ok":true,"command":"...","timezone":"...","generated_at":"...","data":...}`
- **Failure (`stderr`, empty `stdout`):** `{"schema_version":1,"ok":false,"error":{"code":"...","exit_code":N,"message":"...","hint":"..."}}`

| Exit Code | Meaning |
| :---: | :--- |
| `0` | Success (`doctor` always returns `0`) |
| `1` | Unexpected runtime / EventKit / XPC error |
| `2` | Invalid arguments, conflicting flags, or ambiguous calendar/list name |
| `3` | TCC permission denied, non-interactive session, `DAYKIT_READ_ONLY`, or allowlist block |
| `4` | Target `--id`, calendar, or list not found |

## Safety Guardrails & Privacy Limits

- **`DAYKIT_READ_ONLY=1`**: Blocks all writes (`cal add`, `rem add`, `rem done`) with exit code `3`.
- **`DAYKIT_WRITABLE_CALENDARS` / `DAYKIT_WRITABLE_LISTS`**: Comma-separated allowlists accepting exact IDs, `<Source>/<Title>`, or `<Title>`.
- **Multi-account disambiguation**: Exact ID > `<Source>/<Title>` > `<Title>`. Ambiguous write targets fail closed (exit `2`) listing candidates.
- **EventKit boundaries**: `EKEvent.attendees` is read-only on macOS; `daykit` cannot send invites to third parties or create Teams/Meet links. Updates and destructive deletes (`cal update`/`delete`, `rem update`/`delete`) are intentionally out of scope in `v0.1.0`.

## Agent Integration

See [`SKILL.md`](SKILL.md) for direct CLI agent instructions.

## License

[MIT](LICENSE)
