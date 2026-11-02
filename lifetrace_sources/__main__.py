"""Run independent readers, commit cursors only after durable appends."""
import argparse
import contextlib
import datetime as dt
import fcntl
import importlib.util
import json
import os
import tempfile
from pathlib import Path
import time

from .core import CONFIG, DEFAULT_DATA, UTC, Sink, atomic_json, iso, load_json, parse_time, clean
from .readers import Context, READERS, git_roots

READERS = dict(READERS)


def load_extra_readers(config=CONFIG):
    """Optional out-of-tree readers: config `extra_readers` lists Python files, each
    defining READERS = {name: reader(ctx, state)}. See SOURCES.md "Extra readers"."""
    loaded, failed = {}, []
    for entry in config.get('extra_readers', []):
        path = Path(str(entry)).expanduser()
        try:
            spec = importlib.util.spec_from_file_location('lifetrace_extra_' + path.stem, path)
            if spec is None or spec.loader is None:
                raise ImportError('not_a_python_file')
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            for name, reader in dict(module.READERS).items():
                if name in READERS or name in loaded or not callable(reader):
                    raise ValueError('reader_name_conflict')
                loaded[name] = reader
        except Exception as exc:
            failed.append(dict(source=path.stem, count=0, duplicates=0, status='unavailable',
                               issues=[{'target': 'extra_readers', 'reason': type(exc).__name__}]))
    return loaded, failed


def run_one(name, data_dir, since, *, dry_run=False, explicit=False, home=None, now=None, config=None):
    now = now or dt.datetime.now(UTC)
    home = Path(home) if home is not None else Path.home()
    root = Path(data_dir) / 'sources' / name
    started = time.monotonic()
    sink = Sink(root, dry_run)
    ctx = Context(home, since, now, explicit, CONFIG if config is None else config)
    report = dict(source=name, count=0, duplicates=0, status='ok')
    try:
        with contextlib.ExitStack() as stack:
            if not dry_run:
                root.mkdir(parents=True, exist_ok=True, mode=0o700)
                lock = stack.enter_context((root / '.run.lock').open('a'))
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                (root / '.run.lock').chmod(0o600)
            state = load_json(root / '.state.json')
            cursors = state.get('cursors', {})
            for row in READERS[name](ctx, cursors):
                sink.append(row)
            sink.close()  # fsync all lines BEFORE persisting any source cursor.
            report.update(count=sink.count, duplicates=sink.duplicates, **ctx.details)
            if ctx.issues:
                report.update(status='partial' if sink.count else 'unavailable', issues=ctx.issues)
            elif ctx.details.get('availability'):
                report['status'] = ctx.details['availability']
            report['runtime_s'] = round(time.monotonic() - started, 3)
            report['checked_at'] = iso(now)
            if not dry_run:
                atomic_json(root / '.state.json', dict(cursors=cursors))
                atomic_json(root / '.status.json', report)
    except Exception as exc:
        report.update(status='busy' if isinstance(exc, BlockingIOError) else 'unavailable',
                      count=sink.count, duplicates=sink.duplicates,
                      issues=[{'target': name, 'reason': type(exc).__name__}],
                      runtime_s=round(time.monotonic() - started, 3), checked_at=iso(now))
        # No cursor update on failed append/close/reader. Next run replays by stable ID.
        if not dry_run and report['status'] != 'busy':
            try:
                atomic_json(root / '.status.json', report)
            except OSError:
                pass
    finally:
        sink.finish()
    return report


def status(data_dir, home=None, config=None):
    home = Path(home) if home is not None else Path.home()
    probes = dict(browser=[home / 'Library/Application Support'], claude=[home / '.claude/projects'],
                  codex=[home / '.codex/sessions'], shell=[home / '.zsh_history'],
                  git=git_roots(home, CONFIG if config is None else config), media_projects=[home / 'Movies'],
                  calendar=[home / 'Library/Calendars'])
    results = []
    for name in READERS:
        try:
            last = load_json(Path(data_dir) / 'sources' / name / '.status.json')
            # Extra readers have no path probe: 'not_checked' until their first run.
            present = any(p.exists() for p in probes[name]) if name in probes else True
            results.append(last or dict(source=name, status='not_checked' if present else 'missing'))
        except (OSError, ValueError):
            results.append(dict(source=name, status='unavailable'))
    return dict(v='act.v1', query='sources.status', data_dir=str(data_dir), sources=results)


def rescrub(data_dir, dry_run=False):
    """Stream each day file into a private sibling, replacing only complete files."""
    result = dict(v='act.v1', query='sources.rescrub', dry_run=dry_run,
                  files=0, records=0, changed=0)
    for root in sorted((Path(data_dir) / 'sources').glob('*')):
        if not root.is_dir():
            continue
        with contextlib.ExitStack() as stack:
            if not dry_run:
                lock = stack.enter_context((root / '.run.lock').open('a'))
                (root / '.run.lock').chmod(0o600)
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for path in sorted(root.glob('*.jsonl')):
                name = None
                output = None
                try:
                    if not dry_run:
                        fd, name = tempfile.mkstemp(prefix='.rescrub-', dir=root)
                        output = os.fdopen(fd, 'w')
                    with path.open() as stream:
                        for line in stream:
                            if not line.endswith('\n'):
                                raise ValueError('incomplete_jsonl')
                            row = json.loads(line)
                            scrubbed = clean(row)
                            # Structural identities must survive historical sanitation.
                            scrubbed['id'] = row['id']
                            if row.get('source') == 'git' and 'hash' in row:
                                scrubbed['hash'] = row['hash']
                            result['records'] += 1
                            result['changed'] += scrubbed != row
                            if output is not None:
                                output.write(json.dumps(scrubbed, ensure_ascii=False, separators=(',', ':')) + '\n')
                    if output is not None:
                        output.flush()
                        os.fsync(output.fileno())
                        output.close()
                        os.replace(name, path)
                        fd = os.open(root, os.O_RDONLY)
                        try:
                            os.fsync(fd)
                        finally:
                            os.close(fd)
                    result['files'] += 1
                finally:
                    if output is not None:
                        output.close()
                    if name is not None:
                        Path(name).unlink(missing_ok=True)
    return result


def main(argv=None):
    extra, failed = load_extra_readers()
    READERS.update(extra)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    run = commands.add_parser('run')
    run.add_argument('--source', choices=list(READERS), action='append')
    run.add_argument('--since', type=parse_time, help='Offset-aware ISO; overrides initial backfill bound, not saved cursors')
    run.add_argument('--backfill-days', type=float, default=7, help='Initial backfill bound (default: 7)')
    run.add_argument('--data-dir', type=Path, default=DEFAULT_DATA)
    run.add_argument('--dry-run', action='store_true', help='Count only; write neither events, state, locks nor status')
    check = commands.add_parser('status')
    check.add_argument('--json', action='store_true')
    check.add_argument('--data-dir', type=Path, default=DEFAULT_DATA)
    scrub = commands.add_parser('rescrub')
    scrub.add_argument('--data-dir', type=Path, default=DEFAULT_DATA)
    scrub.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)
    if args.command == 'rescrub':
        try:
            result = rescrub(args.data_dir.expanduser(), args.dry_run)
        except Exception as exc:
            print(json.dumps(dict(v='act.v1', error=type(exc).__name__)))
            return 2
        print(json.dumps(result))
        return 0
    if args.command == 'status':
        result = status(args.data_dir.expanduser())
        result['sources'] += failed
        if args.json:
            print(json.dumps(result, ensure_ascii=False))
        else:
            for row in result['sources']:
                print(f"{row['source']}: {row['status']} (last run count: {row.get('count', 'unknown')})")
        return 0
    if args.backfill_days <= 0:
        parser.error('--backfill-days must be positive')
    now = dt.datetime.now(UTC)
    since = args.since or now - dt.timedelta(days=args.backfill_days)
    started = time.monotonic()
    rows = [run_one(name, args.data_dir.expanduser(), since, dry_run=args.dry_run,
                    explicit=args.since is not None, now=now) for name in dict.fromkeys(args.source or READERS)]
    rows += [] if args.source else failed
    print(json.dumps(dict(v='act.v1', query='sources.run', dry_run=args.dry_run, since=iso(since),
                         runtime_s=round(time.monotonic() - started, 3), sources=rows), ensure_ascii=False))
    # Missing apps/permissions are expected; independent readers still complete.
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
