"""Authenticated, same-origin JPEG/WebP thumbnails; fixed provider, bounded cache."""
import os
from pathlib import Path
import re
import stat
import tempfile
import threading
import time
import weakref

MAX_BYTES = 262144
ID = re.compile(r'tt[0-9]{5,12}\Z')


def valid_jpeg(data):
    return isinstance(data, bytes) and 16 <= len(data) <= MAX_BYTES and data.startswith(b'\xff\xd8\xff') and data.endswith(b'\xff\xd9')


def image_mime(data):
    if valid_jpeg(data):
        return 'image/jpeg'
    if (isinstance(data, bytes) and 20 <= len(data) <= MAX_BYTES and
            data[:4] == b'RIFF' and data[8:12] == b'WEBP' and
            int.from_bytes(data[4:8], 'little') == len(data) - 8 and
            data[12:16] in (b'VP8 ', b'VP8L', b'VP8X')):
        return 'image/webp'
    return None


class PosterCache:
    def __init__(self, directory, fetcher=None):
        self.directory = Path(directory)
        self.fetcher = fetcher or self._fetch
        self.guard = threading.Lock()
        self.locks = weakref.WeakValueDictionary()

    def _read(self, path):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > MAX_BYTES:
                    return None
                data = stream.read(MAX_BYTES + 1)
            return data if image_mime(data) else None
        except OSError:
            return None

    def _fetch(self, imdb, remaining):
        import requests
        deadline = time.monotonic() + remaining
        with requests.get('https://images.metahub.space/poster/small/' + imdb + '/img',
                          headers={'Accept': 'image/jpeg, image/webp'}, stream=True, allow_redirects=False,
                          timeout=(min(1, remaining), min(1.5, remaining))) as response:
            mime = response.headers.get('Content-Type', '').split(';')[0]
            if response.status_code != 200 or mime not in ('image/jpeg', 'image/webp'):
                return None
            if int(response.headers.get('Content-Length', '0')) > MAX_BYTES:
                return None
            chunks, size = [], 0
            for chunk in response.iter_content(16384):
                size += len(chunk)
                if size > MAX_BYTES or time.monotonic() > deadline:
                    return None
                chunks.append(chunk)
            data = b''.join(chunks)
            return data if image_mime(data) == mime else None

    def get(self, imdb):
        if not isinstance(imdb, str) or not ID.fullmatch(imdb):
            return None
        path = self.directory / (imdb + '.img')
        if path.is_symlink():
            return None
        cached = self._read(path)
        if cached is not None:
            return cached
        deadline = time.monotonic() + 3
        with self.guard:
            lock = self.locks.get(imdb)
            if lock is None:
                lock = threading.Lock()
                self.locks[imdb] = lock
        if not lock.acquire(timeout=2):
            return None
        try:
            cached = self._read(path)
            if cached is not None:
                return cached
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            data = self.fetcher(imdb, remaining)
            if not image_mime(data):
                return None
            self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            info = self.directory.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                return None
            fd, name = tempfile.mkstemp(prefix='.' + imdb + '-', dir=self.directory)
            try:
                with os.fdopen(fd, 'wb') as stream:
                    os.fchmod(stream.fileno(), 0o600)
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(name, path)
            finally:
                if os.path.exists(name):
                    os.unlink(name)
            return data
        except Exception:
            return None
        finally:
            lock.release()
