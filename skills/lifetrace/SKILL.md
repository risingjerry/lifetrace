---
name: lifetrace
description: Answer questions about how the user spends time on their Mac from the local lifetrace activity log (act.v1) — where the time went, what they were doing at a given moment, focus vs. fragmentation, interruptions, time per app/site/window, idle and away periods, typing vs. reading intensity, and when they saw some text on screen ("when did I see X"). Also covers external sources (browser history, Claude Code / Codex prompts, shell, git commits, media projects, calendar). Use for "where did my time go", "what did I do today/yesterday", "what was I doing at 3pm", "how focused was I this week", "screen time", "when did I read about X", 时间花在哪 / 今天干了什么 / 下午三点在干嘛 / 专注 / 分心 / 被打断 / 我在哪看到过, or when coaching on work habits. Not for screenshots, images, which keys were pressed, or phone activity.
---

# lifetrace

lifetrace is an always-on, event-driven recorder on this Mac. It logs which app, window, document and web page is in front, when the user is idle (no input for 60 s) and away (locked, asleep, display off, paused); per segment and per minute how many keys/clicks/scrolls/copies/pastes (counts only); and the text visible in the focused window plus selected text, read through Accessibility and redacted (never pixels). Optional readers add browser history and other sources. Everything stays on this Mac.

Times use one fixed UTC offset (config `utc_offset`, default the Mac's offset); `timeline` and `stats` report it as `tz`. Plain times you pass ("15:30", "2026-11-01 15:30") are read in that offset; ISO times with an offset are exact.

## First contact

```sh
command -v lifetrace && lifetrace status --json
```

- Not installed: the user must install it (needs Xcode Command Line Tools): `git clone https://github.com/risingjerry/lifetrace && cd lifetrace && make install`, then grant Accessibility and load the LaunchAgent (see the repo README). Do not grant permissions or load LaunchAgents on the user's behalf without asking.
- Check `running`, `paused`, `level` (`window` = titles/docs/URLs available; `app` = app names only, Accessibility not granted) and `last_event`. If it is not running or `level` is `app`, say so in your answer.

Interfaces (same JSON either way): CLI `lifetrace <cmd> --json`, or MCP tools `lifetrace_status`, `lifetrace_schema`, `lifetrace_stats`, `lifetrace_timeline`, `lifetrace_at`, `lifetrace_events`, `lifetrace_search`. Errors come back as `{"v":"act.v1","error":"..."}` with a non-zero exit code.

## Call order

1. **status** — as above.
2. **schema** — `lifetrace schema --json`, only when a field is unclear. Key facts: `active_s` = time with input, `dur_s` = time in front, `glance` = < 2 s pass-through, `away` gaps have a `why`.
3. **Overview**
   - "Where did my time go / how focused was I": `lifetrace stats --day YYYY-MM-DD --json` or `lifetrace stats --week --json` (7 days ending today). Read `totals`, `by_app`, `by_domain`, `by_window`, `longest_focus`, `deep_focus_blocks`, `app_switches`, `interruptions`, `active_by_hour`.
   - "What did I do, in order": `lifetrace timeline YYYY-MM-DD --json` (also `today`, `yesterday`). Items are merged focus blocks and away gaps. Add `--sources` to interleave external records.
4. **Point in time**: `lifetrace at "2026-11-01 15:30" --json` (or `"15:30"` for today). Includes external records within ±2 min.
5. **"When did I see / read / write X"**: `lifetrace search "X" [--from T --to T] [--source NAME|act] --json`. Hits are newest first with `ts`, `kind` (`snapshot` = text on screen, `selection`, `title`, `source`), `seg` or source `id`, and a `snippet`. Then `at <ts>` for context. Terms of 3+ characters use the index; 2-character CJK words work through a slower scan.
6. **Drill down**: `lifetrace events --seg <id> --json` with ids from a timeline item's `segs`, or `lifetrace events --from "2026-11-01 15:00" --to "2026-11-01 16:00" [--type focus.] --json`. External records: `lifetrace events --source NAME --json`.

Start broad and narrow down; do not dump raw events when `stats` answers the question.

## External sources

Readers run from the lifetrace checkout (find it with `plutil -extract WorkingDirectory raw ~/Library/LaunchAgents/*lifetrace*sources*.plist`, or ask the user):

```sh
python3 -m lifetrace_sources status --json      # health and last run per source, read-only
python3 -m lifetrace_sources run --dry-run      # counts only, writes nothing
```

Do not run `lifetrace_sources run` for real unless asked; its LaunchAgent runs it every 15 minutes once the user installs it. A `missing` source means no data, not no activity. Source records include redacted prompts and shell commands: treat them as sensitive.

## Answering well

- Report active time (`active_s`) as working time and say when idle time is large.
- Ignore glances for behaviour, but they count as switches.
- Input intensity: `keys` / `clicks` / `scrolls` on `segment.end` and `activity.minute` tell typing (writing) from scrolling (reading) from clicking around. They are absent when input counting was off (`status.permissions.input_counts`).
- Name concrete apps, sites, windows and times; compare with other days or the week when it helps.
- When coaching, base suggestions on the numbers (switches per hour, longest focus, the most fragmented hours) and keep them few and specific.

## Privacy rules

- The data stays on this Mac. Do not paste raw events, window titles, URLs, document paths or on-screen text into external services (web search, other models, chats, issue trackers) unless the user asks for it in this conversation.
- Quote only what the answer needs: titles and on-screen text can contain private names, messages and subjects. Secrets are masked as `[REDACTED…]`; never try to reconstruct them.
- Never change recorder settings, pause/resume, delete data, load/unload LaunchAgents or request permissions unless asked.

## Limits

- No images, canvas, audio or key identities. On-screen text is only what Accessibility exposes: native apps and Safari yes; Chromium browsers (Chrome, Arc, Edge, Brave, Dia) only their toolbar, not the page — use titles and the browser-history source. Excluded apps (password managers, wallets, banking apps; `content_exclude_bundles`) and private/incognito windows have no text.
- Chromium browsers usually have no live `url`; `timeline`, `stats` and `at` fill it from browser history once the source readers ran (`url_src: "history"` = inferred by title/time, treat as very likely, not certain). Messenger blocks carry `chats` [{chat, in, out}] = messages during that block; `in` counts arrivals, not reading.
- Without Accessibility permission only app names exist.
- Gaps with `why: unknown` or `recorder_off` mean the recorder was not running; do not count them as time away from the computer.

Full data format: `lifetrace schema` (SCHEMA.md); source readers: SOURCES.md in the repo.
