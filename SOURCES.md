# Layer 6 — app-native sources

Local, opt-in Python standard-library package. It does not alter the Swift recorder,
its `events/`, its index, or `act.v1`. Unlike window metadata, this layer deliberately
contains **redacted prompts and shell commands**. Keep it local.
Built-in readers: `browser`, `claude`, `codex`, `shell`, `git`, `media_projects`,
`calendar`; add your own with [extra readers](#extra-readers-your-own-sources).
No app automation, network calls, sending, login or persistent service startup.

## CLI and storage contract

```sh
python3 -m lifetrace_sources run
python3 -m lifetrace_sources run --source browser --source git --since 2026-11-01T00:00:00+08:00
python3 -m lifetrace_sources run --backfill-days 14 --data-dir /tmp/lifetrace-example --dry-run
python3 -m lifetrace_sources status --json
python3 -m lifetrace_sources rescrub --data-dir /tmp/lifetrace-example --dry-run
python3 -m unittest discover -s Tests -t .
```

- Default data directory: `$LIFETRACE_HOME` or `~/.local/share/lifetrace`; `--data-dir` overrides it.
- Config: the recorder's optional `$LIFETRACE_CONFIG` / `~/.config/lifetrace/config.json`.
  Keys used here: `utc_offset`, `git_roots`, `git_authors`, `extra_readers` (below).
- Output: `<data-dir>/sources/<source>/YYYY-MM-DD.jsonl`, **local calendar day** in
  the configured UTC offset (same rule as the recorder, see SCHEMA.md §2).
- Required fields: `v:"act.v1"`, `ts` (offset-aware ISO, milliseconds, configured offset such as `+08:00`),
  `type:"source.<source>.<kind>"`, `source`, `id` (SHA-256 stable within source).
- Timestamps are explicitly converted from UTC/Unix, Chrome's 1601 UTC epoch,
  Apple's 2001 UTC epoch, or offset-aware transcript timestamps. Never implicit
  machine-local conversion. Missing fields are omitted.
- Default **initial** backfill: seven days. `--backfill-days N` changes it;
  `--since ISO` overrides the lower bound and requires an explicit timezone.
  Existing cursors are **not rewound** by either flag. To recover older history,
  use a separate data directory, then let the indexer dedupe the stable IDs.
  Previously untouched files/profiles may be backfilled when the bound expands.
- Once a cursor exists, new source records are read even if their clock goes
  backwards, except an explicit `--since` still filters timestamps. Git uses graph
  boundaries, not a timestamp watermark, for ordinary incremental reads.
- `run` prints **counts and diagnostics only**, never record contents. Missing
  apps/permissions are expected and do not prevent other readers from running.
  Each report has `source,count,duplicates,status,runtime_s,checked_at` plus source
  discovery counts and, on failure, `issues:[{target,reason}]` (exception class only).
- `--dry-run` uses real readers and sanitizers but writes **nothing** to the data
  directory: no events, cursors, status or locks. Temporary DB copies are removed.
- Each source has `.state.json` (cursors), `.status.json`
  (last attempt, including failures), and `.run.lock` (advisory single writer).
  `status [--data-dir DIR] [--json]` reads these cached results, with `checked_at`;
  before the first run it only checks paths and reports `not_checked`/`missing`.
  It does not claim that an old permission check is current.
- JSONL uses `O_APPEND`, **one `os.write` per line**. Files are fsynced before
  atomic state replacement (private temp + rename + directory fsync). Source dirs
  are 0700 and JSONL/state files 0600. Independent targets can advance on partial
  success, but a failed target's unfinished cursor is not acknowledged.
- Existing day-file IDs are checked before appending, including recovery from an
  append/state crash. Unacknowledged files (newer than state, or no state) are
  scanned into a private temporary SQLite ID table for bounded-memory cross-day
  replay; normal incremental runs do not scan the whole history. Corrupt or unterminated JSONL is reported, **never silently
  truncated or appended through**. Manually inspect/repair the file if this occurs.

### Re-sanitize saved records

`python3 -m lifetrace_sources rescrub --data-dir DIR [--dry-run]` re-applies the
current sanitizer to `DIR/sources/*/*.jsonl`. It prints one `act.v1` object with
`query:"sources.rescrub"`, `dry_run`, `files` (processed files), `records` (read
records), and `changed` (records whose sanitized values differ). Dry runs create
no files or locks. Without `--dry-run`, each file is streamed into a private
sibling, fsynced and atomically replaced with mode **0600**, under the source's
writer lock. Record order, stable `id`s and Git `hash`es are preserved; cursor and
status files are untouched. Previously saved `media_path` strings are scrubbed
conservatively, without assuming they still carry verified-path provenance.
Corrupt/incomplete input or a busy writer returns an `act.v1` error and exit 2;
the failing file stays intact. Earlier files may already have been scrubbed, so
retrying is safe. This command is explicit maintenance, never run automatically.

To clean historical shell replay bursts, preview and then explicitly apply:

```sh
python3 -m lifetrace_sources rescrub --data-dir DIR --dedupe-shell-estimated --dry-run
python3 -m lifetrace_sources rescrub --data-dir DIR --dedupe-shell-estimated
```

This adds `removed` to the summary. Within `DIR/sources/shell/*.jsonl`, in day-file
and line order, it keeps the first estimated (`ts_estimated: true`) record per
stored `command` and drops later estimated duplicates, even across days.
Timestamped records, records without a string command and other sources are not
deduplicated. This intentionally collapses legitimate repeats whose execution
times are unknown too; preview before applying. The same writer lock, private
atomic per-file rewrite and error behavior apply. It does not restore fields
already replaced by `[REDACTED]` or modify cursors/status files.

## Redaction and identities

All free-form strings, including titles, URLs, paths, names, prompts, commands and
nested map keys/values are sanitized before output. This covers `sk-…`, GitHub PATs,
AWS access IDs, JWTs, long hex/base64-like tokens, PEM private keys (including
unterminated blocks), full Bearer credentials (before assignment matching), and
quoted/unquoted `key=value` / `key: value` assignments for password, passwd, pwd,
api_key/apikey, access_key/access_token, token, secret, authorization, 密码, 口令,
令牌 (including the existing hyphenated key aliases). Sanitization
precedes truncation. Generic base64-like tokens require at least 40 characters
with uppercase, lowercase and digits; URL path separators are not part of that
match. A separate standalone-blob rule covers slash-bearing base64 credentials.
Purely numeric IDs are not treated as hex secrets; ordinary URL paths and readable
slugs survive. URL query and fragment parameter **values** (including empty
values and percent-encoded parameter names) are replaced with `[REDACTED]` for
phone/mobile/tel, email, lat/lng/lon/flat/flng/tlat/tlng/latitude/longitude,
coordinate/location/geo, token/access_token/*_token, key/*_key/*_key_id, secret,
auth, session/sid, sig/signature, code, password/pwd, openid/open_id/unionid,
uid/user_id and idcard/id_card aliases. Names and useful nonsensitive parameters
such as `q` and `page` remain. Standalone mainland mobile numbers (`1[3-9]` plus
nine digits, not within a longer digit run) and email addresses are scrubbed in
all free text as well. Prompts are bounded by **UTF-8 bytes**, not characters.

Structural `id` and Git `hash` are identifiers, not free-form text; preserve them
for dedupe/commit resolution. Only `media_path` fields that a reader marks as
`VerifiedMediaPath` (a path returned by the app's own cache lookup) preserve
structural 32-hex directory/file hashes, optional extensions and `_t`, `_h`,
`_thumb` cache variants. Other secret-looking filename parts
are still sanitized; the same paths/hashes in text or unverified fields get full
redaction. This is heuristic defense-in-depth, **not a guarantee that all
possible credentials or personal data are removed**. No raw content is logged on
exceptions. Session state stores redacted metadata and counts, never prompt/tool
text.

## Incremental work and discovery

Unchanged browser DB **and WAL** revisions (device/inode, size, nanosecond mtime
and ctime) skip snapshot copying and SQL entirely. Git skips subprocesses when
HEAD, logs/HEAD, recursive refs (including custom namespaces), packed-refs,
reftable and repository configuration metadata are unchanged. Fingerprints are
captured **before** reading, so concurrent changes trigger a later retry rather
than being acknowledged unseen. Empty repositories are cached too. Existing
cursors migrate on the first successful read; that first run is not steady state.

Browser and media metadata discovery cache per-directory listings.
Every known nested directory is still stat'ed: a top-level mtime alone cannot
prove its subtree is unchanged. New nested files/directories are discovered via
their immediate parent's revision. Secret-looking names disable that listing's
cache rather than persisting raw text. Media projects still check the referenced
project files and Final Cut DB/WAL mtimes even when their discovery dirs are
unchanged. Discovery traversal depth and supported inputs are unchanged.
`unchanged_databases` / `unchanged_repositories` report fast-path counts when used;
an unchanged DB is not reopened, so this is not a new SQLite permission probe.
File revision metadata is not a content hash or an arbitrary-rewrite change feed.

## Readers, kinds and fields

### `browser` — `source.browser.visit`

Discover `History` files under all vendor/profile directories (up to three levels
below vendors) in `~/Library/Application Support`, including Dia, Google Chrome,
Microsoft Edge, Brave, Arc and other Chromium-family installations. Also try
`~/Library/Safari/History.db`. Custom user-data dirs outside those roots are not
searched. All discovered profiles are independent.

Fields: `url`, `title`, `browser`, `profile` (relative vendor-root profile path),
`visit_duration` (**seconds**, Chromium microseconds / 1e6), `transition` (Chromium
raw integer bitfield: core type in low eight bits, qualifiers above),
`from_visit_url` (resolved referrer visit URL when still present).
Safari lacks the duration/transition/referrer fields in this adapter.

Clock: Chromium microseconds since **1601-01-01 UTC**; Safari seconds since
**2001-01-01 UTC**. Cursor: visit row ID per path/database generation (device/inode).
Identity: database path hash + generation + visit ID + source visit time. Deleted/recreated DBs may
legitimately produce new identities for retained visits. History-clearing/rewrite
in place that reuses IDs is not a reliable change feed.

Copy DB **and WAL** into a private temporary directory, reject a changing copy,
then query only the copy. SQLite reconstructs SHM there; the original is not opened
by SQLite. Safari may require Full Disk Access; denial is reported and skipped,
without requesting Automation or opening permission settings.

### `claude` / `codex` — `source.<source>.prompt`, `.session`

Claude: `~/.claude/projects/**/*.jsonl`, including nested `subagents` transcripts.
Codex: `~/.codex/sessions/**/*.jsonl`, including sessions whose metadata identifies
subagent provenance. All input files are read-only.

`prompt` fields: `session_id`, `text` (at most **2048 UTF-8 bytes**, redacted first),
`text_truncated` (original exceeded the byte bound), `subagent` (boolean).
Claude user messages with only `tool_result`, meta messages and mirrored API blobs
are not user prompts. Codex uses `response_item` user messages; mirrored
`event_msg.user_message` is deliberately not emitted twice. Versions that only
record that mirror without a response item are not supported.

`session` fields: `session_id`, `project_dir` (**transcript storage directory**),
`cwd` (actual project/working directory if present), `start`, `end` (local ISO),
`turns` (count of nonempty user prompts, not assistant/tool blocks), `tool_calls`
(map: tool name → call count), `model` (last known), `subagent`, `summary_revision`
(byte offset after the last complete consumed line).

A session summary is a **cumulative, append-only snapshot**, not a final/closed
session claim. `ts=end`; a changed session emits a new summary ID based on its
revision. Consumers should choose the latest revision per transcript/session,
not sum snapshots. Initial summary counts cover the readable transcript, possibly
including activity older than the event backfill bound. Transcripts without any
source timestamp produce no fabricated summary. No tool outputs, tool inputs,
assistant text or reasoning are persisted. Known large irrelevant tool/API blobs
are drained in bounded chunks instead of decoded. Relevant messages have no input
size cap; pathological giant prompt/assistant lines can exceed the RSS target.

Clock: explicit transcript ISO offset. Cursors: path hash, inode, byte offset and
redacted cumulative metadata. Incomplete last lines are retried; malformed relevant JSON lines
report an issue and are not acknowledged past that line. Prompt identity uses file
path plus UUID (Claude) or byte position (Codex). Summary identity uses path plus
revision. Rewrites/truncation restart parsing and dedupe existing IDs; arbitrarily
rewritten files cannot be treated as append-only history.

### `shell` — `source.shell.command`

Path: inherited `$HISTFILE` if set, otherwise `~/.zsh_history`. A non-exported shell
variable is unavailable to launchd/Python. `command` (redacted, at most **8192 UTF-8
bytes**), `position` (original byte offset), `ts_estimated` (boolean), and optional
`duration_s` (integer seconds from zsh EXTENDED_HISTORY).

Recognizes `: <Unix seconds>:<duration seconds>;<command>`, including escaped
multiline records. zsh metafied bytes are unescaped after continuation joining,
before UTF-8 decoding; positions and cursor offsets remain raw-file byte offsets.
A dangling Meta byte/incomplete final record waits for more data without cursor
advancement. Without timestamps, **ts is the reader's first observation**,
not execution time; even a 24-hour backfill includes all unseen timestamp-less
lines. A file can mix both: old plain lines stay estimated, timestamped lines get
their exact time. Cursor: inode, byte offset, a short tail fingerprint to detect
rewrites, hashed identities for the last 3 commands and hashes of imported plain
commands (never their raw text). Initial backfill includes every plain record,
including repeats; subsequent reads ignore previously imported plain command
text, irrespective of position or observation time. New plain command text can
still be imported. Identity: timestamped records = history path + full line;
initial plain records = path + position + content hash.

On a rewrite, the reader resumes after its three-record tail when present;
otherwise it scans from the beginning and stable-ID dedupe handles timestamped
replays. Retained plain commands are not re-emitted. zsh's conversion of imported
plain commands to `: <rewrite time>:0;cmd` is suppressed by command hash during
rewrites too. A genuine duration-zero execution of the same formerly plain command
in a rewrite cannot be distinguished from conversion and is conservatively
suppressed; normal timestamped appends and nonzero-duration executions survive.
Older cursors are upgraded from the already-read prefix when intact, or retained
plain lines and plain tail hashes on rewrite. Already-converted commands missing
from both an old cursor's tail and its file cannot be reconstructed. Legacy
text-only tails cannot prove timestamp identity, so timestamped history is replayed
through stable-ID dedupe. Incomplete lines are retried.

For exact command times put `setopt EXTENDED_HISTORY INC_APPEND_HISTORY` in your
`~/.zshrc`. **This implementation does not edit dotfiles** or recover timestamps
for old lines. History is collected only when zsh has flushed it to disk.

### `git` — `source.git.commit`

Read-only `git config`, `git log`, `git rev-parse` and (for an empty repo check)
`git show-ref`. `GIT_OPTIONAL_LOCKS=0`; no checkout/fetch/index writes. Search
each root in config `git_roots` (default: whichever of `~/Developer`, `~/Projects`,
`~/Code`, `~/code`, `~/src`, `~/repos`, `~/GitHub`, `~/workspace`, `~/dev` exist; a
root may itself be a repository): its top-level repositories plus immediate
children of non-repository containers. Resolve worktree `commondir` and process each main repository once;
all refs plus HEAD are included. No submodule recursion or arbitrary deep scan.

Authors match each repo's effective `user.name` / `user.email`, or any name/email
in config `git_authors` (case-insensitive). Fields: `repo` (main repo path), `hash` (full commit ID),
`subject`, `files_changed` (integer), `insertions`, `deletions` (integer **lines**,
binary numstat `-` contributes zero). Rename is one changed file. Merge commits
use git's default numstat behavior; these are not aggregate merge-diff metrics.

`ts` is the commit's **author ISO clock**. Initial `git --since` walks by committer
clock, then an explicit `--since` also filters author dates. Future-dated commits
may appear. Cursors contain all previously observed ref heads, so newly reachable
backdated commits are not lost on ordinary incremental runs. GC'd boundaries
fall back to the configured bounded time window and dedupe. Unborn/empty repos
are counted separately, not treated as permission failures. Identity: repo + hash.

### `media_projects` — `source.media_projects.project`

Metadata only; never parse/render a timeline or read media contents.
Fields: `app`, `project_name`, `path`, `modified` (local ISO), `time_basis`.
`ts=modified`. Identity: app + path + observed modified timestamp; cursor stores
that revision. This is a modified-project observation, **not measured work time**.

- JianyingPro / CapCut: `~/Movies/<app>` and
  `~/Library/Application Support/<app>`, `root_meta_info.json`'s
  `all_draft_store`, including configured `draft_fold_path` outside that tree.
  `tm_draft_modified` is Unix **microseconds** (`time_basis:draft_unix_microseconds`).
  Removed drafts are excluded. Fallback: `draft_meta_info.json` filesystem mtime;
  encrypted metadata is not decoded. No project contents are stored.
- After Effects: `~/Library/Preferences/Adobe/After Effects/*/*Prefs*.txt`
  MRU `.aep` / `.aepx` paths, including quoted continuation lines. Existing files
  contribute their filesystem mtime, **not the prefs file's save time**. Absolute
  POSIX paths and `Macintosh HD:` HFS paths are recognized.
- Blender: `~/Library/Application Support/Blender/*/config/recent-files.txt`,
  existing `.blend` paths and filesystem mtime.
- Final Cut: `.fcpbundle` libraries under `~/Movies` (up to three nested directory
  levels), using max mtime of the bundle and its top-level `.flexolibrary` DB/WAL.

The last three use `time_basis:filesystem_mtime`. MRU order does not expose an
exact last-open clock; unmodified reopened projects cannot yield a precise opened
event. Custom prefs/library locations, disconnected external volumes, deleted
projects and unsupported preference encodings are not fully covered. Missing
Final Cut/Blender metadata is normal; no app is launched.

### `calendar` — `source.calendar.event`

Try `~/Library/Calendars/{Calendar Cache,Calendar.sqlitedb}` and the equivalent
`Library/Group Containers/group.com.apple.calendar[/Calendar]/Calendar.sqlitedb`.
Only filesystem/SQLite reads of temporary DB/WAL copies; **no EventKit,
AppleScript, permission request, settings navigation or app launch**. A TCC denial
or unknown schema is reported and skipped. Full Disk Access may be needed.

Supports CalendarItem / ZCALENDARITEM / ZCALENDAREVENT / Event layouts with known
column aliases. Fields: `uid`, `title`, optional `location`, `start`, `end` (local
ISO), `time_basis` (`modified` if a modification column exists, else `start`).
All recognized date columns use Apple **2001 UTC seconds**. `ts` uses modification
time or start, with an upper bound of the reader's current time. Future meetings
can appear when recently modified. Cursor: inclusive modification/start watermark;
identity: database + row + timestamp + selected field revision, so equal-time edits
are not missed. No recurrence expansion, attendees, notes, cancellation/deletion
feed or claim of server completeness. Unknown schemas are not guessed.

## Extra readers (your own sources)

Readers that do not belong in this repository (a private app database, a work
tool, anything machine-specific) can live anywhere on disk and still run with
the built-in ones. List their Python files in config `extra_readers`:

```json
{ "extra_readers": ["~/lifetrace-readers/notes_reader.py"] }
```

Each file defines `READERS = {"<name>": reader}`. A reader is a generator
`reader(ctx, state)` that yields rows built with
`lifetrace_sources.core.event(source, kind, timestamp, identity, **fields)`:

```python
from lifetrace_sources.core import event, unix

def notes(ctx, state):
    last = state.get('last', 0)          # cursors: plain JSON, persisted only after a durable append
    for row_id, created, title in read_my_db(ctx.home, after=last):
        yield event('notes', 'note', unix(created), [row_id], title=title)
        last = max(last, row_id)
    state['last'] = last

READERS = {'notes': notes}
```

- `ctx.home`, `ctx.since` (initial lower bound), `ctx.now`, `ctx.floor(existing)`,
  `ctx.config` (the parsed config file), `ctx.issue(target, exc)` (report a
  per-target failure; only the exception class is kept), `ctx.details` (extra
  counters for the run report; `availability: "missing"` marks an absent app).
- `event()` sanitizes every string field, sets `v`, `ts` (configured offset),
  `type: source.<source>.<kind>`, `source` and a stable `id` from `identity`.
  Use a `VerifiedMediaPath` for a `media_path` returned by the app's own cache
  lookup to keep its structural 32-hex directory/file names.
- Names must not collide with built-in readers. A file that fails to import or
  collides is reported as `status: "unavailable"` with
  `issues:[{target:"extra_readers", reason:<exception class>}]`; built-in readers
  still run. Extra readers run in-process with your privileges: only list
  files you wrote or reviewed.
- `run --source NAME` and `status` include them; the indexer, `search`,
  `events --source NAME` and `timeline --sources` treat them like any source.

## Scheduling

`launchd/sources.plist.in` specifies StartInterval 900,
ProcessType Background, Nice 10 and LowPriorityIO. It runs `python3 -m
lifetrace_sources run` from this checkout; keep the checkout available.

`make install-sources` renders/writes `~/Library/LaunchAgents/<SOURCES_LABEL>.plist`
(default label `dev.lifetrace.sources`) and creates its log parent but
**does not load it**. It does not build Swift or install dependencies. Tests use
temporary `LAUNCH_AGENTS=... SOURCES_LOG=...` and never touch the real
`~/Library/LaunchAgents`. Loading it (`launchctl bootstrap gui/$(id -u) <plist>`)
and granting Full Disk Access are your decisions.

## Verification

`python3 -m unittest discover -s Tests -t .` runs synthetic fixtures for every
reader: source clock conversion, cursors, replay/append crash recovery,
redaction, WAL, local-day splits, extra-reader loading and failure isolation.
They never read your real home directory. `python3 Tests/benchmark_sources.py`
measures warm no-change and few-new-record reads using temporary synthetic inputs
(32 browser DBs, 54 repositories, transcript and media metadata fixtures), and
asserts that new records are observed. It never loads real config or readers.

Not covered by tests: launchd scheduling, real TCC denials (denials are
simulated), every Final Cut/Blender/CapCut version, custom project locations,
pathological giant transcript lines.
