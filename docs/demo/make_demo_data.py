"""Write a synthetic lifetrace data dir (one fake workday) for demos and screenshots.

Usage: python3 docs/demo/make_demo_data.py OUT_DIR
Then:  LIFETRACE_HOME=OUT_DIR LIFETRACE_CONFIG=/dev/null LIFETRACE_UTC_OFFSET=+00:00 lifetrace reindex
Every app, title, URL and text below is invented.
"""
import datetime as dt
import json
from pathlib import Path
import random
import sys

DAY = dt.datetime(2026, 10, 28, tzinfo=dt.timezone.utc)
random.seed(7)

# Consecutive blocks from 08:58: (minutes, app, bundle, title, url, keys/min, scrolls/min); ('away', minutes).
PLAN = [
    (4, 'Mail', 'com.apple.mail', 'Inbox — 12 unread', None, 6, 8),
    (52, 'Visual Studio Code', 'com.microsoft.VSCode', 'parser.rs — demo-project', None, 70, 4),
    (1.5, 'Slack', 'com.tinyspeck.slackmacgap', '#design-review', None, 30, 5),
    (38, 'Visual Studio Code', 'com.microsoft.VSCode', 'parser_test.rs — demo-project', None, 64, 3),
    (18, 'Safari', 'com.apple.Safari', 'Rust By Example — Iterators', 'https://doc.rust-lang.org/rust-by-example/trait/iter.html', 3, 40),
    (2, 'Messages', 'com.apple.MobileSMS', 'Messages', None, 20, 2),
    (82, 'Terminal', 'com.apple.Terminal', 'cargo test — demo-project', None, 55, 6),
    ('away', 45),
    (26, 'Safari', 'com.apple.Safari', 'Hacker News', 'https://news.ycombinator.com/', 2, 55),
    (41, 'Zoom', 'us.zoom.xos', 'Weekly sync', None, 4, 1),
    (64, 'Figma', 'com.figma.Desktop', 'Onboarding flow v3', None, 12, 18),
    (1.8, 'Slack', 'com.tinyspeck.slackmacgap', '#design-review', None, 35, 6),
    (20, 'Figma', 'com.figma.Desktop', 'Onboarding flow v3', None, 12, 18),
    (33, 'Pages', 'com.apple.iWork.Pages', 'Q4 invoice summary.pages', None, 48, 9),
    (21, 'Safari', 'com.apple.Safari', 'Invoice template ideas — Example Blog', 'https://blog.example.com/invoice-templates', 1, 45),
    (58, 'Visual Studio Code', 'com.microsoft.VSCode', 'lexer.rs — demo-project', None, 72, 5),
    ('away', 10),
]
TEXT = {
    'Pages': 'Q4 invoice summary\nClient: Example Corp\nTotal due: 4,200 USD\nPayment terms: net 30',
    'Safari': 'Iterators — the Iterator trait has one required method, next, returning Option<Item>.',
    'Figma': 'Onboarding flow v3 — Welcome / Connect your calendar / Done',
}


def iso(t):
    return t.isoformat(timespec='milliseconds')


def at(hm):
    h, m = map(int, hm.split(':'))
    return DAY + dt.timedelta(hours=h, minutes=m)


def main(out):
    out = Path(out)
    (out / 'events').mkdir(parents=True, exist_ok=True)
    rows = [dict(v='act.v1', ts=iso(at('08:58')), type='recorder.start', pid=4242, version='0.3.0',
                 ax=True, ax_trusted=True, input=True)]
    t = at('08:58')
    for i, item in enumerate(PLAN):
        if item[0] == 'away':
            rows.append(dict(v='act.v1', ts=iso(t), type='presence.lock'))
            t += dt.timedelta(minutes=item[1])
            rows.append(dict(v='act.v1', ts=iso(t), type='presence.unlock'))
            continue
        minutes, app, bundle, title, url, kpm, spm = item
        a, b = t, t + dt.timedelta(minutes=minutes)
        t = b
        seg = 's' + format(int(a.timestamp() * 1000), 'x')
        ctx = dict(app=app, bundle=bundle, pid=1000 + i, win=10 + i, title=title, seg=seg)
        if url:
            ctx.update(url=url, host=url.split('/')[2].removeprefix('www.'))
        rows.append(dict(v='act.v1', ts=iso(a), type='focus.app', reason='activate', **ctx))
        if app in TEXT:
            text = TEXT[app]
            rows.append(dict(v='act.v1', ts=iso(a + dt.timedelta(seconds=3)), type='content.snapshot', seg=seg,
                             app=app, bundle=bundle, hash=format(abs(hash(text)) % (1 << 63), '016x'),
                             text=text, chars=len(text), why='stable'))
        idle = random.choice([0, 0, 60, 120, 240]) if minutes > 10 else 0
        dur = round(minutes * 60)
        rows.append(dict(v='act.v1', ts=iso(b), type='segment.end', start=iso(a), end=iso(b), dur_s=dur,
                         idle_s=idle, active_s=dur - idle, glance=False, reason='switch', titles=1,
                         keys=round(kpm * minutes), clicks=round(minutes * 3), scrolls=round(spm * minutes),
                         scroll_px=round(spm * minutes * 40), copies=int(minutes // 10), pastes=int(minutes // 12), **ctx))
    rows.append(dict(v='act.v1', ts=iso(t), type='recorder.stop', reason='signal'))
    rows.sort(key=lambda r: r['ts'])
    with (out / 'events' / (DAY.date().isoformat() + '.jsonl')).open('w') as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False, separators=(',', ':')) + '\n')
    src = out / 'sources' / 'browser'
    src.mkdir(parents=True, exist_ok=True)
    with (src / (DAY.date().isoformat() + '.jsonl')).open('w') as f:
        for n, (hm, url, title) in enumerate([
                ('10:34', 'https://doc.rust-lang.org/rust-by-example/trait/iter.html', 'Rust By Example — Iterators'),
                ('16:07', 'https://blog.example.com/invoice-templates', 'Invoice template ideas — Example Blog')]):
            f.write(json.dumps(dict(v='act.v1', ts=iso(at(hm)), type='source.browser.visit', source='browser',
                                    id=f'demo-{n}', url=url, title=title, browser='Safari', profile='Default')) + '\n')


if __name__ == '__main__':
    main(sys.argv[1])
