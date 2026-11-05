"""Owner-confirmed deletion for exact, indexed Movie Night files only.

NEVER called by a read, a server restart, a queued job or a catalog refresh.
A short-lived owner challenge plus the web app's existing Origin/CSRF boundary
are required before any filesystem mutation. Tests use disposable media files.
"""
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import threading
import time

import worker_candidate as worker


ID = re.compile(r"tt[0-9]{5,12}\Z")
FILE = re.compile(r"tt[0-9]{5,12}\.[0-9]{4}\.(?:mkv|mp4)\Z")
LIFETIME_SECONDS = 120


class RemovalUnavailable(ValueError):
    """The indexed target changed or is not safe to remove."""


class ServerFileDeletion:
    def __init__(self, index, jobs_db, clock=time.time):
        self.index = index
        self.jobs_db = Path(jobs_db)
        self.clock = clock
        self.lock = threading.RLock()
        self.challenges = {}
        # An additive, private tombstone table prevents an old job from
        # automatically re-publishing a file intentionally deleted by the owner.
        with sqlite3.connect(index.db) as db:
            db.execute("""CREATE TABLE IF NOT EXISTS removed_media(
                id TEXT PRIMARY KEY, name TEXT NOT NULL,
                size INTEGER NOT NULL, removed_epoch INTEGER NOT NULL)""")

    def removed_ids(self):
        with sqlite3.connect(f"file:{self.index.db}?mode=ro", uri=True) as db:
            return {row[0] for row in db.execute("SELECT id FROM removed_media")}

    def _active(self, imdb):
        if not self.jobs_db.is_file():
            raise RemovalUnavailable("Transfer state unavailable; no movie was deleted.")
        with sqlite3.connect(f"file:{self.jobs_db}?mode=ro", uri=True) as db:
            for raw, in db.execute(
                "SELECT payload FROM jobs WHERE state IN ('approved','downloading')"
            ):
                try:
                    item = json.loads(raw)
                    value = item["choice"]["imdb"]
                except (ValueError, TypeError, KeyError):
                    raise RemovalUnavailable("Transfer state unavailable; no movie was deleted.")
                if value == imdb:
                    raise RemovalUnavailable("A transfer is active; no movie was deleted.")
            table = db.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='movie_download_queue'"
            ).fetchone()
            if table and db.execute(
                "SELECT 1 FROM movie_download_queue WHERE imdb=? "
                "AND state IN ('queued','checking') LIMIT 1", (imdb,)
            ).fetchone():
                raise RemovalUnavailable("A transfer is active; no movie was deleted.")

    def _snapshot(self, imdb):
        if not isinstance(imdb, str) or not ID.fullmatch(imdb):
            raise RemovalUnavailable("Invalid movie ID.")
        if self.index.storage_guard:
            self.index.storage_guard()
        movies = worker.safe_directory(self.index.root / "Movies")
        with sqlite3.connect(f"file:{self.index.db}?mode=ro", uri=True) as db:
            row = db.execute(
                "SELECT filename,size,sha,metadata FROM media WHERE id=? AND visible=1",
                (imdb,),
            ).fetchone()
        if not row:
            raise RemovalUnavailable("Server file no longer available. Refresh Movie Night.")
        filename, size, digest, metadata = row
        if (not isinstance(filename, str) or not FILE.fullmatch(filename)
                or not filename.startswith(imdb + ".")
                or type(size) is not int or size <= 0
                or not isinstance(digest, str) or not re.fullmatch("[a-f0-9]{64}", digest)):
            raise RemovalUnavailable("Server file identity changed; no movie was deleted.")
        path = movies / filename
        if path.is_symlink():
            raise RemovalUnavailable("Server file identity changed; no movie was deleted.")
        try:
            st = path.stat(follow_symlinks=False)
        except OSError:
            raise RemovalUnavailable("Server file no longer available. Refresh Movie Night.")
        if not stat.S_ISREG(st.st_mode) or st.st_size != size:
            raise RemovalUnavailable("Server file identity changed; no movie was deleted.")
        try:
            info = json.loads(metadata)
            title = info["title"]
        except (ValueError, TypeError, KeyError):
            raise RemovalUnavailable("Server metadata unavailable; no movie was deleted.")
        if not isinstance(title, str) or not 1 <= len(title) <= 200:
            raise RemovalUnavailable("Server metadata unavailable; no movie was deleted.")
        identity = (filename, size, digest, st.st_dev, st.st_ino, st.st_mtime_ns)
        return movies, title, identity

    def preview(self, principal, imdb):
        if not isinstance(principal, str) or not principal:
            raise RemovalUnavailable("Owner session unavailable.")
        with self.lock:
            self._active(imdb)
            movies, title, identity = self._snapshot(imdb)
            token = secrets.token_urlsafe(32)
            self.challenges[(principal, imdb)] = (
                token, float(self.clock()) + LIFETIME_SECONDS, identity
            )
            return {
                "imdb": imdb, "title": title, "sizeBytes": identity[1],
                "confirmationToken": token, "expiresInSeconds": LIFETIME_SECONDS,
                "requiresExplicitConfirmation": True,
            }

    def delete(self, principal, imdb, token, title_confirmation):
        with self.lock:
            challenge = self.challenges.pop((principal, imdb), None)
            if (not challenge or not isinstance(token, str)
                    or not secrets.compare_digest(challenge[0], token)
                    or float(self.clock()) > challenge[1]):
                raise RemovalUnavailable("Confirmation expired. Review the movie again.")
            self._active(imdb)
            movies, title, actual = self._snapshot(imdb)
            if actual != challenge[2] or title_confirmation != title:
                raise RemovalUnavailable("Server file changed. Review the movie again.")
            filename = actual[0]
            fd = os.open(movies, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                st = os.stat(filename, dir_fd=fd, follow_symlinks=False)
                if not stat.S_ISREG(st.st_mode) or (
                    st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns
                ) != (actual[3], actual[4], actual[1], actual[5]):
                    raise RemovalUnavailable("Server file changed. Review the movie again.")
                with sqlite3.connect(self.index.db) as db:
                    db.execute("BEGIN IMMEDIATE")
                    record = db.execute(
                        "SELECT filename,size,sha,visible FROM media WHERE id=?", (imdb,)
                    ).fetchone()
                    if record != (actual[0], actual[1], actual[2], 1):
                        raise RemovalUnavailable("Server index changed. Review the movie again.")
                    # The only unlink in this feature: exact basename under a
                    # verified directory descriptor after a named confirmation.
                    os.unlink(filename, dir_fd=fd)
                    db.execute("DELETE FROM media WHERE id=?", (imdb,))
                    db.execute(
                        "INSERT OR REPLACE INTO removed_media VALUES (?,?,?,?)",
                        (imdb, title, actual[1], int(self.clock())),
                    )
                return {"deleted": True, "imdb": imdb, "title": title,
                        "freedBytes": actual[1], "serverCopyRemoved": True}
            finally:
                os.close(fd)
