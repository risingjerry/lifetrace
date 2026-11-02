"""Local, bounded readers. No app automation, network, or third-party Python deps."""
from __future__ import annotations

import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess

from .core import (APPLE, CHROME, UTC, apple, chrome, clean, digest, event,
                   iso, parse_time, short, snapshot, unix, database_stamp, file_stamp, tree_files)

# Searched for git repositories (top level + one container level) unless config `git_roots` is set.
DEFAULT_GIT_ROOTS = ('~/Developer', '~/Projects', '~/projects', '~/Code', '~/code', '~/src',
                     '~/repos', '~/GitHub', '~/github', '~/workspace', '~/dev')


class Context:
    def __init__(self, home, since, now, explicit=False, config=None):
        self.home, self.since, self.now = Path(home), since, now
        self.explicit = explicit
        self.config = config or {}
        self.issues = []
        self.details = {}

    def floor(self, existing):
        return self.since if self.explicit or not existing else dt.datetime.min.replace(tzinfo=UTC)

    def issue(self, target, error):
        # Never return exception strings: SQL/paths can contain personal text or keys.
        self.issues.append({'target': str(target), 'reason': type(error).__name__})


def history_paths(home, cache=None):
    support = home / 'Library/Application Support'
    found = []
    cache = {} if cache is None else cache
    if support.exists():
        for vendor in support.iterdir():
            if not vendor.is_dir():
                continue
            for path in tree_files(vendor, cache, lambda n: n == 'History', max_depth=3,
                                   prune={'Cache', 'Code Cache', 'GPUCache', 'node_modules', 'Service Worker'}):
                relative = path.parent.relative_to(vendor)
                app = vendor.name
                if vendor.name in ('Google', 'Microsoft') and relative.parts:
                    app += ' ' + relative.parts[0]
                elif vendor.name == 'BraveSoftware':
                    app = 'Brave'
                found.append((path, app, str(relative)))
    safari = home / 'Library/Safari/History.db'
    try:
        safari.stat()
        found.append((safari, 'Safari', 'Default'))
    except PermissionError:
        found.append((safari, 'Safari', 'Default'))
    except FileNotFoundError:
        pass
    return sorted(found)


def browser(ctx, state):
    paths = history_paths(ctx.home, state.setdefault('_discovery', {}))
    ctx.details['databases'] = len(paths)
    if not paths:
        ctx.details['availability'] = 'missing'
    for path, app, profile in paths:
        key = digest(str(path))
        try:
            stamp = database_stamp(path)
            stat = path.stat()
            generation = [stat.st_dev, stat.st_ino]
            old = state.get(key, {})
            if old.get('stamp') == stamp:
                ctx.details['unchanged_databases'] = ctx.details.get('unchanged_databases', 0) + 1
                continue
            existing = old.get('generation') == generation
            cursor = old.get('id', 0) if existing else 0
            with snapshot(path) as con:
                table = 'history_visits' if app == 'Safari' else 'visits'
                boundary = con.execute(f'SELECT coalesce(max(id),0) FROM {table}').fetchone()[0]
                if boundary < cursor:  # History cleared in place.
                    existing, cursor = False, 0
                floor = ctx.floor(existing)
                if app == 'Safari':
                    lower = (floor - APPLE).total_seconds()
                    visit_columns = {r[1] for r in con.execute('PRAGMA table_info(history_visits)')}
                    title = 'v.title' if 'title' in visit_columns else 't.title'
                    rows = con.execute(f'''SELECT v.id,v.visit_time,t.url,{title} AS title
                        FROM history_visits v JOIN history_items t ON t.id=v.history_item
                        WHERE v.id>? AND v.visit_time>=? ORDER BY v.id''', (cursor, lower))
                else:
                    lower = int((floor - CHROME).total_seconds() * 1_000_000)
                    rows = con.execute('''SELECT v.id,v.visit_time,v.visit_duration,v.transition,
                        u.url,u.title,p.url AS from_url FROM visits v JOIN urls u ON u.id=v.url
                        LEFT JOIN visits f ON f.id=v.from_visit LEFT JOIN urls p ON p.id=f.url
                        WHERE v.id>? AND v.visit_time>=? ORDER BY v.id''', (cursor, lower))
                for r in rows:
                    fields = dict(url=r['url'], title=r['title'], browser=app, profile=profile)
                    if app != 'Safari':
                        fields.update(visit_duration=r['visit_duration'] / 1_000_000,
                                      transition=r['transition'], from_visit_url=r['from_url'])
                    yield event('browser', 'visit', apple(r['visit_time']) if app == 'Safari'
                                else chrome(r['visit_time']), [key, generation, r['id'], r['visit_time']], **fields)
                    cursor = max(cursor, r['id'])
            state[key] = dict(id=max(cursor, boundary), generation=generation, stamp=stamp)
        except Exception as exc:
            ctx.issue(app + '/' + profile, exc)


def _text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(b.get('text', '') for b in content if isinstance(b, dict)
                         and b.get('type') in ('text', 'input_text'))
    return ''



def _session_line(stream, source):
    """Drain large irrelevant tool/API blobs in bounded chunks, not json.loads.

    Relevant user/assistant messages retain the normal parser; no prompt size cap.
    A partial final line is never acknowledged. Return metadata-only stand-ins for
    ignored blobs so the session's time bounds still reflect those records.
    """
    prefix = stream.readline(8192)
    if not prefix or prefix.endswith(b'\n'):
        return prefix
    text = prefix.decode('utf-8', 'replace')
    types = re.findall(r'(?<!\\)"type"\s*:\s*"([^"\\]+)"', text)
    ignored = (source == 'claude' and types and types[0] in
               {'api-request-blob', 'api-request', 'attachment', 'file-history-snapshot'})
    ignored = ignored or (source == 'codex' and types and (types[0] in
               {'world_state', 'token_usage_record', 'event_msg'} or
               types[:2] in [['response_item', 'function_call_output'],
                            ['response_item', 'custom_tool_call_output'],
                            ['response_item', 'reasoning'], ['response_item', 'additional_tools']]))
    chunks = [] if ignored else [prefix]
    while True:
        chunk = stream.readline(65536)
        if not chunk:
            return b''
        if not ignored:
            chunks.append(chunk)
        if chunk.endswith(b'\n'):
            break
    if ignored:
        stamp = re.search(r'"timestamp"\s*:\s*"([^"\\]+)"', text)
        return (json.dumps({'type': 'ignored', 'timestamp': stamp[1] if stamp else None}) + '\n').encode()
    return b''.join(chunks)


def sessions(ctx, state, source):
    root = ctx.home / ('.claude/projects' if source == 'claude' else '.codex/sessions')
    files = sorted(root.rglob('*.jsonl')) if root.exists() else []
    ctx.details['files'] = len(files)
    if not files:
        ctx.details['availability'] = 'missing'
    for path in files:
        key = digest(str(path))
        try:
            st = path.stat()
            old = state.get(key, {})
            offset = old.get('offset', 0)
            if old.get('inode') != st.st_ino or st.st_size < offset:
                old, offset = {}, 0
            # Old untouched transcripts need not be decoded on first backfill.
            if not old and st.st_mtime < ctx.since.timestamp():
                continue
            if offset == st.st_size:
                continue
            summary = dict(old.get('summary', {}))
            tools = dict(summary.get('tool_calls', {}))
            turns = summary.get('turns', 0)
            cwd = summary.get('cwd')
            start, end = summary.get('start'), summary.get('end')
            model = summary.get('model')
            sid = summary.get('session_id', path.stem)
            subagent = summary.get('subagent', 'subagents' in path.parts or path.stem.startswith('agent-'))
            floor = ctx.floor(bool(old))
            changed = False
            with path.open('rb') as stream:
                stream.seek(offset)
                while True:
                    position = stream.tell()
                    line = _session_line(stream, source)
                    if not line or not line.endswith(b'\n'):
                        break  # A concurrent writer's incomplete line is retried next time.
                    try:
                        d = json.loads(line)
                    except ValueError:
                        ctx.issue(source, ValueError())
                        break  # Don't acknowledge malformed lines, or a partial summary.
                    offset = stream.tell()
                    timestamp = d.get('timestamp')
                    if not timestamp:
                        continue
                    when = parse_time(timestamp)
                    start = min(start, iso(when)) if start else iso(when)
                    end = max(end, iso(when)) if end else iso(when)
                    cwd = d.get('cwd', cwd)
                    prompt, calls = '', []
                    if source == 'claude':
                        sid = d.get('sessionId', sid)
                        subagent = subagent or d.get('isSidechain', False)
                        msg = d.get('message', {})
                        if not isinstance(msg, dict):
                            msg = {}
                        model = msg.get('model', model)
                        if d.get('type') == 'user' and not d.get('isMeta'):
                            prompt = _text(msg.get('content'))
                        if d.get('type') == 'assistant':
                            for b in msg.get('content', []) if isinstance(msg.get('content'), list) else []:
                                if b.get('type') == 'tool_use':
                                    calls.append(b.get('name', 'unknown'))
                    else:
                        p = d.get('payload', {})
                        if not isinstance(p, dict):
                            continue
                        if d.get('type') == 'session_meta':
                            sid, cwd = p.get('id', p.get('session_id', sid)), p.get('cwd', cwd)
                            subagent = subagent or 'subagent' in json.dumps(p.get('source', p.get('thread_source', ''))).lower()
                        if d.get('type') == 'turn_context':
                            model, cwd = p.get('model', model), p.get('cwd', cwd)
                        if d.get('type') == 'response_item':
                            if p.get('type') == 'message' and p.get('role') == 'user':
                                prompt = _text(p.get('content'))
                            elif p.get('type') in ('function_call', 'custom_tool_call'):
                                calls.append(p.get('name', 'unknown'))
                        # event_msg user_message is a mirror: never ingest it twice.
                    for name in calls:
                        tools[name] = tools.get(name, 0) + 1
                    if prompt:
                        turns += 1
                        if when >= floor:
                            yield event(source, 'prompt', when, [key, d.get('uuid') or position],
                                        session_id=sid, text=short(prompt),
                                        text_truncated=len(prompt.encode()) > 2048,
                                        subagent=subagent)
                    changed = True
            if not changed:
                continue
            # An append-only revision of the cumulative session summary, not a finality claim.
            summary = dict(session_id=sid, project_dir=str(path.parent), cwd=cwd,
                           start=start, end=end, turns=turns, tool_calls=tools,
                           model=model, subagent=bool(subagent), summary_revision=offset)
            if end and parse_time(end) >= floor:
                yield event(source, 'session', end, [key, 'summary', offset], **summary)
            state[key] = dict(inode=st.st_ino, offset=offset, summary=clean(summary))
        except Exception as exc:
            ctx.issue(source, exc)


def claude(ctx, state):
    yield from sessions(ctx, state, 'claude')


def codex(ctx, state):
    yield from sessions(ctx, state, 'codex')


_EXTENDED = re.compile(r'^: (\d+):(\d+);([\s\S]*)$')


def history_records(stream):
    """Yield (position, end, line) for complete records; zsh continues lines with backslash."""
    while True:
        position = stream.tell()
        raw = stream.readline()
        if not raw or not raw.endswith(b'\n'):
            return
        while raw.endswith(b'\\\n'):
            more = stream.readline()
            if not more or not more.endswith(b'\n'):
                return
            raw = raw[:-2] + b'\n' + more
        raw = re.sub(rb'\x83([\x00-\xff])', lambda m: bytes([m[1][0] ^ 0x20]), raw)
        yield position, stream.tell(), raw.decode('utf-8', 'replace').rstrip('\n')


def history_command(line):
    match = _EXTENDED.match(line)
    result = {'text': digest(match[3] if match else line)}
    if match:
        result['record'] = digest(int(match[1]), int(match[2]), match[3])
    return result


def resume_after(stream, tail):
    """After zsh rewrites HISTFILE (trim, or EXTENDED_HISTORY turning old plain lines
    into `: <rewrite time>:0;cmd`), use exact timestamped identities. Only records
    originally lacking timestamps may match by text after conversion."""
    stream.seek(0)
    recent, found = [], 0
    for _, end, line in history_records(stream):
        recent = (recent + [history_command(line)])[-len(tail):]
        if len(recent) == len(tail) and all(
                isinstance(old, dict) and (new == old if 'record' in old else new['text'] == old['text'])
                for new, old in zip(recent, tail)):
            found = end
    return found


def shell(ctx, state):
    path = Path(os.environ.get('HISTFILE') or ctx.home / '.zsh_history').expanduser()
    try:
        st = path.stat()
    except FileNotFoundError:
        ctx.details['availability'] = 'missing'
        return
    key = digest(str(path))
    old = state.get(key, {})
    offset = old.get('offset', 0)
    tail = old.get('tail', [])
    floor = ctx.floor(bool(old))
    estimated = 0
    plain_commands = set(old.get('plain_commands', []))
    with path.open('rb') as stream:
        replaced = old.get('inode') != st.st_ino or st.st_size < offset
        if offset and not replaced and old.get('anchor'):
            stream.seek(max(0, offset - 128))
            replaced = digest(stream.read(min(offset, 128)).hex()) != old['anchor']
        # Upgrade pre-text-identity cursors from the already imported prefix.
        # If the file has changed, plain lines cannot safely be called new.
        if old and 'plain_commands' not in old:
            stream.seek(0)
            for _, end, line in history_records(stream):
                if not replaced and end > offset:
                    break
                if not _EXTENDED.match(line):
                    plain_commands.add(digest(line))
            plain_commands.update(t['text'] for t in tail
                                  if isinstance(t, dict) and 'record' not in t)
        previous_plain = plain_commands.copy()
        if replaced:
            offset = resume_after(stream, tail) if old and tail else 0
        stream.seek(offset)
        for position, offset, line in history_records(stream):
            match = _EXTENDED.match(line)
            when = unix(match[1]) if match else ctx.now
            if not match:
                estimated += 1
            command_id = history_command(line)
            tail = (tail + [command_id])[-3:]
            text_hash = command_id['text']
            # Plain positions/times are unstable on trim. zsh also gives retained
            # plain commands a fake timestamp and duration 0 when rewriting them.
            if text_hash in previous_plain and (not match or (replaced and int(match[2]) == 0)):
                continue
            if when >= floor:
                if not match:
                    plain_commands.add(text_hash)
                # Exact lines are identified by content so a rewritten file cannot duplicate them.
                identity = [key, line] if match else [key, position, text_hash]
                yield event('shell', 'command', when, identity,
                            command=short(match[3] if match else line, 8192),
                            duration_s=int(match[2]) if match else None,
                            ts_estimated=not bool(match), position=position)
        stream.seek(max(0, offset - 128))
        anchor = digest(stream.read(min(offset, 128)).hex())
    state[key] = dict(inode=st.st_ino, offset=offset, anchor=anchor, tail=tail,
                      plain_commands=sorted(plain_commands))
    ctx.details['timestamp_less_records'] = estimated


def git_cmd(repo, *args, allowed=(0,)):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS='0')
    p = subprocess.run(['git', '-C', str(repo), *args], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, env=env, timeout=20)
    if p.returncode not in allowed:
        raise RuntimeError('git_read_failed')
    return p.stdout.decode('utf-8', 'replace')


def git_roots(home, config=None):
    roots = (config or {}).get('git_roots') or DEFAULT_GIT_ROOTS
    home = str(home)
    return [Path(home + r[1:] if r.startswith('~') else r) for r in roots if isinstance(r, str)]


def repositories(home, config=None):
    result = {}
    candidates, seen = [], set()
    for root in git_roots(home, config):
        try:
            st = root.stat()
        except OSError:
            continue
        # Case-insensitive volumes: ~/Projects and ~/projects are one directory.
        if root.is_dir() and (st.st_dev, st.st_ino) not in seen:
            seen.add((st.st_dev, st.st_ino))
            candidates.append(root)  # A root may itself be a repository.
            candidates.extend(root.iterdir())
    # Also include a container's immediate repo children (e.g. workspace groups).
    for parent in list(candidates):
        if parent.is_dir() and not (parent / '.git').exists():
            candidates.extend(p for p in parent.iterdir() if p.is_dir())
    for repo in sorted(candidates):
        dot = repo / '.git'
        if dot.is_dir():
            common = dot.resolve()
        elif dot.is_file():
            gitdir = (repo / dot.read_text().strip().removeprefix('gitdir: ')).resolve()
            commonfile = gitdir / 'commondir'
            common = (gitdir / commonfile.read_text().strip()).resolve() if commonfile.exists() else gitdir
        else:
            continue
        # Report the main repo path even when its worktree was discovered first.
        main = common.parent if common.name == '.git' else repo
        st = common.stat()
        result.setdefault((st.st_dev, st.st_ino), main)
    return sorted(set(result.values()))


def git_stamp(repo):
    dot = repo / '.git'
    if dot.is_file():
        dot = (repo / dot.read_text().strip().removeprefix('gitdir: ')).resolve()
    commonfile = dot / 'commondir'
    common = (dot / commonfile.read_text().strip()).resolve() if commonfile.exists() else dot
    paths = [dot / 'HEAD', dot / 'logs/HEAD', common / 'packed-refs', common / 'config',
             common / 'shallow', common / 'info/grafts']
    # Any ref can introduce reachable commits, including nested/custom namespaces.
    for root in (common / 'refs', dot / 'refs', common / 'reftable'):
        if root.exists():
            for parent, dirs, files in os.walk(root):
                paths.append(Path(parent))
                paths.extend(Path(parent) / n for n in files)
    return digest([(str(p), file_stamp(p)) for p in sorted(set(paths))])


def git(ctx, state):
    repos = repositories(ctx.home, ctx.config)
    ctx.details['repositories'] = len(repos)
    if not repos:
        ctx.details['availability'] = 'missing'
    for repo in repos:
        key = digest(str(repo))
        try:
            revision = git_stamp(repo)
            old = state.get(key, {})
            if old.get('stamp') == revision:
                ctx.details['unchanged_repositories'] = ctx.details.get('unchanged_repositories', 0) + 1
                if old.get('empty'):
                    ctx.details['empty_repositories'] = ctx.details.get('empty_repositories', 0) + 1
                continue
            config = git_cmd(repo, 'config', '--get-regexp', r'^user\.(name|email)$', allowed=(0, 1))
            # The repo's effective user.name/user.email plus config `git_authors`.
            authors = {str(a).casefold() for a in ctx.config.get('git_authors', []) if a}
            authors.update(line.split(' ', 1)[1].casefold() for line in config.splitlines() if ' ' in line)
            try:
                # Snapshot ALL refs before log. Reading heads afterwards can
                # acknowledge a concurrent commit that log never saw.
                heads = sorted(set(git_cmd(repo, 'rev-parse', '--all', 'HEAD').splitlines()))
            except RuntimeError:
                if not git_cmd(repo, 'show-ref', '--head', '--hash', allowed=(0, 1)).strip():
                    ctx.details['empty_repositories'] = ctx.details.get('empty_repositories', 0) + 1
                    state[key] = dict(heads=[], stamp=revision, empty=True)
                    continue
                raise
            args = ['log', *heads, '--format=%x1e%H%x00%aI%x00%an%x00%ae%x00%s', '--numstat', '-z']
            base_args = list(args)
            if old.get('heads'):
                args += ['--not', *old['heads']]
            else:
                args += ['--since=' + iso(ctx.since)]
            try:
                log = git_cmd(repo, *args)
            except RuntimeError:
                if not old:
                    raise
                # A GC'd/rewritten boundary: bounded replay, Sink IDs still dedupe.
                log = git_cmd(repo, *base_args, '--since=' + iso(ctx.since))
            for record in log.split('\x1e')[1:]:
                fields = record.split('\x00', 5)
                if len(fields) < 6:
                    continue
                sha, stamp, name, email, subject, stats = fields
                if not ({name.casefold(), email.casefold()} & authors):
                    continue
                if ctx.explicit and parse_time(stamp) < ctx.since:
                    continue
                count = additions = deletions = 0
                for entry in stats.split('\x00'):
                    match = re.match(r'^\n?(\d+|-)\t(\d+|-)\t', entry)
                    if match:
                        count += 1
                        additions += int(match[1]) if match[1] != '-' else 0
                        deletions += int(match[2]) if match[2] != '-' else 0
                yield event('git', 'commit', stamp, [key, sha], repo=str(repo), commit_hash=sha,
                            subject=subject, files_changed=count, insertions=additions,
                            deletions=deletions)
            state[key] = dict(heads=sorted(set(heads)), stamp=revision)
        except Exception as exc:
            ctx.issue('repository', exc)


def media_projects(ctx, state):
    candidates = {}  # (app, path) -> (name, timestamp, clock)
    def add(app, path, name=None, stamp=None, clock='filesystem_mtime'):
        path = Path(path).expanduser()
        try:
            when = unix(path.stat().st_mtime) if stamp is None else stamp
        except FileNotFoundError:
            return
        candidates[app, str(path)] = (name or path.stem, when, clock)

    discovery = state.setdefault('_discovery', {})
    for app in ('JianyingPro', 'CapCut'):
        for root in (ctx.home / 'Movies' / app, ctx.home / 'Library/Application Support' / app):
            if not root.exists():
                continue
            # Metadata only, never parse the potentially huge timeline contents.
            metadata = sorted(tree_files(root, discovery, lambda n: n in ('root_meta_info.json', 'draft_meta_info.json')))
            for path in (p for p in metadata if p.name == 'root_meta_info.json'):
                try:
                    d = json.loads(path.read_text())
                    for item in d.get('all_draft_store', []):
                        if item.get('tm_draft_removed', 0):
                            continue
                        project = item.get('draft_fold_path')
                        if project:
                            stamp = item.get('tm_draft_modified', 0)
                            add(app, project, item.get('draft_name'),
                                unix(stamp / 1_000_000) if stamp else None,
                                'draft_unix_microseconds' if stamp else 'filesystem_mtime')
                except Exception as exc:
                    ctx.issue(app, exc)
            # Some versions lack a root list. JSON metadata may be encrypted; don't guess.
            for path in (p for p in metadata if p.name == 'draft_meta_info.json'):
                if (app, str(path.parent)) not in candidates:
                    add(app, path.parent, stamp=unix(path.stat().st_mtime))
    ae = ctx.home / 'Library/Preferences/Adobe/After Effects'
    for prefs in ae.glob('*/*Prefs*.txt'):
        try:
            text = prefs.read_text(errors='replace')
            # Adobe continuation lines split a quoted MRU value after a backslash.
            text = re.sub(r'"\\\s*\n\s*"', '', text)
            for value in re.findall(r'"([^"\n]+\.(?:aep|aepx))"', text, re.I):
                value = value.replace('\\/', '/')
                if value.startswith('/'):
                    add('After Effects', value)
                elif value.startswith('Macintosh HD:'):
                    add('After Effects', '/' + value.split(':', 1)[1].replace(':', '/'))
        except Exception as exc:
            ctx.issue('After Effects', exc)
    for recent in (ctx.home / 'Library/Application Support/Blender').glob('*/config/recent-files.txt'):
        try:
            for value in recent.read_text().splitlines():
                if value.strip().endswith('.blend'):
                    add('Blender', value.strip())
        except Exception as exc:
            ctx.issue('Blender', exc)
    # Final Cut libraries are packages, not ordinary .fcp project files.
    movies = ctx.home / 'Movies'
    # Find bundle markers via cached directory listings, without entering media packages.
    pending = [(movies, 0)]
    while pending:
        parent, depth = pending.pop()
        try:
            if not parent.exists():
                continue
            key = digest('final_cut', str(parent))
            stamp = file_stamp(parent)
            old = discovery.get(key, {})
            if old.get('stamp') == stamp:
                dirs = old['dirs']
            else:
                with os.scandir(parent) as entries:
                    dirs = [e.name for e in entries if e.is_dir()]
                if clean(dirs) == dirs and file_stamp(parent) == stamp:
                    discovery[key] = dict(stamp=stamp, dirs=dirs)
                else:
                    discovery.pop(key, None)
        except OSError as exc:
            ctx.issue('Final Cut', exc)
            continue
        for name in dirs:
            try:
                library = parent / name
                if name.endswith('.fcpbundle'):
                    stamps = [library.stat().st_mtime]
                    stamps.extend(db.stat().st_mtime for db in library.glob('*.flexolibrary*'))
                    add('Final Cut', library, stamp=unix(max(stamps)))
                elif depth < 3 and not library.is_symlink():
                    pending.append((library, depth + 1))
            except OSError as exc:
                ctx.issue('Final Cut', exc)
    ctx.details['projects'] = len(candidates)
    if not candidates:
        ctx.details['availability'] = 'missing'
    for (app, path), (name, when, clock) in sorted(candidates.items()):
        key = digest(app, path)
        stamp = iso(when)
        if state.get(key) == stamp:
            continue
        if when >= ctx.floor(key in state):
            yield event('media_projects', 'project', when, [key, stamp], app=app,
                        project_name=name, path=path, modified=stamp, time_basis=clock)
        state[key] = stamp


def calendar_paths(home):
    return [home / p for p in (
        'Library/Calendars/Calendar Cache',
        'Library/Calendars/Calendar.sqlitedb',
        'Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb',
        'Library/Group Containers/group.com.apple.calendar/Calendar/Calendar.sqlitedb')]


def calendar(ctx, state):
    available = 0
    for path in calendar_paths(ctx.home):
        key = digest(str(path))
        try:
            path.stat()
        except FileNotFoundError:
            continue
        except OSError as exc:
            ctx.issue('Calendar/TCC', exc)
            continue
        available += 1
        try:
            with snapshot(path) as con:
                tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                table = next((t for t in ('CalendarItem', 'ZCALENDARITEM', 'ZCALENDAREVENT', 'Event') if t in tables), None)
                if not table:
                    raise RuntimeError('unsupported_calendar_schema')
                columns = {r[1] for r in con.execute(f'PRAGMA table_info("{table}")')}
                def col(*names):
                    return next((n for n in names if n in columns), None)
                start = col('start_date', 'ZSTARTDATE', 'start')
                end = col('end_date', 'ZENDDATE', 'end')
                modified = col('last_modified', 'ZLASTMODIFIEDDATE', 'modification_date')
                title = col('summary', 'ZTITLE', 'title')
                location = col('location', 'ZLOCATION')
                uid = col('uuid', 'unique_identifier', 'ZUUID', 'uid')
                if not start or not title:
                    raise RuntimeError('unsupported_calendar_columns')
                # Timestamp watermark is overlapped inclusively for equal-time edits;
                # Sink dedupes (row, revision). Capture modifications, not future appointments.
                clock = modified or start
                old = state.get(key)
                lower = (ctx.floor(bool(old)) - APPLE).total_seconds()
                if old is not None and not ctx.explicit:
                    lower = old
                upper = (ctx.now - APPLE).total_seconds()
                high = old if old is not None else lower
                for row in con.execute(f'SELECT rowid AS _rowid,* FROM "{table}" WHERE "{clock}">=? AND "{clock}"<=? ORDER BY "{clock}"', (lower, upper)):
                    when = apple(row[clock])
                    revision = [row[c] for c in (start, end, title, location) if c]
                    yield event('calendar', 'event', when, [key, row['_rowid'], row[clock], revision],
                                uid=row[uid] if uid else str(row['_rowid']), title=row[title],
                                location=row[location] if location else None,
                                start=iso(apple(row[start])), end=iso(apple(row[end])) if end and row[end] is not None else None,
                                time_basis='modified' if modified else 'start')
                    high = max(high, row[clock])
                state[key] = high
        except Exception as exc:
            ctx.issue('Calendar/TCC', exc)
    ctx.details['databases'] = available
    if not available and not ctx.issues:
        ctx.details['availability'] = 'missing'


READERS = {f.__name__: f for f in (browser, claude, codex, shell, git, media_projects, calendar)}
