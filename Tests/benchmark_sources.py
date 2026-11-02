"""Synthetic reader benchmark (no real home/config/content): python3 Tests/benchmark_sources.py."""
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time

os.environ['LIFETRACE_CONFIG'] = os.devnull
os.environ['LIFETRACE_UTC_OFFSET'] = '+08:00'
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lifetrace_sources import core, readers  # noqa: E402


def benchmark(iterations=3):
    with tempfile.TemporaryDirectory(prefix='lifetrace-benchmark-') as directory:
        home = Path(directory)
        now = core.parse_time('2026-11-01T16:30:00+08:00')
        since = now - dt.timedelta(days=7)
        chromium = int((now - core.CHROME).total_seconds() * 1_000_000)
        databases = []
        for i in range(32):
            path = home / f'Library/Application Support/Chromium/Profile {i}/History'
            path.parent.mkdir(parents=True)
            con = sqlite3.connect(path)
            con.executescript('''CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT);
                CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER,
                visit_duration INTEGER,transition INTEGER,from_visit INTEGER);
                INSERT INTO urls VALUES(1,'https://example.test?q=synthetic','Synthetic');
                CREATE TABLE padding(data BLOB); INSERT INTO padding VALUES(zeroblob(1048576));''')
            con.execute('INSERT INTO visits VALUES(1,1,?,0,0,0)', (chromium,))
            con.commit(); con.close()
            databases.append(path)
        transcripts = {}
        for source, prefix in (('claude', '.claude/projects'), ('codex', '.codex/sessions')):
            for i in range(100):
                path = home / prefix / f'synthetic/{i}.jsonl'
                path.parent.mkdir(parents=True, exist_ok=True)
                if source == 'claude':
                    row = dict(type='user', timestamp=core.iso(now), uuid='first', sessionId=str(i),
                               message=dict(content='synthetic prompt'))
                else:
                    row = dict(type='response_item', timestamp=core.iso(now),
                               payload=dict(type='message', role='user', content='synthetic prompt'))
                path.write_text(json.dumps(row) + '\n')
                transcripts[source] = (path, row)
        repo = home / 'Projects/repo-0'
        repo.mkdir(parents=True)
        env = dict(os.environ, HOME=str(home), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_AUTHOR_DATE=core.iso(now), GIT_COMMITTER_DATE=core.iso(now))
        def git(*args):
            subprocess.run(['git', '-C', str(repo), *args], check=True, env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        git('init'); git('config', 'user.name', 'Synthetic Author')
        git('config', 'user.email', 'synthetic@example.test')
        git('commit', '--allow-empty', '-m', 'synthetic')
        for i in range(1, 54):
            shutil.copytree(repo, repo.parent / f'repo-{i}')
        metadata = None
        for i in range(100):
            project = home / f'Movies/JianyingPro/Projects/synthetic-{i}'
            project.mkdir(parents=True)
            metadata = project / 'draft_meta_info.json'
            metadata.write_text('{}')
            for j in range(10):
                (project / f'irrelevant-{j}.json').write_text('{}')
        shell = home / '.zsh_history'
        shell.write_text(f': {int(now.timestamp())}:0;echo synthetic\n')
        # No inherited HISTFILE may escape the synthetic home.
        os.environ['HISTFILE'] = str(shell)
        names = ('browser', 'claude', 'codex', 'shell', 'git', 'media_projects')
        states = {name: {} for name in names}
        def run(name):
            ctx = readers.Context(home, since, now, config={'git_roots': [str(repo.parent)]})
            started = time.perf_counter()
            count = sum(1 for _ in readers.READERS[name](ctx, states[name]))
            elapsed = time.perf_counter() - started
            if ctx.issues:
                raise RuntimeError('synthetic reader failure')
            return elapsed, count
        for name in names:
            run(name)
        results = {}
        for name in names:
            samples = [run(name) for _ in range(iterations)]
            assert all(count == 0 for _, count in samples), name
            results[name] = dict(steady_s=round(statistics.median(t for t, _ in samples), 6))
        with sqlite3.connect(databases[0]) as con:
            con.execute('INSERT INTO visits VALUES(2,1,?,0,0,0)', (chromium - 30 * 86400 * 1_000_000,))
        for path, row in transcripts.values():
            row = dict(row, uuid='second')
            with path.open('a') as stream:
                stream.write(json.dumps(row) + '\n')
        with shell.open('a') as stream:
            stream.write(f': {int(now.timestamp())}:0;echo new\n')
        git('commit', '--allow-empty', '-m', 'new synthetic')
        os.utime(metadata, (now.timestamp() + 1, now.timestamp() + 1))
        for name in names:
            elapsed, count = run(name)
            assert count > 0, name
            results[name].update(new_s=round(elapsed, 6), new_records=count)
        print(json.dumps(results, indent=2))


if __name__ == '__main__':
    benchmark()
