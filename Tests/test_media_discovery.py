"""Synthetic failure isolation for cached media-project discovery."""
import datetime as dt
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

os.environ['LIFETRACE_CONFIG'] = os.devnull
os.environ['LIFETRACE_UTC_OFFSET'] = '+08:00'

from lifetrace_sources import core, readers


class MediaDiscoveryTests(unittest.TestCase):
    def test_denied_final_cut_directory_preserves_other_projects(self):
        with tempfile.TemporaryDirectory(prefix='lifetrace-media-test-') as temporary:
            home = Path(temporary)
            denied = home / 'Movies/Denied'
            denied.mkdir(parents=True)
            library = home / 'Movies/Readable/Example.fcpbundle'
            library.mkdir(parents=True)
            project = home / 'Projects/Example.blend'
            project.parent.mkdir()
            project.touch()
            recent = home / 'Library/Application Support/Blender/1/config/recent-files.txt'
            recent.parent.mkdir(parents=True)
            recent.write_text(str(project) + '\n')
            now = core.unix(project.stat().st_mtime)

            # Fail each per-directory filesystem operation, not real permissions/TCC.
            for operation in ('scandir', 'exists', 'file_stamp'):
                with self.subTest(operation=operation):
                    if operation == 'scandir':
                        original = os.scandir
                        target = 'lifetrace_sources.readers.os.scandir'
                    elif operation == 'exists':
                        original = Path.exists
                        target = 'pathlib.Path.exists'
                    else:
                        original = readers.file_stamp
                        target = 'lifetrace_sources.readers.file_stamp'

                    def checked(path, *args, **kwargs):
                        if Path(path) == denied:
                            raise PermissionError('synthetic denial')
                        return original(path, *args, **kwargs)

                    ctx = readers.Context(home, now - dt.timedelta(days=1), now)
                    with patch(target, checked):
                        rows = list(readers.media_projects(ctx, {}))
                    self.assertEqual({(row['app'], row['project_name']) for row in rows}, {
                        ('Blender', 'Example'), ('Final Cut', 'Example')})
                    self.assertEqual(ctx.issues, [
                        {'target': 'Final Cut', 'reason': 'PermissionError'}])


if __name__ == '__main__':
    unittest.main()
