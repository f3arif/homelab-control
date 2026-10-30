"""Bounded external subtitle prewarming; no service/account/movie mutations.

Run explicitly or from an approved external scheduler. Read-only SQLite;
requires the existing volume guard; cross-process flock; counts-only output.
"""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import sys
import time

from server_subtitles import SubtitleCache, SubtitleUnavailable, IMDB, _directory


class ReadOnlySubtitleIndex:
    def __init__(self, db, root, *, storage_guard):
        self.db, self.root = Path(db), Path(root)
        self.storage_guard = storage_guard
        if not callable(storage_guard):
            raise ValueError('Existing volume validation is required')
        for p in (self.db.parent, self.root, self.root/'Movies'):
            _directory(p)
        info = self.db.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('Existing private owned index required')
        self.storage_guard()

    @contextmanager
    def connect(self):
        # mode=ro never creates/repairs or modifies the production database.
        db = sqlite3.connect(self.db.absolute().as_uri() + '?mode=ro', uri=True, timeout=2)
        try:
            db.execute('PRAGMA query_only=ON')
            yield db
        finally:
            db.close()

    def ids(self):
        self.storage_guard()
        with self.connect() as db:
            rows = db.execute('SELECT id FROM media WHERE visible=1 ORDER BY rowid DESC LIMIT 501').fetchall()
        if len(rows) > 500:
            raise ValueError('Inventory exceeds subtitle pass budget')
        return [r[0] for r in rows if isinstance(r[0], str) and IMDB.fullmatch(r[0])]

    def require_not_removed(self, imdb):
        with self.connect() as db:
            exists = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='removed_media'").fetchone()
            if exists and db.execute('SELECT 1 FROM removed_media WHERE id=?', (imdb,)).fetchone():
                raise SubtitleUnavailable('Movie was removed')

    def resolve(self, imdb):
        self.storage_guard()
        self.require_not_removed(imdb)
        with self.connect() as db:
            row = db.execute('SELECT filename,size,visible FROM media WHERE id=?', (imdb,)).fetchone()
        if not row or not row[2] or not isinstance(row[0], str) or not re.fullmatch(re.escape(imdb)+r'\.[0-9]{4}\.(?:mkv|mp4)', row[0]):
            return None
        p = self.root/'Movies'/row[0]
        info = p.lstat()
        return p if stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size == row[1] else None


def transfers_idle(database):
    """Unknown/busy state postpones work, never competes with active transfers."""
    try:
        p = Path(database)
        info = p.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            return False
        with sqlite3.connect(p.absolute().as_uri() + '?mode=ro', uri=True, timeout=2) as db:
            active = db.execute("SELECT 1 FROM jobs WHERE state IN ('approved','downloading','checking','validating','downloaded') LIMIT 1").fetchone()
        return active is None
    except (OSError, sqlite3.Error):
        return False


def prewarm_once(cache, *, idle, languages=frozenset({'eng'}), max_movies=2,
                 max_tracks=4, seconds=180, clock=time.monotonic):
    if type(max_movies) is not int or not 1 <= max_movies <= 10 or not 1 <= seconds <= 900:
        raise ValueError('Bounded prewarm policy required')
    deadline = clock() + seconds
    result = {'prepared': 0, 'alreadyReady': 0, 'failed': 0, 'postponed': 0, 'busy': False}
    lock = os.open(cache.directory/'worker.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(lock)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('Unsafe subtitle worker lock')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            result['busy'] = True
            return result
        attempts = 0
        for imdb in cache.index.ids():
            if not idle() or clock() >= deadline:
                result['postponed'] += 1
                break
            try:
                if cache.prepared(imdb, languages=languages, max_tracks=max_tracks):
                    result['alreadyReady'] += 1
                    continue
                if attempts >= max_movies:
                    result['postponed'] += 1
                    break
                attempts += 1
                cache.prepare(imdb, languages=languages, max_tracks=max_tracks,
                              budget_seconds=max(.01, deadline-clock()))
                result['prepared'] += 1
            except (ValueError, OSError, sqlite3.Error):
                result['failed'] += 1
        return result
    finally:
        os.close(lock)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--state', required=True)
    parser.add_argument('--cache', required=True)
    parser.add_argument('--languages', default='eng')
    parser.add_argument('--max-movies', type=int, default=2)
    options = parser.parse_args(argv)
    languages = frozenset(options.languages.split(','))
    if not languages or any(not re.fullmatch('[a-z]{3}', lang) for lang in languages):
        parser.error('Use comma-separated ISO-639-2 language codes')
    from storage_volume import MediaVolume
    volume = MediaVolume()  # Never create a missing mount or use root-disk fallback.
    state = _directory(Path(options.state), private=True)
    index = ReadOnlySubtitleIndex(state/'download-index.sqlite3', volume.root, storage_guard=volume.check)
    runtime = Path(sys.executable).absolute().parent
    cache = SubtitleCache(index, options.cache, ffmpeg=runtime/'ffmpeg', ffprobe=runtime/'ffprobe')
    result = prewarm_once(cache, idle=lambda: transfers_idle(state/'preferences.sqlite3'),
                          languages=languages, max_movies=options.max_movies)
    print(json.dumps(result), flush=True)  # No titles, credentials or caption text.


if __name__ == '__main__':
    main()
