"""Exact 8 TB volume checks. Never create a fallback folder on the system disk."""
import json
from pathlib import Path
import shutil
import subprocess

MOUNT = Path('/srv/afzmedia')
MEDIA_ROOT = MOUNT / 'Media/MovieNight'
VOLUME_UUID = 'A29E635A9E63264F'


def mounted_filesystem(path):
    result = subprocess.run(['findmnt', '-J', '-T', str(path), '-o',
                             'TARGET,SOURCE,FSTYPE,UUID,OPTIONS'],
                            capture_output=True, check=True, timeout=5)
    return json.loads(result.stdout)['filesystems'][0]


class MediaVolume:
    def __init__(self, root=MEDIA_ROOT, mount=MOUNT, uuid=VOLUME_UUID,
                 inspect=mounted_filesystem, usage=shutil.disk_usage):
        self.root, self.mount, self.uuid = Path(root), Path(mount), uuid
        self.inspect, self.usage = inspect, usage

    def check(self):
        try:
            if self.root == self.mount or not self.root.is_relative_to(self.mount):
                raise ValueError()
            for path in (self.root, *self.root.parents):
                if path.is_symlink(): raise ValueError()
            row = self.inspect(self.mount)
            if (Path(row['target']) != self.mount or row.get('uuid') != self.uuid
                    or row.get('fstype') != 'ntfs3'
                    or 'rw' not in row.get('options', '').split(',')):
                raise ValueError()
            usage = self.usage(self.mount)
            if usage.total < 7_000_000_000_000: raise ValueError()
            return usage.free
        except Exception:
            raise ValueError('8 TB drive unavailable; downloads paused.') from None

    def ensure(self):
        self.check()
        from worker_candidate import safe_directory
        safe_directory(self.root / 'Movies', create=True)
        self.check()
        return self.root

