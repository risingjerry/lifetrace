"""act.v1 persistence, explicit clocks and defense-in-depth text sanitizing."""
from __future__ import annotations

import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import tempfile
from urllib.parse import unquote_plus

UTC = dt.timezone.utc
APPLE = dt.datetime(2001, 1, 1, tzinfo=UTC)
CHROME = dt.datetime(1601, 1, 1, tzinfo=UTC)
DEFAULT_DATA = Path(os.environ.get('LIFETRACE_HOME') or Path.home() / '.local/share/lifetrace')
CONFIG_PATH = Path(os.environ.get('LIFETRACE_CONFIG') or Path.home() / '.config/lifetrace/config.json')


def load_config(path=CONFIG_PATH):
    """Same optional file as the Swift recorder; unknown keys ignored, bad JSON = defaults."""
    try:
        value = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


CONFIG = load_config()


def parse_offset(text):
    """'+08:00' / '-05:00' / 'Z' -> timedelta, else None."""
    if text in ('Z', 'z', '+00:00', '-00:00'):
        return dt.timedelta(0)
    match = re.fullmatch(r'([+-])(\d{2}):(\d{2})', str(text or ''))
    if not match or int(match[2]) > 14 or int(match[3]) > 59:
        return None
    delta = dt.timedelta(hours=int(match[2]), minutes=int(match[3]))
    return -delta if match[1] == '-' else delta


def local_zone(config=None):
    """Fixed UTC offset that decides day files and ISO output, identical to the recorder's:
    $LIFETRACE_UTC_OFFSET, then config `utc_offset`, then the machine's offset at start."""
    config = CONFIG if config is None else config
    for candidate in (os.environ.get('LIFETRACE_UTC_OFFSET'), config.get('utc_offset')):
        offset = parse_offset(candidate)
        if offset is not None:
            return dt.timezone(offset)
    return dt.timezone(dt.datetime.now().astimezone().utcoffset())


LOCAL = local_zone()


def parse_time(value):
    if isinstance(value, dt.datetime):
        result = value
    else:
        result = dt.datetime.fromisoformat(str(value).replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('A timezone offset is required')
    return result.astimezone(LOCAL)


def iso(value):
    return parse_time(value).isoformat(timespec='milliseconds')


def unix(value):
    return dt.datetime.fromtimestamp(float(value), UTC).astimezone(LOCAL)


def apple(value):
    return (APPLE + dt.timedelta(seconds=float(value))).astimezone(LOCAL)


def chrome(value):
    return (CHROME + dt.timedelta(microseconds=int(value))).astimezone(LOCAL)


def digest(*parts):
    return hashlib.sha256(json.dumps(parts, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()


# Order matters: remove whole PEMs/assignments before shorter token patterns.
_PATTERNS = [
    r'-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----[\s\S]*?(?:-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----|\Z)',
    r'''(?i)\b(?:authorization["']?\s*[:=]\s*["']?)?bearer\s+[^\s,"';]+["']?''',
    r'''(?i)\b(?:password|passwd|pwd|api[_-]?key|access[_-]?(?:token|key)|token|secret|authorization|密码|口令|令牌)\b["']?\s*[:=]\s*(?:"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|[^\s,;&]+)''',
    r'(?<!\d)1[3-9]\d{9}(?!\d)',
    r"(?i)(?<![a-z0-9.!#$%&'*+/=?^_`{|}~-])[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+",
    r'\bsk-[A-Za-z0-9_-]{6,}',
    r'\b(?:gh[pousr]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,})',
    r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
    r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
    r'(?<![A-Za-z0-9])(?=[A-Fa-f0-9]*[A-Fa-f])[A-Fa-f0-9]{32,}(?![A-Za-z0-9])',
    # Like the recorder: length alone is not evidence of a token, and '/' is
    # structural in URLs. Keep standalone slash-bearing base64 covered too.
    r'(?<![A-Za-z0-9_+/=-])(?=[A-Za-z0-9_+=-]*[0-9])(?=[A-Za-z0-9_+=-]*[a-z])(?=[A-Za-z0-9_+=-]*[A-Z])[A-Za-z0-9_+=-]{40,}(?![A-Za-z0-9_+/=-])',
    r"""(?<![^\s"'(\[{])(?=[A-Za-z0-9_+/=-]*[0-9])(?=[A-Za-z0-9_+/=-]*[a-z])(?=[A-Za-z0-9_+/=-]*[A-Z])[A-Za-z0-9_+/=-]{40,}(?=$|[\s"')\]},;])""",
]
_REDACT = [re.compile(p) for p in _PATTERNS]


_PARAM = re.compile(r"[?&#;]([^?&#;=\s<>\"']+)=")
_PARAM_END = re.compile(r"[&#;\s<>\"']")
_QUOTED_PARAM = re.compile(r'''"(?:\\.|[^"\\\n])*(?:"|(?=\n|\Z))|'(?:\\.|[^'\\\n])*(?:'|(?=\n|\Z))''')
_SENSITIVE_PARAM = re.compile(
    r'(?i)(?:phone|mobile|tel|email|lat|latitude|lng|lon|longitude|flat|flng|tlat|tlng|'
    r'coordinates?|location|geo|geolocation|token|key|secret|auth|authorization|'
    r'session|sid|sig|signature|code|password|passwd|pwd|openid|unionid|uid|userid|idcard)')


def _sensitive_param(name):
    name = unquote_plus(name)
    # CamelCase, snake_case and hyphenated aliases, plus *_key_id / open_id.
    words = re.sub(r'([a-z])([A-Z])', r'\1_\2', name).lower()
    return (_SENSITIVE_PARAM.fullmatch(re.sub(r'[_-]', '', words)) or
            any(_SENSITIVE_PARAM.fullmatch(w) for w in re.split(r'[_\-.\[\]]+', words)))


def _redact_assignments(text):
    names = iter(_PARAM.finditer(text))
    name = next(names, None)
    def replace(match):
        nonlocal name
        while name is not None and name.end() <= match.start():
            name = next(names, None)
        # Only URL parameter names are exempt; CLI flags and dotted keys are not.
        if name is not None and name.start() <= match.start() < name.end():
            return text[match.start():name.end()] + '[REDACTED]'
        return '[REDACTED]'
    return _REDACT[2].sub(replace, text)


def _redact_url_values(text):
    spans, end = [], 0
    for name in _PARAM.finditer(text):
        if name.end() > end:
            boundary = _PARAM_END.search(text, name.end())
            end = boundary.start() if boundary else len(text)
        # '?' can be data inside a value, including a nested query-like string.
        if _sensitive_param(name[1]) and (not spans or name.end() > spans[-1][1]):
            quoted = _QUOTED_PARAM.match(text, name.end())
            spans.append((name.end(), quoted.end() if quoted else end))
    parts, position = [], 0
    for start, end in spans:
        parts.extend((text[position:start], '[REDACTED]'))
        position = end
    parts.append(text[position:])
    return ''.join(parts)


def _redact_tokens(text):
    for pattern in _REDACT[3:]:
        text = pattern.sub('[REDACTED]', text)
    return text


def redact(text):
    for pattern in _REDACT[:2]:
        text = pattern.sub('[REDACTED]', text)
    text = _redact_url_values(_redact_assignments(text))
    parts, position = [], 0
    for name in _PARAM.finditer(text):
        # Scrub values separately so an email cannot consume '?q=' or other keys.
        parts.extend((_redact_tokens(text[position:name.start()]),
                      name[0][0] + _redact_tokens(name[1]) + '='))
        position = name.end()
    parts.append(_redact_tokens(text[position:]))
    return ''.join(parts)


class VerifiedMediaPath(str):
    """A path a reader got from the app's own cache lookup (not from free text). Only these
    keep structural 32-hex directory/file names; every other string is fully redacted."""


def redact_media_path(path):
    # Remove credentials/PEMs BEFORE splitting, including quoted values with '/'.
    # Preserve structural hashes before phone/email and generic token rules.
    for pattern in _REDACT[:2]:
        path = pattern.sub('[REDACTED]', path)
    path = _redact_assignments(path)
    return '/'.join(part if re.fullmatch(r'[A-Fa-f0-9]{32}(?:_(?:t|h|thumb))?(?:\.[A-Za-z0-9]{1,10})?', part)
                    else redact(part) for part in path.split('/'))


def clean(value):
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, dict):
        return {redact(str(k)): clean(v) for k, v in value.items() if v is not None}
    if isinstance(value, (list, tuple)):
        return [clean(v) for v in value]
    return value


def event(source, kind, timestamp, identity, **fields):
    sanitized = clean(fields)
    if isinstance(fields.get('media_path'), VerifiedMediaPath):
        sanitized['media_path'] = redact_media_path(fields['media_path'])
    if source == 'git' and 'commit_hash' in fields:
        sanitized['hash'] = fields['commit_hash']
        sanitized.pop('commit_hash', None)
    return dict(v='act.v1', ts=iso(timestamp), type=f'source.{source}.{kind}',
                source=source, id=digest(source, identity), **sanitized)


def short(text, size=2048):
    # Sanitize BEFORE truncating: cutting a token or PEM must not leak its prefix.
    return redact(text).encode('utf-8')[:size].decode('utf-8', 'ignore')


def load_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return {} if default is None else default


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix='.state-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        Path(name).unlink(missing_ok=True)


def file_stamp(path):
    """JSON-stable identity/revision; ctime also catches chmod and same-size rewrites."""
    try:
        st = Path(path).stat()
        return [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns]
    except FileNotFoundError:
        return None


def database_stamp(path):
    return [file_stamp(str(path) + suffix) for suffix in ('', '-wal')]


def tree_files(root, cache, wanted, *, max_depth=None, prune=(), on_error=None):
    """Cache directory listings, not whole subtrees: nested edits still get stat'ed.

    Only directory names and matching filenames are retained, never file contents.
    Secret-looking names disable caching that listing instead of storing raw text.
    """
    root = Path(root)
    pending = [(root, 0)]
    while pending:
        parent, depth = pending.pop()
        try:
            stamp = file_stamp(parent)
        except OSError as exc:
            if on_error is not None:
                on_error(exc)
            continue  # Match os.walk/rglob: inaccessible discovery branches are skipped.
        if stamp is None:
            continue
        key = digest(str(parent))
        old = cache.get(key, {})
        if old.get('stamp') == stamp:
            dirs, files = old['dirs'], old['files']
        else:
            dirs, files = [], []
            try:
                with os.scandir(parent) as entries:
                    for entry in entries:
                        if entry.is_symlink() and entry.is_dir():
                            continue
                        if entry.is_dir(follow_symlinks=False):
                            if entry.name not in prune:
                                dirs.append(entry.name)
                        elif wanted(entry.name):
                            files.append(entry.name)
            except OSError as exc:
                if on_error is not None:
                    on_error(exc)
                continue
            if clean([dirs, files]) == [dirs, files] and file_stamp(parent) == stamp:
                cache[key] = dict(stamp=stamp, dirs=dirs, files=files)
            else:
                cache.pop(key, None)
        for name in files:
            yield parent / name
        if max_depth is None or depth < max_depth:
            pending.extend((parent / name, depth + 1) for name in dirs)


@contextlib.contextmanager
def snapshot(path):
    """Copy DB + WAL into a private directory; never open the original with SQLite.

    Reject a moving family rather than acknowledge an inconsistent cursor. SQLite
    reconstructs SHM only in the private copy. No immutable=1 (it ignores WAL).
    """
    path = Path(path)
    def stamp():
        result = []
        for suffix in ('', '-wal'):
            try:
                st = Path(str(path) + suffix).stat()
                result.append((st.st_ino, st.st_size, st.st_mtime_ns))
            except FileNotFoundError:
                result.append(None)
        return result
    with tempfile.TemporaryDirectory(prefix='lifetrace-db-') as directory:
        target = Path(directory) / 'snapshot.db'
        for _ in range(3):
            before = stamp()
            if before[0] is None:
                raise FileNotFoundError()
            for suffix, info in zip(('', '-wal'), before):
                dest = Path(str(target) + suffix)
                dest.unlink(missing_ok=True)
                if info is not None:
                    shutil.copyfile(str(path) + suffix, dest)
                    dest.chmod(0o600)
            if before == stamp():
                break
        else:
            raise RuntimeError('snapshot_busy')
        con = sqlite3.connect(target)
        con.row_factory = sqlite3.Row
        con.execute('PRAGMA query_only=ON')
        try:
            yield con
        finally:
            con.close()


class Sink:
    """Day ID cache plus bounded-memory cross-day recovery of unacknowledged appends."""
    def __init__(self, root, dry_run=False):
        self.root, self.dry_run = Path(root), dry_run
        self.day = None
        self.ids = set()
        self.count = self.duplicates = 0
        self.fd = None
        self.recovery = None
        self.temporary = None
        self.checked_recovery = False

    def _recover(self):
        # Only an unacknowledged append needs cross-day recovery. In particular,
        # timestamp-less shell records get a different observed date on retry.
        # Normal incremental runs never rescan all history or build this index.
        self.checked_recovery = True
        files = list(self.root.glob('*.jsonl'))
        state = self.root / '.state.json'
        if not files or (state.exists() and all(p.stat().st_mtime_ns <= state.stat().st_mtime_ns for p in files)):
            return
        self.temporary = tempfile.TemporaryDirectory(prefix='lifetrace-replay-')
        self.recovery = sqlite3.connect(Path(self.temporary.name) / 'ids.sqlite')
        self.recovery.execute('PRAGMA cache_size=-1024')
        self.recovery.execute('CREATE TABLE ids(id TEXT PRIMARY KEY) WITHOUT ROWID')
        for path in files:
            with path.open() as stream:
                for line in stream:
                    if not line.endswith('\n'):
                        raise RuntimeError('output_jsonl_incomplete')
                    self.recovery.execute('INSERT OR IGNORE INTO ids VALUES(?)', (json.loads(line)['id'],))

    def append(self, row):
        if not self.checked_recovery:
            self._recover()
        if self.recovery is not None and self.recovery.execute('SELECT 1 FROM ids WHERE id=?', (row['id'],)).fetchone():
            self.duplicates += 1
            return
        day = row['ts'][:10]
        if day != self.day:
            self.close()
            self.day = day
            self.ids = set()
            path = self.root / (day + '.jsonl')
            if path.exists():
                with path.open() as stream:
                    for line in stream:
                        if not line.endswith('\n'):
                            raise RuntimeError('output_jsonl_incomplete')
                        try:
                            self.ids.add(json.loads(line)['id'])
                        except (ValueError, KeyError):
                            # Do not append beyond an incomplete/crashed line.
                            raise RuntimeError('output_jsonl_corrupt') from None
            if not self.dry_run:
                self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
                self.fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        if row['id'] in self.ids:
            self.duplicates += 1
            return
        if self.fd is not None:
            data = (json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n').encode()
            if os.write(self.fd, data) != len(data):
                raise OSError('short_append')
        self.ids.add(row['id'])
        if self.recovery is not None:
            self.recovery.execute('INSERT OR IGNORE INTO ids VALUES(?)', (row['id'],))
        self.count += 1

    def close(self):
        if self.fd is not None:
            try:
                os.fsync(self.fd)
            finally:
                os.close(self.fd)
                self.fd = None

    def finish(self):
        try:
            self.close()
        finally:
            if self.recovery is not None:
                self.recovery.close()
                self.recovery = None
            if self.temporary is not None:
                self.temporary.cleanup()
                self.temporary = None
