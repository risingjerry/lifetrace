"""Render the sources LaunchAgent plist only; NEVER bootstrap/load it."""
import argparse
from pathlib import Path
import plistlib
import sys
import shutil
from xml.sax.saxutils import escape


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--launch-agents', type=Path, required=True)
    p.add_argument('--log', type=Path, required=True)
    p.add_argument('--label', default='dev.lifetrace.sources')
    args = p.parse_args()
    repo = Path(__file__).resolve().parent.parent
    text = (repo / 'launchd/sources.plist.in').read_text()
    values = {'PYTHON': shutil.which('python3') or sys.executable, 'REPO': str(repo), 'LOG': str(args.log),
              'LABEL': args.label, 'PATH': f'{Path.home()}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'}
    for key, value in values.items():
        text = text.replace('@' + key + '@', escape(value))
    plistlib.loads(text.encode())  # Validate before writing.
    args.launch_agents.mkdir(parents=True, exist_ok=True)
    args.log.parent.mkdir(parents=True, exist_ok=True)
    path = args.launch_agents / (args.label + '.plist')
    path.write_text(text)
    print(f'Written {path}; NOT loaded. Uses this checkout: {repo}')


if __name__ == '__main__':
    main()
