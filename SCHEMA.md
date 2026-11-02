# lifetrace data schema — `act.v1`

lifetrace records how you use your Mac: which app/window/document/web page is in front, for how long, when you are idle or away, how intensely you are typing/clicking/scrolling (counts only), and what text was on screen (read through Accessibility, redacted). It never records the screen, screenshots, audio, which keys were pressed, or password fields. External readers (browser history, agent transcripts, shell, git, …) add their own records under `sources/`, described in [SOURCES.md](SOURCES.md).

## 1. Storage

| What | Where | Notes |
|---|---|---|
| Raw events (source of truth) | `~/.local/share/lifetrace/events/YYYY-MM-DD.jsonl` | Append-only, one JSON object per line. The day is the local calendar day of the record's `ts`, in the configured UTC offset (§2). Kept forever. A line cut short by a crash or a full disk is terminated before the next append, so it stays one unreadable line that readers skip; every other line is read. Failed writes are counted in `status` → `write_errors`. |
| External sources | `~/.local/share/lifetrace/sources/<source>/YYYY-MM-DD.jsonl` | Written by separate readers (see [SOURCES.md](SOURCES.md)), same act.v1 line format plus `source` and `id`. lifetrace only reads them. |
| Query index | `~/.local/share/lifetrace/index.sqlite` (WAL) | Derived. Safe to delete; `lifetrace reindex` rebuilds it from JSONL (own events and sources). Queries catch up incrementally by file offset; source records are deduplicated on (`source`, `id`); a partial last line waits for its newline. Includes an FTS5 full-text index (trigram tokenizer, any language). |
| Daemon state | `state.json`, `control.json`, `daemon.lock` in the same dir | Not part of the event log. |
| Config (optional) | `~/.config/lifetrace/config.json` | Keys below. |

`LIFETRACE_HOME` and `LIFETRACE_CONFIG` override the data directory and the config file. `LIFETRACE_UTC_OFFSET` overrides `utc_offset`.

Config keys (all optional): `utc_offset` (e.g. `"+08:00"`; default: this Mac's UTC offset when the recorder starts, see §2), `idle_threshold_s` (60), `idle_poll_s` (3), `title_throttle_s` (5), `glance_s` (2), `ax` (true; false = app level only), `browser_applescript` (false; true = ask Chromium browsers/Safari for the URL via Apple Events when Accessibility does not expose it — macOS asks the user once per browser for Automation permission), `input_counts` (true; layer 4), `content` (true; layer 5), `content_exclude_bundles` (list of bundle ids that never get layer-5 content, a trailing `*` matches a prefix; setting it replaces the default list: password managers — 1Password, Bitwarden, Keychain Access, Passwords, KeePassXC, LastPass, Dashlane, Enpass —, crypto wallets — OneKey, Ledger —, Alipay/Ant, Chinese bank apps — CMB, ICBC, CCB, BOC, ABC, BoCom — and PayPal; see `lifetrace status --json` → `config` for the effective list), `title_commands` (object: bundle id → argv with an absolute program path; for apps whose window title says little, e.g. a GPU-drawn terminal workspace: the program prints line 1 = title, optional line 2 = absolute document/folder path, which then replace the Accessibility `title`/`doc`; it runs on focus changes and at most once per `title_throttle_s` after input in that app, with `LIFETRACE_PID` set, a 0.5 s timeout and 8 KB output cap; its output goes through the same redaction). The source readers read the same file for their own keys (`git_roots`, `git_authors`, `extra_readers`; see [SOURCES.md](SOURCES.md)).

## 2. Common fields

Every record has:

| Field | Type | Meaning |
|---|---|---|
| `v` | string | Always `"act.v1"`. A breaking change gets a new version; readers skip lines with other versions. |
| `ts` | string | ISO 8601, millisecond precision, with the configured offset: `2026-11-01T21:51:23.123+08:00`. Meaning depends on type (below); for most it is when it happened. |
| `type` | string | `layer.name`. Layers: `recorder`, `presence`, `focus`, `segment`, `activity` (layer 4), `content` (layer 5); external records use `source.<source>.<kind>`. |

Fields with no value are omitted rather than written as `null`. Lines are in write order, which is almost but not exactly `ts` order (`presence.idle_start` is back-dated, see below). Sort by `ts` when it matters; the index does.

Times use one **fixed UTC offset** (no daylight-saving changes): `$LIFETRACE_UTC_OFFSET`, else config `utc_offset`, else this Mac's offset when the process starts. It decides day files and the offset written in every `ts`. Set `utc_offset` when the day you think in differs from the Mac's time zone, or to keep day files stable across DST changes. Every `ts` carries its offset, so instants stay exact if the offset is changed later; only the day a record is filed under follows the offset at write time.

## 3. Event types

### recorder — the recorder's own lifecycle

| Type | Fields |
|---|---|
| `recorder.start` | `pid`, `version`, `ax` (bool: window-level data available), `ax_trusted` (bool: macOS reports Accessibility granted), `input` (bool: input counting active), `config` (object, effective config). |
| `recorder.stop` | `reason`: `signal` (normal stop: logout, `launchctl`, Ctrl-C) or `crash`. A crash is detected at the next start; the recorder then writes the missing `segment.end` and a `recorder.stop` with `reason: "crash"` whose `ts` is the last recorded instant (real end may be a little later). |
| `recorder.pause` | `until` (optional ISO time the pause ends by itself). Nothing about focus or idleness is recorded while paused; presence events still are. |
| `recorder.resume` | `by`: `cli` or `timer` (pause expired). |
| `recorder.perm` | `ax`, `ax_trusted`. Emitted when Accessibility permission is granted or revoked while running. |

### presence — is anyone at the computer

| Type | Meaning |
|---|---|
| `presence.lock` / `presence.unlock` | Screen locked/unlocked. Fast user switching is recorded the same way with field `why`: `"session_switch"`. |
| `presence.sleep` / `presence.wake` | System sleep / wake. |
| `presence.display_sleep` / `presence.display_wake` | Displays off / on. |
| `presence.idle_start` | No keyboard/mouse/trackpad input for `threshold_s` seconds. **`ts` is the instant of the last input**, i.e. the real start of the idle period (back-dated). `detected` = when the recorder noticed (≈ `ts` + `threshold_s`). |
| `presence.idle_end` | Input resumed. `ts` = time of input (accurate to about `idle_poll_s`). `idle_s` = length of the idle period. `reason`: `input`, or `away` when lock/sleep/display-off/pause/stop cut it short. |

"Away" = locked, asleep, displays off, or paused. No segment is open while away.

### focus — what is in front

All three carry the same context fields (those that are known):

| Field | Type | Meaning | Needs Accessibility |
|---|---|---|---|
| `app` | string | App display name, e.g. `Google Chrome`. | no |
| `bundle` | string | Bundle id, e.g. `com.google.Chrome`. Prefer this for grouping. | no |
| `pid` | int | Process id. | no |
| `win` | int | CGWindowID of the focused window. | yes |
| `title` | string | Focused window title, spinner glyphs (⠋ ✳ …) stripped, secrets masked (§3 content rules). | yes |
| `doc` | string | File path of the document (AXDocument), e.g. in editors, Preview, Pages. Secrets masked. | yes |
| `url` | string | Web page URL in browsers. Stored without user/password; values of credential-like or personal query or fragment parameters (`token`, `key`, `secret`, `password`, `auth`, `code`, `sig`/`signature`, `session`, `access_token`, `phone`/`mobile`/`tel`, `email`, `lat`/`lng`/`lon` and other coordinates, `uid`/`openid`/`unionid`/`user_id`, `idcard`, …) replaced by `REDACTED`; then the content rules (which also mask mainland mobile numbers and e-mail addresses). | yes, see §6 |
| `host` | string | Host of `url`, lowercase, without `www.`. | yes |
| `seg` | string | Id of the segment this event belongs to. | no |

| Type | When |
|---|---|
| `focus.app` | Another app came to the front. Also re-announced (`reason`) at `start`, after coming back from away (`resume`) and after a permission change (`perm`); normal switches have `reason: "activate"`. |
| `focus.window` | The focused window inside the frontmost app changed. |
| `focus.title` | Title, document or URL of the focused window changed. Throttled to at most one check per `title_throttle_s` (5 s); a burst of changes yields the last value. |

### segment — the unit for time accounting

A **segment** is a continuous stretch with the same app + window + document/URL in front while present. A title change alone does not end a segment (terminal titles change constantly); a URL change (ignoring `#fragment`), document change, window change or app switch does, and so does going away or stopping.

`segment.end` is written when a segment ends. It is self-contained: all context fields of the segment's last state plus:

| Field | Type | Meaning |
|---|---|---|
| `seg` | string | Segment id (also on the `focus.*` events inside it). |
| `start` / `end` | string | ISO bounds of this record. `ts` equals `end`, except for a non-empty piece ending exactly at local midnight (`ts` = `end` − 1 ms so it is filed under the day it covers). |
| `dur_s` | number | `end − start` in seconds (ms precision). |
| `idle_s` | number | Seconds inside the segment that fell within an idle period. |
| `active_s` | number | `dur_s − idle_s`: time with recent input. Reading without touching anything for more than the idle threshold counts as idle. |
| `glance` | bool | Whole segment shorter than `glance_s` (2 s): passing through an app while switching, not real use. |
| `reason` | string | What ended it: `switch` (other app), `window`, `doc`, `url`, `lock`, `sleep`, `display`, `pause`, `stop`, `crash` (recorder died; ended at its last recorded instant), or `midnight` (piece cut at local midnight). |
| `titles` | int | Distinct window titles seen during the segment, counted up to 256. |
| `titles_capped` | bool | Only when more than 256 distinct titles were seen (`titles` is then 256, a lower bound). |
| `revised` | bool | Only on a correction, see below. |
| `part` / `parts` | int | Only when the segment crosses local midnight: it is written as several records with the same `seg`, `part` = 1..`parts`, each with its own `start`/`end`/durations. |
| `keys`, `clicks`, `scrolls`, `scroll_px`, `copies`, `pastes` | int | Input counts during the segment (layer 4, see below). Present only when input counting was active; then 0 is a real zero. For a segment split at midnight they are all on the last part. Absent in records written by versions before input counting existed (0.2). |

Identity: (`seg`, `part`) is unique. Segment ids look like `s` + base36 of the start ms.

Corrections: idle is detected `idle_threshold_s` after the last input and back-dated to it. A segment can be ended by a focus change that needs no input (a page redirecting itself, an app opening a window) during what later turns out to be idle time. When the back-dated `presence.idle_start` reaches into such an already written segment, its `segment.end` record(s) are written again, complete, with the idle part added and `revised: true`. **The last `segment.end` for a (`seg`, `part`) wins**; the index and all queries already apply this. Only segments closed by `switch`/`window`/`doc`/`url` with no input since can be revised; the correction is written next to the `presence.idle_start`.

### activity — input intensity (layer 4, counts only)

A listen-only event tap counts key-down, mouse-button-down and scroll events. Which key was pressed is never stored; the only key check is "Cmd+V" to count pastes. Mouse movement is not observed. Nothing is counted while away. Needs the Accessibility permission lifetrace already has (or Input Monitoring); if neither works `recorder.start.input` and `status.permissions.input_counts` are false and only layers 1–3 and 5 are recorded.

| Field | Meaning |
|---|---|
| `keys` | Key presses (auto-repeat excluded). |
| `clicks` | Mouse/trackpad button presses (left, right, other). |
| `scrolls` | Scroll events from the user's gesture (momentum events excluded) — "ticks". |
| `scroll_px` | Total scrolled distance in points, momentum included, both axes. |
| `copies` | Pasteboard writes (`changeCount` delta; also counts copies made by apps themselves). |
| `pastes` | Cmd+V presses. |

| Type | When |
|---|---|
| `activity.minute` | Once per local clock minute **that had input** (idle minutes produce nothing). `ts` = start of the minute; also written early, for the partial minute, when going away or stopping. Carries the six counts and `seg` = the segment open when it was written. |

The same counts are summed per segment into `segment.end`. Queries that replay the log (the still-open segment, crash recovery) rebuild segment counts from `activity.minute` records, so they are approximate there.

### content — text seen on screen (layer 5, Accessibility, no images)

Read through the Accessibility API only; never pixels. Rules:

- Read 3 s after focus settles on a window, then again at most once per 60 s and only after the app reported a value/title change. Stored only when the text hash changed.
- Each read walks the focused window breadth-first with hard limits: 400 elements, depth 40, 30 ms. It takes the selected text, the focused element's visible text, then static texts and visible text of text areas.
- Password fields (`AXSecureTextField`) and everything under them are never read. Apps in `content_exclude_bundles` get no content at all (layers 1–4 still recorded). Browser windows whose title/toolbar says Private Browsing / Incognito / InPrivate / 无痕 / 隐私浏览 are skipped (best effort).
- Before writing, strings that look like secrets are masked as `[REDACTED…]`: private key blocks, JWTs, `sk-…`, `ghp_…`/`github_pat_…`, AWS access keys, Google `AIza…`, Slack `xox…`, `password=`/`token:`/`secret=`/`api_key=`/`access_key=`/`密码：`/`口令：`/`令牌：`-style values (a quoted value is masked whole), Bearer tokens in full, hex strings of 32+ digits and mixed-case base64-like tokens of 32+ characters. Each text is masked before it is cut to size. The same rules apply to window titles, document paths and URLs of `focus.*` and `segment.end`.

| Type | Fields |
|---|---|
| `content.snapshot` | `seg`, `app`, `bundle`, `hash` (FNV-1a 64 of `text`), `text` (≤ 4 KB UTF-8: selection, focused element, then window content, one item per line), `repeat` (true when identical text was stored in one of the last 64 snapshots — `text` is then omitted; find it by `hash`), `chars`, `truncated`, `progress` (0..1 vertical position of the first scroll area, when exposed), `nodes`, `read_ms`, `why` (`stable` after a focus change, `change` after an app-reported change). |
| `content.selection` | Selected text changed and stayed for 1.5 s: `seg`, `bundle`, `text` (≤ 2 KB, redacted), `chars`. Selections shorter than 2 characters or equal to the previous one are skipped. Read only as a bounded range (elements that report neither a selected range nor a small length are skipped); never in password fields or elements inside them, nor in a browser window that is private or has not had a full read yet. |

Web pages: Safari exposes page text; Chromium browsers (Chrome, Dia, Arc, Edge, Brave) normally expose only their own toolbar, not the page, unless an assistive app turned on Chromium accessibility. lifetrace does not turn it on (it makes the browser build a full accessibility tree for every page, costing the browser CPU and memory); page content comes from the browser-history source and window titles instead.

### source — external records

Lines in `sources/<source>/YYYY-MM-DD.jsonl`, written by readers outside the recorder. Required: `v` (`act.v1`), `ts`, `type` (`source.<source>.<kind>`), `source`, `id` (unique within the source). All other fields are free-form; see [SOURCES.md](SOURCES.md). Lines missing a required field are ignored. All string values except `source`, `id`, `*_id` and `*hash` fields go into full-text search.

## 4. Query output (CLI `--json` and MCP)

Every result is one JSON object with `"v": "act.v1"` and `"query": "<name>"`. Durations are seconds; times are ISO strings in the configured offset (`tz` on `timeline`/`stats`).

- `status` — `recording`, `running`, `pid`, `memory_mb` (physical footprint, like Activity Monitor), `rss_mb`, `cpu_avg_pct` (average since start), `paused`, `write_errors` (records the daemon could not write, e.g. disk full) and `last_write_error`, `permissions`, `level` (`window` or `app`), `today_events`, `last_event`, `data_dir`, `config`. `permissions.input_counts` = input counting active (false: event tap refused; grant Accessibility or Input Monitoring and restart), `permissions.input_listen_access` = macOS Input Monitoring preflight.
- `timeline` — `day`, `totals` {`tracked_s`, `active_s`, `idle_s`, `segments`, `glances`}, `items`: focus blocks `{kind:"focus", start, end, dur_s, active_s, idle_s, app, bundle, title, host, url, url_src?, doc, segs[], glances, chats?, open?}` and gaps `{kind:"away", start, end, dur_s, why}` with `why` ∈ `lock | sleep | display_sleep | pause | recorder_off | unknown`. Consecutive segments of the same app and same host/doc are merged when separated by ≤ 60 s (glances in between are absorbed and counted); `title`/`url` are those with the most time. `--raw` lists every segment instead. Browser segments with no live `url` get one from browser history (`source.browser.visit` of the same browser: the latest visit up to the segment end whose title matches the window title, within 12 h, else the latest visit inside the segment); such blocks/segments carry `url_src: "history"` (also applied in `stats` → `by_domain` and `at`). `chats` lists, for a block of a messenger app, the chats of source records with `chat_name` from that app's source (block app name contains the source name) inside the block: `[{chat, in, out}]`, busiest first, at most 8. `open: true` marks the segment still in progress. `--sources` interleaves external records as `{kind:"source", ts, source, type, id, summary}` (off by default because sources can be numerous; `sources` = how many).
- `at` — `state` (`active | idle | away | unknown`), `why` when away, `segment` (containing segment), `prev`, `next`, `events` (raw events within ±2 min, own and external sources interleaved by time; external ones have `source`).
- `stats` — `totals`, `app_switches` (consecutive segments with different apps, glances included), `interruptions` (A → B → A where B is a non-glance segment ≤ 120 s), `longest_focus` (longest run of non-glance segments in one app, gaps ≤ 60 s, by `active_s`), `deep_focus_blocks` (such runs with ≥ 25 min active), `by_app`, `by_domain`, `by_window` (top N by `active_s`, with `share` of total active), `active_by_hour` (24 numbers, local hours), `active_by_day` (week only).
- `events` — `events[]` raw records filtered by `--seg`, `--from/--to`, `--type` prefix; with `--source NAME` the records of that external source instead.
- `search` — `q`, `count`, `hits[]` newest first: `{ts, kind, source, app?, seg? | id?, snippet}`. `kind` ∈ `snapshot | selection | title` (own records, `source: "act"`, `seg` = segment id) or `source` (external, `id` = record id; fetch it with `events --source S --from TS --to TS`). Every whitespace-separated term must match, case-insensitive substring; terms of 3+ characters use the index, shorter ones (2-character Chinese words) a scan. Filters: `--from/--to`, `--source NAME|act`, `--limit` (50).
- `schema` — this spec in JSON.

## 5. How an agent should query

1. `status` — is it recording, since when, at which level (window or app only)? If not running or `level` is `app`, say so in the answer: titles/URLs will be missing.
2. `schema` — only if unsure what a field means.
3. Overview: `stats --day D` or `stats --week` for "where did my time go", focus and fragmentation; `timeline D` for "what did I do today, in order".
4. Point in time: `at "2026-11-01 15:30"`.
5. "When did I see / read / write about X": `search "X"` → `at <hit ts>` or `events --seg <hit seg>` for context.
6. Drill down: take `segs` ids from a timeline item and call `events --seg ID` for the raw focus/title/URL changes; or `events --from … --to …` for a window of time.

Interpretation tips: use `active_s` for "time spent working", `dur_s` for "time in front of it"; ignore `glance` segments for behaviour analysis but count them for switching; treat `away` gaps with `why: unknown` as recorder downtime. Days are local days in the configured offset.

## 6. Limits

- Without Accessibility permission only app-level data exists (`app`, `bundle`, `pid`); `status.level` is `app`.
- Browser URLs: Safari exposes the URL through Accessibility. Chromium browsers (Chrome, Dia, Arc, Edge, Brave) usually do not, so the live `url` is missing unless `browser_applescript` is enabled; the page title is still in `title`, and queries fill `url` from browser history (`url_src: "history"`) once the source readers have run.
- No images, canvas, audio or key identities are recorded. Window text is only what Accessibility exposes (layer 5); apps drawing their own text (games, some Electron/canvas apps, Chromium web pages) yield little or nothing. Password fields are never read.
- Idle detection is accurate to about 3 s at the end; the start is exact.
