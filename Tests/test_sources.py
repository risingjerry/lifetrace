import datetime as dt
import json
import os
import sys
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch

# Isolate from the machine: no user config/extra readers; pin the day offset the fixtures use.
os.environ['LIFETRACE_CONFIG'] = os.devnull
os.environ['LIFETRACE_UTC_OFFSET'] = '+08:00'

from lifetrace_sources import core, readers  # noqa: E402
from lifetrace_sources import __main__ as cli  # noqa: E402
from lifetrace_sources.__main__ import run_one, status  # noqa: E402

NOW = core.parse_time('2026-11-01T16:30:00+08:00')
SINCE = NOW - dt.timedelta(days=1)


class Fixtures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='lifetrace-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.data = self.root / 'data'

    def path(self, name):
        p = self.home / name
        p.parent.mkdir(parents=True, exist_ok=True)
        return p

    def jsonl(self, path, rows, mode='w'):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open(mode) as f:
            for row in rows:
                f.write(json.dumps(row) + '\n')

    def run_reader(self, name, dry=False):
        return run_one(name, self.data, SINCE, home=self.home, now=NOW, dry_run=dry)

    def events(self, name):
        return [json.loads(line) for p in sorted((self.data / 'sources' / name).glob('*.jsonl'))
                for line in p.read_text().splitlines()]

    def db(self, path, sql):
        con = sqlite3.connect(path)
        con.executescript(sql)
        con.commit()
        return con

    def test_clocks_independent_of_machine_timezone(self):
        old = os.environ.get('TZ')
        try:
            os.environ['TZ'] = 'America/New_York'
            import time
            time.tzset()
            expected = '2001-01-01T08:00:00.123+08:00'
            self.assertEqual(core.iso(core.apple(.123)), expected)
            micro = int((core.APPLE - core.CHROME).total_seconds() * 1_000_000) + 123000
            self.assertEqual(core.iso(core.chrome(micro)), expected)
            self.assertEqual(core.iso(core.unix(core.APPLE.timestamp() + .123)), expected)
            with self.assertRaises(ValueError):
                core.parse_time('2026-11-01T12:00:00')
        finally:
            if old is None:
                os.environ.pop('TZ', None)
            else:
                os.environ['TZ'] = old
            time.tzset()

    def test_redaction_and_truncation(self):
        secrets = ['sk-proj-' + 'a' * 60, 'ghp_' + 'b' * 36, 'AKIA' + 'A' * 16,
                   'eyJhbGciOiJIUzI1NiJ9.eyJmb28iOiJiYXIifQ.signature123',
                   'abcdef0123456789' * 4, 'AbCd_123+EfGh/456' * 5,
                   'password="hello world"', "passwd='top secret'", 'api_key=xyz123',
                   '-----BEGIN RSA PRIVATE' + ' KEY-----\nsecret\n-----END RSA PRIVATE' + ' KEY-----',
                   '-----BEGIN PRIVATE' + ' KEY-----\nunfinished']
        for secret in secrets:
            with self.subTest(kind=secret[:10]):
                self.assertNotEqual(core.redact(secret), secret)
                self.assertNotIn(secret, json.dumps(core.clean({'nested': [secret]})))
        self.assertEqual(core.redact('ordinary sentence 2026-11-01'), 'ordinary sentence 2026-11-01')
        text = '前缀' * 400 + secrets[0]
        bounded = core.short(text)
        self.assertLessEqual(len(bounded.encode()), 2048)
        self.assertNotIn('sk-proj', bounded)
        row = core.event('git', 'commit', NOW, 'id', commit_hash='a' * 40, subject=secrets[0])
        self.assertEqual(row['hash'], 'a' * 40)
        self.assertEqual(row['subject'], '[REDACTED]')

    def test_redaction_preserves_ordinary_url_paths_and_masks_mixed_blobs(self):
        urls = [
            'https://x.com/someone/status/1985123456789012345',
            'https://github.com/example/ExampleRepo/blob/main/Sources/Feature2/README.md',
            'https://example.test/' + 'a-long-readable-article-slug-' * 4,
            'https://example.test/' + '1234567890' * 6,
            'https://example.test:8080/ExampleRepo/Feature2/' + 'long-path-' * 5,
        ]
        blob = 'aGVsbG8gd29ybGQgdGhpcyBpcyBhIHNlY3JldCB0b2tlbjEyMw=='
        for url in urls:
            with self.subTest(url=url):
                self.assertEqual(core.redact(url), url)
        for token in (blob, 'AbCd_123+EfGh/456' * 5, 'AbCd_123-EfGh456' * 4,
                      '/' + blob, blob + '/AbCd1234'):
            self.assertEqual(core.redact(token), '[REDACTED]')
            self.assertEqual(core.redact('blob: "' + token + '"'), 'blob: "[REDACTED]"')
        path = '/cache/' + 'a' * 32 + '/preview.jpg'
        self.assertEqual(core.redact_media_path(core.VerifiedMediaPath(path)), path)
        self.assertEqual(core.redact_media_path('/cache/' + blob + '/preview.jpg'),
                         '/cache/[REDACTED]/preview.jpg')
        self.jsonl(self.data / 'sources/browser/2026-11-01.jsonl',
                   [dict(v='act.v1', id=str(i), source='browser', url=url)
                    for i, url in enumerate(urls)])
        self.assertEqual(cli.rescrub(self.data)['changed'], 0)

    def test_rescrub_keeps_verified_media_path_hashes(self):
        media = '/x/msg/attach/' + '1300900b61034e8dd85b2c35adb546ac' + '/2026-10/' + 'a' * 32 + '.mp4'
        self.jsonl(self.data / 'sources/chat/2026-11-01.jsonl',
                   [dict(v='act.v1', id='m1', source='chat', media_path=media, text='call 13800000000')])
        self.assertEqual(cli.rescrub(self.data)['changed'], 1)
        row = json.loads((self.data / 'sources/chat/2026-11-01.jsonl').read_text())
        self.assertEqual(row['media_path'], media)
        self.assertNotIn('13800000000', row['text'])

    def test_email_in_url_path_keeps_host(self):
        self.assertEqual(core.redact('https://mail.example.com/inbox/jane.doe@example.org'),
                         'https://mail.example.com/inbox/[REDACTED]')

    def test_url_parameters_and_free_text_privacy(self):
        names = ('phone mobile tel email lat lng lon flat flng tlat tlng coordinate '
                 'coordinates location geo token access_token daijia_token key api_key '
                 'access_key_id secret auth session sid sig signature code password pwd '
                 'openid open_id unionid uid user_id idcard id_card latitude longitude '
                 'phoneNumber userLocation geo_location access-key-id api-token access-token PHONE').split()
        for name in names:
            for delimiter in ('?', '&', '#', '#/route?'):
                with self.subTest(name=name, delimiter=delimiter):
                    url = 'https://example.test/x' + delimiter + name + '=fake-value&page=2'
                    expected = 'https://example.test/x' + delimiter + name + '=[REDACTED]&page=2'
                    self.assertEqual(core.redact(url), expected)
                    self.assertEqual(core.redact(expected), expected)
        example = ('https://example.test/x?h=1#/order-list?phone=13800000000&flat=29.5&flng=106.5'
                   '&lat=29.5&lng=106.5&open_id=&access_key_id=37&daijia_token=&timestamp=1700000000000')
        scrubbed = core.redact(example)
        for value in ('13800000000', '29.5', '106.5', 'access_key_id=37'):
            self.assertNotIn(value, scrubbed)
        self.assertIn('h=1#/order-list?phone=[REDACTED]', scrubbed)
        self.assertIn('timestamp=1700000000000', scrubbed)
        self.assertEqual(core.redact('https://example.test?%70hone=123&open_id=&q=hello'),
                         'https://example.test?%70hone=[REDACTED]&open_id=[REDACTED]&q=hello')
        for value in ('person@example.test', '13800000000'):
            self.assertEqual(core.redact('https://example.test?' + value + '=value'),
                             'https://example.test?[REDACTED]=value')
        text = 'call 13800000000 or 19900000000; mail person+tag@example.test'
        self.assertEqual(core.redact(text), 'call [REDACTED] or [REDACTED]; mail [REDACTED]')
        for text in ('https://example.test/path?q=hello&page=2#/route?sort=asc',
                     'plain text 12345; plate=blue; language=en; code review',
                     '013800000000 138000000001 12800000000'):
            self.assertEqual(core.redact(text), text)

    def test_privacy_cli_assignments_url_boundaries_and_verified_hashes(self):
        for text in ('--password=demo-pass', '--token=demo-token', '--api-key=demo-key',
                     'config.password=demo-pass', 'settings.token=demo-token'):
            with self.subTest(text=text):
                self.assertNotIn(text.split('=', 1)[1], core.redact(text))
        for prefix in ('https://example.test?', 'https://example.test#/route?'):
            for name in ('token', 'password', 'access-token'):
                url = prefix + name + '=prefix?private-suffix&page=2'
                expected = prefix + name + '=[REDACTED]&page=2'
                self.assertEqual(core.redact(url), expected)
            for value in ('person+tag@example.test', '13800000000'):
                self.assertEqual(core.redact(prefix + 'q=' + value + '&page=2'),
                                 prefix + 'q=[REDACTED]&page=2')
        for name in ('token', 'lat'):
            for value in ('"short secret"', "'29.5'"):
                self.assertEqual(core.redact('https://example.test?' + name + '=' + value + '&page=2'),
                                 'https://example.test?' + name + '=[REDACTED]&page=2')
        self.assertEqual(core.redact('https://example.test?q=https://nested.test?token=private&page=2'),
                         'https://example.test?q=https://nested.test?token=[REDACTED]&page=2')
        md5 = 'a' * 10 + '13800000000' + 'b' * 11
        self.assertEqual(len(md5), 32)
        path = f'/cache/{md5}/{md5}_thumb.jpg'
        self.assertEqual(core.redact_media_path(core.VerifiedMediaPath(path)), path)
        self.assertNotIn('13800000000', core.redact(path))
        self.assertEqual(core.redact_media_path('/cache/13800000000/file.txt'),
                         '/cache/[REDACTED]/file.txt')

    def test_redaction_long_non_email_token_is_bounded(self):
        env = dict(os.environ, HOME=str(self.home), LIFETRACE_CONFIG=os.devnull,
                   LIFETRACE_UTC_OFFSET='+08:00')
        # A missing left boundary in the email regex retries every token suffix.
        result = subprocess.run([sys.executable, '-c',
            "from lifetrace_sources.core import redact; "
            "assert redact('x' * 1000000) == 'x' * 1000000; "
            "assert redact('x' * 999997 + 'A1x') == '[REDACTED]'"],
            env=env, capture_output=True, timeout=3, check=True)
        self.assertEqual(result.stdout, b'')

    def test_rescrub_cli_summary_errors_and_busy_writer(self):
        import fcntl
        root = self.data / 'sources/browser'
        root.mkdir(parents=True)
        path = root / '2026-11-01.jsonl'
        self.jsonl(path, [dict(v='act.v1', id='a' * 64, source='browser', text='13800000000')])
        original = path.read_bytes()
        env = dict(os.environ, HOME=str(self.home), LIFETRACE_CONFIG=os.devnull,
                   LIFETRACE_UTC_OFFSET='+08:00')
        command = [sys.executable, '-m', 'lifetrace_sources', 'rescrub', '--data-dir', str(self.data)]
        def run(*args):
            result = subprocess.run(command + list(args), env=env, capture_output=True, timeout=3)
            self.assertEqual(result.stderr, b'')
            self.assertEqual(len(result.stdout.splitlines()), 1)
            return result.returncode, json.loads(result.stdout)
        code, summary = run('--dry-run')
        self.assertEqual(code, 0)
        self.assertEqual(summary, dict(v='act.v1', query='sources.rescrub', dry_run=True,
                                      files=1, records=1, changed=1))
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse((root / '.run.lock').exists())
        with (root / '.run.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            code, error = run()
        self.assertEqual(code, 2)
        self.assertEqual(error, dict(v='act.v1', error='BlockingIOError'))
        self.assertEqual(path.read_bytes(), original)
        path.write_bytes(original + b'{')
        code, error = run()
        self.assertEqual(code, 2)
        self.assertEqual(error, dict(v='act.v1', error='ValueError'))
        self.assertEqual(path.read_bytes(), original + b'{')
        self.assertEqual(list(root.glob('.rescrub-*')), [])

    def test_rescrub_atomic_private_order_ids_and_dry_run(self):
        root = self.data / 'sources/browser'
        root.mkdir(parents=True)
        path = root / '2026-11-01.jsonl'
        rows = [dict(v='act.v1', id='a' * 64, source='browser',
                     url='https://example.test#/order?phone=13800000000&lat=29.5&q=hello'),
                dict(v='act.v1', id='b' * 64, source='git', hash='c' * 40,
                     subject='person@example.test', nested={'phone=plain': '13800000000'})]
        self.jsonl(path, rows)
        original = path.read_bytes()
        expected = dict(v='act.v1', query='sources.rescrub', dry_run=True, files=1, records=2, changed=2)
        self.assertEqual(cli.rescrub(self.data, True), expected)
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse((root / '.run.lock').exists())
        with patch('lifetrace_sources.__main__.os.replace', side_effect=OSError):
            with self.assertRaises(OSError):
                cli.rescrub(self.data)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(list(root.glob('.rescrub-*')), [])
        self.assertEqual(cli.rescrub(self.data)['changed'], 2)
        scrubbed = [json.loads(l) for l in path.read_text().splitlines()]
        self.assertEqual([r['id'] for r in scrubbed], [r['id'] for r in rows])
        self.assertEqual(scrubbed[1]['hash'], rows[1]['hash'])
        self.assertNotIn('13800000000', path.read_text())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(cli.rescrub(self.data)['changed'], 0)
        path.write_bytes(original + b'{')
        with self.assertRaises(ValueError):
            cli.rescrub(self.data)
        self.assertEqual(path.read_bytes(), original + b'{')

    def test_day_split_crash_replay_and_atomic_state(self):
        root = self.data / 'sources/browser'
        sink = core.Sink(root)
        a = core.event('browser', 'visit', '2026-11-01T15:59:59.999Z', 1)
        b = core.event('browser', 'visit', '2026-11-01T16:00:00.000Z', 2)
        with patch('lifetrace_sources.core.os.write', wraps=os.write) as write:
            sink.append(a)
            sink.append(b)
            sink.finish()
            self.assertEqual(write.call_count, 2)
        self.assertEqual({p.name for p in root.glob('*.jsonl')}, {'2026-11-01.jsonl', '2026-11-02.jsonl'})
        sink = core.Sink(root)
        sink.append(a)
        sink.append(b)
        sink.finish()
        self.assertEqual(sink.count, 0)
        self.assertEqual(sink.duplicates, 2)
        core.atomic_json(root / '.state.json', {'cursor': 2})
        self.assertEqual(core.load_json(root / '.state.json'), {'cursor': 2})
        self.assertEqual(list(root.glob('.state-*')), [])

    def test_redaction_full_bearer_and_assignment_values(self):
        credential = 'abcDEF1234567890'
        self.assertEqual(core.redact('Authorization: Bearer ' + credential), '[REDACTED]')
        for key in ('token', 'secret', 'password', 'passwd', 'api_key', 'apikey',
                    'access_key', '密码', '口令', '令牌'):
            for separator in ('=', ': '):
                for value in (credential, '"two word secret"', "'two word secret'"):
                    with self.subTest(key=key, separator=separator, value=value):
                        self.assertEqual(core.redact(key + separator + value), '[REDACTED]')

    def test_shell_zsh_metafied_chinese_continuations_and_raw_cursor(self):
        # zsh Meta=0x83 escapes bytes 0x80..0x9f, NUL and 0xa0, XOR 0x20.
        command = 'echo 中文\n下一行'
        plain = f': {int(NOW.timestamp())}:0;{command}'.encode()
        metafied = b''.join(bytes((0x83, b ^ 0x20)) if b == 0 or 0x80 <= b <= 0xa0
                            else bytes((b,)) for b in plain)
        # This exact prefix was also checked against /bin/zsh -f -i `fc -W`.
        self.assertIn(b'echo \xe4\xb8\xad\xe6\x83\xb6\x83\xa7', metafied)
        raw = metafied.replace(b'\n', b'\\\n') + b'\n'
        p = self.path('.zsh_history')
        p.write_bytes(raw + b'echo \xe6\x83\xb6\x83')
        state = {}
        with patch.dict(os.environ, {}, clear=True):
            ctx = readers.Context(self.home, SINCE, NOW)
            rows = list(readers.shell(ctx, state))
            self.assertEqual(rows[0]['command'], command)
            self.assertEqual(len(rows), 1)
            self.assertEqual(state[core.digest(str(p))]['offset'], len(raw))
            self.assertEqual(list(readers.shell(ctx, state)), [])
            self.assertEqual(state[core.digest(str(p))]['offset'], len(raw))
            with p.open('ab') as stream:
                stream.write(b'\xa7\n')  # Completes the final metafied byte of 文.
            rows = list(readers.shell(ctx, state))
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]['command'], 'echo 文')
            self.assertEqual(rows[0]['position'], len(raw))
            self.assertEqual(state[core.digest(str(p))]['offset'], p.stat().st_size)

    def test_shell_rewrite_repeated_group_keeps_new_timestamped_commands(self):
        p = self.path('.zsh_history')
        epoch = int(NOW.timestamp()) - 60
        commands = ('git status', 'pwd', 'ls')
        old = ''.join(f': {epoch+i}:0;{cmd}\n' for i, cmd in enumerate(commands))
        p.write_text(old)
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(self.run_reader('shell')['count'], 3)
            fresh = self.path('.zsh_history.new')
            fresh.write_text(old + ''.join(f': {epoch+10+i}:0;{cmd}\n'
                                          for i, cmd in enumerate(commands)))
            os.replace(fresh, p)
            report = self.run_reader('shell')
            self.assertEqual((report['count'], report['duplicates']), (3, 0))
            self.assertEqual([r['command'] for r in self.events('shell')[3:]], list(commands))
            self.assertEqual(self.run_reader('shell')['count'], 0)

    def test_shell_rewrite_anchor_includes_duration(self):
        p = self.path('.zsh_history')
        epoch = int(NOW.timestamp())
        old = f': {epoch}:0;git status\n: {epoch}:0;pwd\n: {epoch}:0;ls\n'
        p.write_text(old)
        state = {}
        ctx = readers.Context(self.home, SINCE, NOW)
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(len(list(readers.shell(ctx, state))), 3)
            fresh = self.path('.zsh_history.new')
            fresh.write_text(old + old.replace(':0;', ':1;'))
            os.replace(fresh, p)
            rows = list(readers.shell(ctx, state))
            self.assertEqual([row['duration_s'] for row in rows], [1, 1, 1])

    def test_cross_day_estimated_timestamp_crash_dedupes(self):
        root = self.data / 'sources/shell'
        first = core.event('shell', 'command', NOW, 'same', ts_estimated=True)
        retry = core.event('shell', 'command', NOW + dt.timedelta(days=1), 'same', ts_estimated=True)
        sink = core.Sink(root)
        sink.append(first)
        sink.finish()  # No state commit: simulated crash.
        sink = core.Sink(root)
        sink.append(retry)
        self.assertEqual(sink.count, 0)
        self.assertEqual(sink.duplicates, 1)
        sink.finish()
        self.assertEqual(len(list(root.glob('*.jsonl'))), 1)

    def test_incomplete_valid_json_is_not_appended_through(self):
        root = self.data / 'sources/shell'
        root.mkdir(parents=True)
        row = core.event('shell', 'command', NOW, 'old')
        path = root / (row['ts'][:10] + '.jsonl')
        path.write_text(json.dumps(row))  # Valid JSON, missing final newline.
        sink = core.Sink(root)
        try:
            with self.assertRaises(RuntimeError):
                sink.append(core.event('shell', 'command', NOW, 'new'))
        finally:
            sink.finish()
        self.assertEqual(path.read_text(), json.dumps(row))

    def test_no_cursor_on_append_failure_then_recovery(self):
        def reader(ctx, state):
            state['cursor'] = 42
            yield core.event('shell', 'command', NOW, 42, command='ok')
        with patch.dict('lifetrace_sources.__main__.READERS', shell=reader):
            with patch('lifetrace_sources.core.os.write', side_effect=OSError):
                report = self.run_reader('shell')
            self.assertEqual(report['status'], 'unavailable')
            self.assertFalse((self.data / 'sources/shell/.state.json').exists())
            self.assertEqual(self.run_reader('shell')['count'], 1)
            # Simulate a crash after append but before cursor rename.
            (self.data / 'sources/shell/.state.json').unlink()
            self.assertEqual(self.run_reader('shell')['duplicates'], 1)
            self.assertEqual(len(self.events('shell')), 1)

    def test_dry_run_writes_nothing_and_missing_status(self):
        report = self.run_reader('shell', dry=True)
        self.assertEqual(report['status'], 'missing')
        self.assertFalse(self.data.exists())
        self.assertEqual(len(status(self.data, self.home)['sources']), 7)

    def test_browser_chromium_safari_profiles_and_wal(self):
        stamp = int((NOW.astimezone(core.UTC) - core.CHROME).total_seconds() * 1_000_000)
        p = self.path('Library/Application Support/Dia/User Data/Profile 1/History')
        con = self.db(p, '''PRAGMA journal_mode=WAL;
            CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT);
            CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER,visit_duration INTEGER,transition INTEGER,from_visit INTEGER);''')
        self.addCleanup(con.close)
        con.execute('INSERT INTO urls VALUES(1,?,?)', ('https://example.test?password=hidden', 'a title'))
        con.execute('INSERT INTO visits VALUES(1,1,?,1200000,1,0)', (stamp,))
        con.commit()  # Remains in WAL, not checkpointed.
        chrome_path = self.path('Library/Application Support/Google/Chrome/Default/History')
        copied = sqlite3.connect(chrome_path)
        con.backup(copied)
        copied.close()
        safari = self.path('Library/Safari/History.db')
        sc = self.db(safari, '''CREATE TABLE history_items(id INTEGER PRIMARY KEY,url TEXT);
            CREATE TABLE history_visits(id INTEGER PRIMARY KEY,history_item INTEGER,visit_time REAL,title TEXT);
            INSERT INTO history_items VALUES(1,'https://example.test');''')
        sc.execute('INSERT INTO history_visits VALUES(1,1,?,"Safari")', ((NOW - core.APPLE).total_seconds(),))
        sc.commit()
        sc.close()
        self.assertEqual(self.run_reader('browser')['count'], 3)
        rows = self.events('browser')
        dia = next(r for r in rows if r['browser'] == 'Dia')
        self.assertIn('Google Chrome', {r['browser'] for r in rows})
        self.assertEqual(dia['visit_duration'], 1.2)
        self.assertNotIn('hidden', dia['url'])
        with patch.object(readers, 'snapshot', side_effect=AssertionError('unchanged DB copied')):
            self.assertEqual(self.run_reader('browser')['count'], 0)
        con.execute('INSERT INTO visits VALUES(2,1,?,0,2,1)', (stamp + 1000,))
        con.commit()
        self.assertEqual(self.run_reader('browser')['count'], 1)
        self.assertEqual(self.events('browser')[-1]['from_visit_url'], dia['url'])

    def test_browser_initial_bound_and_new_backdated_visits(self):
        stamp = int((NOW - core.CHROME).total_seconds() * 1_000_000)
        old = stamp - 30 * 86400 * 1_000_000
        p = self.path('Library/Application Support/Chromium/Default/History')
        con = self.db(p, """CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT);
            CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER,visit_duration INTEGER,transition INTEGER,from_visit INTEGER);
            INSERT INTO urls VALUES(1,'https://example.test','title');""")
        self.addCleanup(con.close)
        con.execute('INSERT INTO visits VALUES(1,1,?,0,0,0)', (stamp,))
        con.execute('INSERT INTO visits VALUES(2,1,?,0,0,0)', (old,))
        con.commit()
        self.assertEqual(self.run_reader('browser')['count'], 1)
        self.assertEqual(self.run_reader('browser')['count'], 0)
        con.execute('INSERT INTO visits VALUES(3,1,?,0,0,0)', (old+1000,))
        con.commit()
        self.assertEqual(self.run_reader('browser')['count'], 1)
        self.assertEqual(self.run_reader('browser')['count'], 0)

    def test_permission_failure_is_independent(self):
        p = self.path('Library/Safari/History.db')
        p.touch()
        with patch('lifetrace_sources.readers.snapshot', side_effect=PermissionError):
            r = self.run_reader('browser')
        self.assertEqual(r['status'], 'unavailable')
        self.assertEqual(r['issues'][0]['reason'], 'PermissionError')

    def test_discovery_cache_observes_nested_new_files_and_same_size_edits(self):
        root = self.path('cache/nested/deep/one.jsonl').parent
        first = root / 'one.jsonl'
        first.write_text('old')
        cache = {}
        find = lambda: sorted(core.tree_files(self.home / 'cache', cache, lambda n: n.endswith('.jsonl')))
        self.assertEqual(find(), [first])
        with patch('lifetrace_sources.core.os.scandir', side_effect=AssertionError('unchanged listing scanned')):
            self.assertEqual(find(), [first])
        stamp = (self.home / 'cache').stat().st_mtime_ns
        second = root / 'two.jsonl'
        second.write_text('new')
        self.assertEqual(find(), [first, second])
        self.assertEqual((self.home / 'cache').stat().st_mtime_ns, stamp)
        before = core.file_stamp(first)
        first.write_text('NEW')
        self.assertNotEqual(core.file_stamp(first), before)
        first.unlink()
        self.assertEqual(find(), [second])

    def test_browser_fast_path_matches_forced_query_after_wal_append(self):
        import copy
        p = self.path('Library/Application Support/Chromium/Default/History')
        con = self.db(p, """PRAGMA journal_mode=WAL;
            CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT);
            CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER,visit_duration INTEGER,transition INTEGER,from_visit INTEGER);
            INSERT INTO urls VALUES(1,'https://example.test?q=useful','title');""")
        self.addCleanup(con.close)
        stamp = int((NOW - core.CHROME).total_seconds() * 1_000_000)
        con.execute('INSERT INTO visits VALUES(1,1,?,0,0,0)', (stamp,)); con.commit()
        state = {}
        context = lambda: readers.Context(self.home, SINCE, NOW)
        self.assertEqual(len(list(readers.browser(context(), state))), 1)
        con.execute('INSERT INTO visits VALUES(2,1,?,0,0,0)', (stamp - 30 * 86400 * 1_000_000,)); con.commit()
        slow = copy.deepcopy(state)
        for value in slow.values():
            if isinstance(value, dict):
                value.pop('stamp', None)
        fast_rows = list(readers.browser(context(), state))
        self.assertEqual(fast_rows, list(readers.browser(context(), slow)))
        self.assertEqual(len(fast_rows), 1)
        # New profile under an existing nested directory must be discovered too.
        new = p.parent / 'nested/Profile 2/History'
        new.parent.mkdir(parents=True)
        dest = sqlite3.connect(new); con.backup(dest); dest.close()
        self.assertEqual(len(list(readers.browser(context(), state))), 1)

    def test_claude_prompts_summary_tool_outputs_ignored(self):
        p = self.path('.claude/projects/project/one/subagents/agent-123.jsonl')
        rows = [dict(type='user', timestamp=core.iso(NOW), uuid='u1', cwd='/project', sessionId='s1',
                     message={'content': [{'type': 'text', 'text': 'hello ' + '中' * 1000}]}),
                dict(type='assistant', timestamp=core.iso(NOW), message={'model': 'claude-test',
                     'content': [{'type': 'tool_use', 'name': 'Read', 'input': {'secret': 'not kept'}}]}),
                dict(type='user', timestamp=core.iso(NOW), message={'content': [
                    {'type': 'tool_result', 'content': 'TOOL OUTPUT NOT STORED'}]})]
        self.jsonl(p, rows)
        self.assertEqual(self.run_reader('claude')['count'], 2)
        events = self.events('claude')
        prompt, summary = events
        self.assertTrue(prompt['subagent'])
        self.assertLessEqual(len(prompt['text'].encode()), 2048)
        self.assertEqual(summary['turns'], 1)
        self.assertEqual(summary['tool_calls'], {'Read': 1})
        self.assertNotIn('TOOL OUTPUT', json.dumps(events))
        self.assertEqual(self.run_reader('claude')['count'], 0)
        self.jsonl(p, [dict(type='user', timestamp=core.iso(NOW + dt.timedelta(seconds=1)), uuid='u2',
                           message={'content': 'next'})], 'a')
        self.assertEqual(self.run_reader('claude')['count'], 2)
        self.assertEqual(self.events('claude')[-1]['turns'], 2)
        self.assertEqual(self.events('claude')[-1]['tool_calls'], {'Read': 1})

    def test_codex_prompt_mirror_subagent_and_partial_line(self):
        p = self.path('.codex/sessions/2026/11/01/rollout-test.jsonl')
        def item(kind, payload):
            return dict(type=kind, timestamp=core.iso(NOW), payload=payload)
        self.jsonl(p, [item('session_meta', dict(id='codex1', cwd='/project', source={'subagent': 'spawn'})),
                       item('turn_context', dict(model='test-model')),
                       item('event_msg', dict(type='user_message', message='mirror')),
                       item('response_item', dict(type='message', role='user', content=[{'type': 'input_text', 'text': 'real'}])),
                       item('response_item', dict(type='function_call', name='exec_command', arguments='NOT STORED')),
                       item('response_item', dict(type='function_call_output', output='NOT STORED'))])
        self.assertEqual(self.run_reader('codex')['count'], 2)
        events = self.events('codex')
        self.assertEqual(events[0]['text'], 'real')
        self.assertTrue(events[-1]['subagent'])
        self.assertEqual(events[-1]['tool_calls'], {'exec_command': 1})
        self.assertEqual(events[-1]['model'], 'test-model')
        self.assertNotIn('NOT STORED', json.dumps(events))
        line = json.dumps(item('response_item', dict(type='message', role='user', content='next')))
        with p.open('a') as f:
            f.write(line[:20])
        self.assertEqual(self.run_reader('codex')['count'], 0)
        with p.open('a') as f:
            f.write(line[20:] + '\n')
        self.assertEqual(self.run_reader('codex')['count'], 2)
        self.assertEqual(self.run_reader('codex')['count'], 0)

    def test_large_ignored_transcript_blobs_and_partial_retry(self):
        p = self.path('.codex/sessions/blob.jsonl')
        stamp = core.iso(NOW)
        self.jsonl(p, [dict(timestamp=stamp, type='response_item', payload=dict(
            type='function_call_output', output='X' * 1_000_000)),
            dict(timestamp=stamp, type='response_item', payload=dict(
                type='message', role='user', content='kept'))])
        with patch('lifetrace_sources.readers.json.loads', wraps=json.loads) as loads:
            self.assertEqual(self.run_reader('codex')['count'], 2)
        self.assertTrue(all(len(call.args[0]) < 10000 for call in loads.call_args_list))
        self.assertEqual(self.events('codex')[0]['text'], 'kept')
        with p.open('a') as f:
            f.write(json.dumps(dict(timestamp=stamp, type='response_item', payload=dict(
                type='function_call_output', output='X' * 10000))))
        self.assertEqual(self.run_reader('codex')['count'], 0)
        with p.open('a') as f:
            f.write('\n')
        self.assertEqual(self.run_reader('codex')['count'], 1)  # Summary only.

    def test_shell_no_timestamp_extended_multiline_rotation(self):
        p = self.path('.zsh_history')
        p.write_text('echo first\necho first\n: ' + str(int(NOW.timestamp())) + ':2;echo exact\\\nsecond\n')
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(self.run_reader('shell')['count'], 3)
            rows = self.events('shell')
            self.assertEqual(len({r['id'] for r in rows}), 3)
            self.assertTrue(rows[0]['ts_estimated'])
            self.assertEqual(rows[0]['ts'], core.iso(NOW))
            self.assertFalse(rows[2]['ts_estimated'])
            self.assertEqual(rows[2]['duration_s'], 2)
            self.assertEqual(rows[2]['command'], 'echo exact\nsecond')
            self.assertEqual(self.run_reader('shell')['count'], 0)
            with p.open('a') as f:
                f.write('password=hidden\n')
            self.assertEqual(self.run_reader('shell')['count'], 1)
            self.assertNotIn('hidden', json.dumps(self.events('shell')))
            p.write_text('rotated\n')
            self.assertEqual(self.run_reader('shell')['count'], 1)
            p.write_text('changed\n')  # Same size/inode rewrite, tail fingerprint changes.
            self.assertEqual(self.run_reader('shell')['count'], 1)

    def test_shell_mixed_history_then_zsh_rewrite(self):
        # Plain lines from before EXTENDED_HISTORY, then `: epoch:dur;cmd` lines.
        p = self.path('.zsh_history')
        t = int(NOW.timestamp()) - 600
        p.write_text(f'echo old1\necho old2\n: {t}:1;echo new1\n')
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(self.run_reader('shell')['count'], 3)
            rows = self.events('shell')
            self.assertEqual([r['ts_estimated'] for r in rows], [True, True, False])
            self.assertEqual(rows[2]['ts'], core.iso(core.unix(t)))
            self.assertEqual(self.run_reader('shell')['count'], 0)
            with p.open('a') as f:
                f.write(f': {t + 60}:0;echo new2\n')
            self.assertEqual(self.run_reader('shell')['count'], 1)
            self.assertFalse(self.events('shell')[-1]['ts_estimated'])
            # zsh trims/rewrites HISTFILE (new inode): old plain lines become
            # `: <rewrite time>:0;cmd`, the first line is trimmed, one new command follows.
            r = int(NOW.timestamp())
            fresh = self.path('.zsh_history.new')
            fresh.write_text(f': {r}:0;echo old2\n: {t}:1;echo new1\n: {t + 60}:0;echo new2\n'
                             f': {t + 120}:0;echo new3\n')
            os.replace(fresh, p)
            report = self.run_reader('shell')
            self.assertEqual((report['count'], report['duplicates']), (1, 0))
            self.assertEqual(self.events('shell')[-1]['command'], 'echo new3')
            self.assertEqual(len({r['id'] for r in self.events('shell')}), 5)
            self.assertEqual(self.run_reader('shell')['count'], 0)

    def test_shell_trim_without_tail_does_not_replay_plain_or_converted_lines(self):
        p = self.path('.zsh_history')
        epoch = int(NOW.timestamp()) - 60
        p.write_text(f'echo old1\necho old2\necho old3\n: {epoch}:1;echo exact\n')
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(self.run_reader('shell')['count'], 4)
            # Trim destroys the three-record tail; plain positions shift.
            p.write_text(f'echo old2\necho old3\n: {epoch+1}:0;echo new1\n')
            self.assertEqual(self.run_reader('shell')['count'], 1)
            # Conversion also happens when no previous tail survives.
            fresh = self.path('.zsh_history.new')
            fresh.write_text(f': {epoch+30}:0;echo old3\n: {epoch+2}:0;echo new2\n')
            os.replace(fresh, p)
            self.assertEqual(self.run_reader('shell')['count'], 1)
            self.assertEqual([row['command'] for row in self.events('shell')],
                             ['echo old1', 'echo old2', 'echo old3', 'echo exact',
                              'echo new1', 'echo new2'])
            # A genuine timestamped execution of a formerly plain command on append survives.
            with p.open('a') as stream:
                stream.write(f': {epoch+40}:0;echo old3\n')
            self.assertEqual(self.run_reader('shell')['count'], 1)
            # A nonzero-duration replay is not a conversion, even on rewrite.
            p.write_text(f': {epoch+50}:1;echo old3\n')
            self.assertEqual(self.run_reader('shell')['count'], 1)
            self.assertEqual(self.events('shell')[-1]['duration_s'], 1)

    def test_shell_legacy_cursor_seeds_plain_hashes_before_rewrite(self):
        p = self.path('.zsh_history')
        commands = ['echo old-' + str(i) for i in range(20)]
        epoch = int(NOW.timestamp()) - 60
        p.write_text('\n'.join(commands) + f'\n: {epoch}:0;echo exact\n')
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(self.run_reader('shell')['count'], 21)
            state_path = self.data / 'sources/shell/.state.json'
            state = core.load_json(state_path)
            del state['cursors'][core.digest(str(p))]['plain_commands']
            core.atomic_json(state_path, state)
            self.assertEqual(self.run_reader('shell')['count'], 0)
            cursor = core.load_json(state_path)['cursors'][core.digest(str(p))]
            self.assertEqual(set(cursor['plain_commands']), {core.digest(c) for c in commands})
            p.write_text(f'echo old-1\n: {epoch+20}:0;echo old-2\n: {epoch+30}:0;echo new\n')
            self.assertEqual(self.run_reader('shell')['count'], 1)
            self.assertEqual(self.events('shell')[-1]['command'], 'echo new')

    def test_rescrub_dedupes_estimated_shell_commands_across_days(self):
        root = self.data / 'sources/shell'
        def row(identity, command, estimated=True):
            return core.event('shell', 'command', NOW, identity,
                              command=command, ts_estimated=estimated)
        first = [row('a', 'echo repeat'), row('b', 'echo exact', False),
                 row('c', 'echo repeat')]
        second = [row('d', 'echo repeat'), row('e', 'echo exact'),
                  row('f', 'echo repeat', False), row('g', 'echo unique')]
        self.jsonl(root / '2026-11-01.jsonl', first)
        self.jsonl(root / '2026-11-02.jsonl', second)
        self.jsonl(self.data / 'sources/browser/2026-11-01.jsonl', first)
        originals = {p: p.read_bytes() for p in root.glob('*.jsonl')}
        result = cli.rescrub(self.data, True, dedupe_shell_estimated=True)
        self.assertEqual(result, dict(v='act.v1', query='sources.rescrub', dry_run=True,
                                     files=3, records=10, changed=0, removed=2))
        self.assertEqual({p: p.read_bytes() for p in originals}, originals)
        self.assertFalse((root / '.run.lock').exists())
        replace = os.replace
        def fail_shell(source, destination):
            if destination.parent == root:
                raise OSError('synthetic replacement failure')
            replace(source, destination)
        with patch('lifetrace_sources.__main__.os.replace', side_effect=fail_shell):
            with self.assertRaises(OSError):
                cli.rescrub(self.data, dedupe_shell_estimated=True)
        self.assertEqual({p: p.read_bytes() for p in originals}, originals)
        self.assertEqual(list(root.glob('.rescrub-*')), [])
        # Exercise the actual CLI flag and its act.v1 summary as well.
        result = subprocess.run([sys.executable, '-m', 'lifetrace_sources', 'rescrub',
                                 '--data-dir', str(self.data), '--dedupe-shell-estimated'],
                                capture_output=True, timeout=3, check=True)
        self.assertEqual(result.stderr, b'')
        self.assertEqual(json.loads(result.stdout), dict(v='act.v1', query='sources.rescrub',
                         dry_run=False, files=3, records=10, changed=0, removed=2))
        self.assertEqual(self.events('shell'), [first[0], first[1]] + second[1:])
        self.assertEqual(self.events('browser'), first)
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in originals))
        self.assertEqual(cli.rescrub(self.data, dedupe_shell_estimated=True)['removed'], 0)

    def test_git_author_stats_worktree_and_backdated_incremental(self):
        repo = self.path('Projects/repo/.git').parent
        def git(*args, env=None):
            return subprocess.run(['git', '-C', str(repo), *args], check=True, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=env).stdout.decode().strip()
        git('init')
        git('config', 'user.name', 'Test Author')
        git('config', 'user.email', 'test@example.test')
        p = repo / 'example.txt'
        p.write_text('one\ntwo\n')
        git('add', 'example.txt')
        git('commit', '-m', 'first', env=dict(os.environ, GIT_AUTHOR_DATE=core.iso(NOW), GIT_COMMITTER_DATE=core.iso(NOW)))
        wt = self.home / 'Projects/repo-wt'
        git('worktree', 'add', '-b', 'testing', str(wt))
        self.assertEqual(len(readers.repositories(self.home)), 1)
        self.assertEqual(self.run_reader('git')['count'], 1)
        row = self.events('git')[0]
        self.assertEqual(row['insertions'], 2)
        self.assertEqual(row['files_changed'], 1)
        self.assertEqual(len(row['hash']), 40)
        git('update-ref', 'refs/lifetrace-test/retained', row['hash'])
        self.assertEqual(self.run_reader('git')['count'], 0)
        self.assertEqual(self.run_reader('git')['duplicates'], 0)
        p.write_text('one\n')
        git('add', 'example.txt')
        earlier = core.iso(NOW - dt.timedelta(days=30))
        git('commit', '-m', 'backdated', env=dict(os.environ, GIT_AUTHOR_DATE=earlier, GIT_COMMITTER_DATE=earlier))
        self.assertEqual(self.run_reader('git')['count'], 1)
        self.assertEqual(self.events('git')[0]['deletions'], 1)
        with patch.object(readers, 'git_cmd', side_effect=AssertionError('unchanged git spawned')):
            self.assertEqual(self.run_reader('git')['count'], 0)
        with patch.object(readers, 'git_cmd', side_effect=AssertionError('unchanged git spawned')):
            self.assertEqual(self.run_reader('git')['count'], 0)
        original = readers.git_cmd
        injected = False
        def concurrent_commit(repo_path, *args, **kwargs):
            nonlocal injected
            out = original(repo_path, *args, **kwargs)
            if args[0] == 'log' and not injected:
                injected = True
                p.write_text('concurrent\n')
                git('add', 'example.txt')
                git('commit', '-m', 'arrived during log')
            return out
        git('update-ref', 'refs/lifetrace-test/concurrency', row['hash'])
        with patch.object(readers, 'git_cmd', concurrent_commit):
            self.assertEqual(self.run_reader('git')['count'], 0)
        self.assertEqual(self.run_reader('git')['count'], 1)
        git('worktree', 'remove', str(wt))

    def test_media_projects_clocks_and_incremental(self):
        draft = self.path('Movies/JianyingPro/User Data/Projects/com.lveditor.draft/test/draft_content.json')
        draft.write_text('{}')
        meta = draft.parents[1] / 'root_meta_info.json'
        meta.write_text(json.dumps({'all_draft_store': [dict(draft_fold_path=str(draft.parent),
            draft_name='Demo', tm_draft_modified=int(NOW.timestamp() * 1_000_000))]}))
        ae = self.path('Projects/demo.aep')
        ae.write_text('')
        blend = self.path('Projects/demo.blend')
        blend.write_text('')
        final = self.home / 'Movies/demo.fcpbundle'
        final.mkdir()
        for p in (ae, blend, final):
            os.utime(p, (NOW.timestamp(), NOW.timestamp()))
        prefs = self.path('Library/Preferences/Adobe/After Effects/26.5/Adobe After Effects Prefs.txt')
        prefs.write_text('"MRU" = "' + str(ae) + '"\n')
        recent = self.path('Library/Application Support/Blender/4.5/config/recent-files.txt')
        recent.write_text(str(blend) + '\n')
        self.assertEqual(self.run_reader('media_projects')['count'], 4)
        self.assertEqual({r['app'] for r in self.events('media_projects')}, {'JianyingPro', 'After Effects', 'Blender', 'Final Cut'})
        self.assertEqual(self.run_reader('media_projects')['count'], 0)
        root_mtime = (self.home / 'Movies').stat().st_mtime_ns
        os.utime(blend, (NOW.timestamp() + 1, NOW.timestamp() + 1))
        self.assertEqual(self.run_reader('media_projects')['count'], 1)
        self.assertEqual((self.home / 'Movies').stat().st_mtime_ns, root_mtime)
        meta.write_text(json.dumps({'all_draft_store': [dict(draft_fold_path=str(draft.parent),
            draft_name='Demo', tm_draft_modified=int((NOW.timestamp() + 2) * 1_000_000))]}))
        self.assertEqual(self.run_reader('media_projects')['count'], 1)
        nested = self.path('Movies/JianyingPro/new/deep/project/draft_meta_info.json')
        nested.write_text('{}')
        self.assertEqual(self.run_reader('media_projects')['count'], 1)

    def test_calendar_apple_dates_edit_revision_and_permissions(self):
        p = self.path('Library/Calendars/Calendar Cache')
        con = self.db(p, 'CREATE TABLE CalendarItem(uuid TEXT,summary TEXT,location TEXT,start_date REAL,end_date REAL,last_modified REAL);')
        stamp = (NOW - core.APPLE).total_seconds()
        con.execute('INSERT INTO CalendarItem VALUES(?,?,?,?,?,?)', ('uid1', 'private title', '', stamp, stamp+3600, stamp))
        con.commit()
        self.addCleanup(con.close)
        self.assertEqual(self.run_reader('calendar')['count'], 1)
        row = self.events('calendar')[0]
        self.assertEqual(row['ts'], core.iso(NOW))
        self.assertEqual(row['start'], core.iso(NOW))
        self.assertEqual(self.run_reader('calendar')['count'], 0)
        con.execute("UPDATE CalendarItem SET summary='edited'")
        con.commit()
        self.assertEqual(self.run_reader('calendar')['count'], 1)
        with patch('lifetrace_sources.readers.snapshot', side_effect=PermissionError):
            self.assertEqual(self.run_reader('calendar')['status'], 'unavailable')

    def test_install_template_without_loading(self):
        target, log = self.root / 'LaunchAgents', self.root / 'logs/sources.log'
        env = dict(os.environ, HOME=str(self.home), AGENT_RUN=str(self.home / 'missing-agent-run'))
        # Explicit label: a maintainer's untracked config.mk may override the default.
        subprocess.run(['make', 'install-sources', f'LAUNCH_AGENTS={target}', f'SOURCES_LOG={log}',
                        'SOURCES_LABEL=test.lifetrace.sources'], check=True, stdout=subprocess.PIPE, env=env)
        plist = plistlib.loads((target / 'test.lifetrace.sources.plist').read_bytes())
        self.assertEqual(plist['Label'], 'test.lifetrace.sources')
        self.assertNotIn('@', json.dumps(plist, default=str))
        subprocess.run([sys.executable, '-m', 'lifetrace_sources.install', '--launch-agents', str(target),
                        '--log', str(log)], check=True, stdout=subprocess.PIPE, env=env)
        self.assertEqual(plistlib.loads((target / 'dev.lifetrace.sources.plist').read_bytes())['Label'],
                         'dev.lifetrace.sources')
        self.assertEqual(plist['StartInterval'], 900)
        self.assertEqual(plist['Nice'], 10)
        self.assertTrue(plist['LowPriorityIO'])
        self.assertEqual(plist['ProgramArguments'][1:], ['-m', 'lifetrace_sources', 'run'])
        self.assertNotIn('KeepAlive', plist)

    def test_install_optional_agent_run(self):
        target, log = self.root / 'LaunchAgents', self.root / 'logs/sources.log'
        env = dict(os.environ, HOME=str(self.home))
        env.pop('AGENT_RUN', None)

        def render():
            subprocess.run([sys.executable, '-m', 'lifetrace_sources.install', '--launch-agents', str(target),
                            '--log', str(log)], check=True, stdout=subprocess.PIPE, env=env)
            return plistlib.loads((target / 'dev.lifetrace.sources.plist').read_bytes())

        original = render()
        self.assertEqual(original['ProgramArguments'][1:], ['-m', 'lifetrace_sources', 'run'])
        for name, override in (('.local/bin/agent-run', None), ('custom & <runner>', '~/custom & <runner>')):
            launcher = self.path(name)
            if override:
                env['AGENT_RUN'] = override
            for mode in (None, 0o644, 0o755):
                with self.subTest(name=name, mode=mode):
                    if mode is not None:
                        launcher.write_text('#!/bin/sh\nexit 0\n')
                        launcher.chmod(mode)
                    expected = dict(original, ProgramArguments=([str(launcher)] if mode == 0o755 else [])
                                    + original['ProgramArguments'])
                    self.assertEqual(render(), expected)

    def test_utc_offset_config_env_and_machine_default(self):
        self.assertEqual(core.parse_offset('+08:00'), dt.timedelta(hours=8))
        self.assertEqual(core.parse_offset('-05:30'), -dt.timedelta(hours=5, minutes=30))
        self.assertEqual(core.parse_offset('Z'), dt.timedelta(0))
        for bad in ('8', '+8:00', '+25:00', None, 'Asia/Shanghai'):
            self.assertIsNone(core.parse_offset(bad))
        with patch.dict(os.environ, {'LIFETRACE_UTC_OFFSET': ''}):
            self.assertEqual(core.local_zone({'utc_offset': '-05:00'}).utcoffset(None), -dt.timedelta(hours=5))
            machine = dt.datetime.now().astimezone().utcoffset()
            self.assertEqual(core.local_zone({'utc_offset': 'bogus'}).utcoffset(None), machine)
        with patch.dict(os.environ, {'LIFETRACE_UTC_OFFSET': '+01:00'}):
            self.assertEqual(core.local_zone({'utc_offset': '-05:00'}).utcoffset(None), dt.timedelta(hours=1))

    def test_verified_media_path_keeps_structural_hashes_only(self):
        md5 = '0123456789abcdef' * 2
        path = f'/cache/{md5}/{md5}_t.dat'
        row = core.event('example', 'item', NOW, 'm', media_path=core.VerifiedMediaPath(path), text=path)
        self.assertEqual(row['media_path'], path)
        self.assertNotIn(md5, row['text'])
        self.assertNotIn(md5, core.event('example', 'item', NOW, 'r', media_path=path)['media_path'])
        secret = core.VerifiedMediaPath(f'/cache/{md5}/token=abcDEF1234567890.txt')
        self.assertNotIn('abcDEF1234567890', core.event('example', 'item', NOW, 's', media_path=secret)['media_path'])

    def test_git_roots_config_and_extra_authors(self):
        repo = self.path('elsewhere/repo/.git').parent
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        self.assertEqual(readers.repositories(self.home), [])
        self.assertEqual(readers.repositories(self.home, {'git_roots': ['~/elsewhere']}), [repo.resolve()])
        self.assertEqual(readers.repositories(self.home, {'git_roots': [str(repo)]}), [repo.resolve()])

    def test_extra_readers_load_run_and_report_failures(self):
        plugin = self.root / 'plugins/example_reader.py'
        plugin.parent.mkdir()
        plugin.write_text('''from lifetrace_sources.core import event
def notes(ctx, state):
    state['seen'] = state.get('seen', 0) + 1
    yield event('notes', 'note', ctx.now, ['n', state['seen']], title='hello token=abcDEF1234567890')
READERS = {'notes': notes}
''')
        broken = self.root / 'plugins/broken.py'
        broken.write_text('raise RuntimeError("boom")\n')
        clash = self.root / 'plugins/clash.py'
        clash.write_text('READERS = {"git": lambda ctx, state: iter(())}\n')
        loaded, failed = cli.load_extra_readers({'extra_readers': [str(plugin), str(broken), str(clash),
                                                                      str(self.root / 'missing.py')]})
        self.assertEqual(list(loaded), ['notes'])
        self.assertEqual({f['source'] for f in failed}, {'broken', 'clash', 'missing'})
        self.assertTrue(all(f['status'] == 'unavailable' for f in failed))
        with patch.dict(cli.READERS, loaded):
            self.assertEqual(self.run_reader('notes')['count'], 1)
            self.assertEqual(self.run_reader('notes')['count'], 1)
            rows = self.events('notes')
            self.assertEqual(rows[0]['type'], 'source.notes.note')
            self.assertNotIn('abcDEF1234567890', json.dumps(rows))
            self.assertIn('notes', [r['source'] for r in status(self.data, home=self.home)['sources']])


if __name__ == '__main__':
    unittest.main()
