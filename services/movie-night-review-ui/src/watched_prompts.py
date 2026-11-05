"""Watched → confirm-deletion prompts. Records only; it NEVER deletes anything.

AFZ Nuvio reports owner-profile watch progress for a Movie Night server movie.
At WATCHED_PERCENT or an explicit "watched" mark the title becomes a prompt,
shown only while the file is still ready on the server and not already removed.
Keep dismisses it for good; Confirm goes through the separate R55 two-step
delete (preview + exact-title confirmation), never through this module.
"""
from contextlib import closing
import re
import sqlite3

WATCHED_PERCENT = 90
ID = re.compile(r'tt[0-9]{5,12}\Z')


class WatchedPrompts:
    def __init__(self, db, clock):
        self.db = db
        self.clock = clock
        with closing(sqlite3.connect(self.db)) as c, c:
            c.execute('''CREATE TABLE IF NOT EXISTS movie_watched_prompts(
                principal TEXT NOT NULL, imdb TEXT NOT NULL, progress INTEGER NOT NULL,
                source TEXT NOT NULL, reported INTEGER NOT NULL, dismissed INTEGER,
                PRIMARY KEY(principal, imdb))''')

    @staticmethod
    def _imdb(value):
        value = str(value or '').strip()
        if not ID.match(value):
            raise ValueError('Invalid movie ID.')
        return value

    def report(self, principal, imdb, progress, watched=False):
        imdb = self._imdb(imdb)
        if isinstance(progress, bool) or not isinstance(progress, (int, float)) or not 0 <= progress <= 100:
            raise ValueError('Invalid watch progress.')
        if not isinstance(watched, bool):
            raise ValueError('Invalid watch progress.')
        progress = int(progress)
        if not watched and progress < WATCHED_PERCENT:
            return {'imdb': imdb, 'watched': False}
        now = int(self.clock())
        with closing(sqlite3.connect(self.db)) as c, c:
            # A later report never revives a prompt the owner already kept.
            c.execute('''INSERT INTO movie_watched_prompts VALUES (?,?,?,?,?,NULL)
                         ON CONFLICT(principal, imdb) DO UPDATE SET
                         progress=max(progress, excluded.progress), source=excluded.source''',
                      (principal, imdb, progress, 'marked' if watched else 'progress', now))
            dismissed = c.execute('SELECT dismissed FROM movie_watched_prompts WHERE principal=? AND imdb=?',
                                  (principal, imdb)).fetchone()[0]
        return {'imdb': imdb, 'watched': True, 'kept': dismissed is not None}

    def keep(self, principal, imdb):
        imdb = self._imdb(imdb)
        with closing(sqlite3.connect(self.db)) as c, c:
            changed = c.execute('UPDATE movie_watched_prompts SET dismissed=? WHERE principal=? AND imdb=? AND dismissed IS NULL',
                                (int(self.clock()), principal, imdb)).rowcount
            if not changed and not c.execute('SELECT 1 FROM movie_watched_prompts WHERE principal=? AND imdb=?',
                                             (principal, imdb)).fetchone():
                # Keep before any report (e.g. offline phone) is still remembered.
                c.execute('INSERT INTO movie_watched_prompts VALUES (?,?,0,?,?,?)',
                          (principal, imdb, 'kept', int(self.clock()), int(self.clock())))
        return {'imdb': imdb, 'kept': True}

    def pending(self, principal, ready, removed=frozenset()):
        """ready: {imdb: title} of files currently indexed and valid on the server."""
        with closing(sqlite3.connect(self.db)) as c:
            rows = c.execute('''SELECT imdb, progress, source, reported FROM movie_watched_prompts
                                WHERE principal=? AND dismissed IS NULL ORDER BY reported DESC''',
                             (principal,)).fetchall()
        return [{'imdb': i, 'title': ready[i], 'progressPercent': p, 'source': s, 'reportedAt': r}
                for i, p, s, r in rows if i in ready and i not in removed]
