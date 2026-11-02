# AGENTS.md — working on lifetrace

lifetrace is a local macOS activity recorder: a Swift daemon + CLI (`Sources/`), a
stdlib-only Python package of optional source readers (`lifetrace_sources/`), a thin
MCP server (`lifetrace_mcp/`) and an agent skill (`skills/lifetrace/SKILL.md`).
This file is for agents changing the code. To *use* the tool, read the skill.

## Layout

| Path | What |
|---|---|
| `Sources/LifetraceCore/` | Event model, fixed-offset time (`Zone`), segmenter, JSONL store, SQLite/FTS5 index, queries, schema |
| `Sources/lifetrace/` | CLI entry (`main.swift`), daemon (NSWorkspace/AX observers, idle, input counts), Accessibility content reader |
| `Tests/LifetraceCoreTests/` | XCTest for the core (no permissions needed) |
| `lifetrace_sources/` | Readers: browser, claude, codex, shell, git, media_projects, calendar; `extra_readers` plug-in loader |
| `Tests/test_sources.py` | Python unittest with synthetic fixtures only |
| `lifetrace_mcp/` | MCP stdio server; shells out to `lifetrace ... --json` |
| `launchd/*.plist.in` | LaunchAgent templates; label and paths filled in at install |
| `SCHEMA.md`, `SOURCES.md` | Data contract (`act.v1`) and reader contract — update them with any field change |
| `module.json`, `MODULE.md` | Optional self-description for agent hubs that load tool modules |

## Build and test

Requires macOS 13+, Xcode Command Line Tools (Swift 5.10+), Python 3.9+.

```sh
swift build                                   # debug build
swift test                                    # core tests
python3 -m unittest discover -s Tests -t .    # source reader tests
make test                                     # both
make build                                    # release build + codesign (see below)
```

Run one heavy build/test at a time. Tests pin `utc_offset` to `+08:00` and point
`LIFETRACE_CONFIG` at `/dev/null`; keep new tests independent of the machine's time
zone, home directory and real data.

Smoke checks that need no permissions and touch no real data:

```sh
export LIFETRACE_HOME=$(mktemp -d) LIFETRACE_CONFIG=/dev/null
.build/debug/lifetrace status --json
.build/debug/lifetrace schema --json
.build/debug/lifetrace timeline today --json
python3 -m lifetrace_sources run --dry-run --data-dir "$LIFETRACE_HOME"
```

## Signing and the Accessibility grant

macOS ties the Accessibility grant to the binary's designated requirement:
code-signing identifier (= `LABEL`, default `dev.lifetrace.recorder`) plus
certificate. `make build` signs with the first "Apple Development" identity it finds,
or `SIGN_IDENTITY="..."`, else ad-hoc (`-`; the grant must then be re-given after
every rebuild). Per-machine overrides (`LABEL`, `SOURCES_LABEL`, `SIGN_IDENTITY`,
`PREFIX`) go in an untracked `config.mk`. Changing `LABEL` or the identity on an
existing install invalidates the user's grant — never do it silently.

## Rules

- Output contract: every `--json` result is one object with `"v": "act.v1"` and
  `"query"`; errors are `{"v":"act.v1","error":...}` with exit code 2. Event and
  query changes go into `Schema.swift` and `SCHEMA.md` together (a test checks that
  every schema type is documented).
- Privacy is the product: never add screenshots, screen recording, audio, key
  identities, network calls or telemetry. New text fields must pass the redaction
  rules (`Activity.swift` for the recorder, `core.redact` for readers) before they
  are written. Readers never write into the apps they read; they copy SQLite DB+WAL
  to a private temp dir first.
- Python readers stay stdlib-only. App- or machine-specific readers belong outside
  the repo via config `extra_readers` (SOURCES.md), not in `lifetrace_sources/`.
- Installation never loads LaunchAgents and never requests permissions; the user
  does both. Do not run `launchctl`, change TCC settings, or read the user's real
  `~/.local/share/lifetrace` from tests.
- No absolute personal paths, account names or real captured data in code, tests,
  docs or fixtures. Fixtures use obviously fake data.
