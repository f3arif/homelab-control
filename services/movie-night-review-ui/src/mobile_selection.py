"""Explicit owner selections authorize one durable server download each."""
from contextlib import closing
import json
import re


class MobileSelections:
    def __init__(self, controller):
        self.c = controller
        with closing(controller.feedback.connect()) as db, db:
            db.execute('CREATE TABLE IF NOT EXISTS movie_mobile_selections(principal TEXT NOT NULL,imdb TEXT NOT NULL,metadata TEXT NOT NULL,updated INTEGER NOT NULL,PRIMARY KEY(principal,imdb))')

    @staticmethod
    def intent(request_id, retry):
        if not isinstance(request_id, str) or not re.fullmatch(r'[A-Za-z0-9-]{16,80}', request_id) or type(retry) is not bool:
            raise ValueError('Invalid Movie Night selection request. Try again.')

    def selected(self, principal, imdb):
        with closing(self.c.feedback.connect()) as db:
            return db.execute('SELECT 1 FROM movie_mobile_selections WHERE principal=? AND imdb=?', (principal, imdb)).fetchone() is not None

    def require_eligible(self, principal, imdb):
        rows = {r['id']:r for r in self.c.review_pool()}
        if imdb not in rows or self.c.feedback.ratings(principal).get(imdb, {}).get('value') in ('seen', 'dislike'):
            raise ValueError('This Movie Night selection is no longer eligible. Check your Movie Night list.')
        return rows[imdb]

    def select(self, principal, imdb, request_id, retry):
        from movie_night import present_movie
        c = self.c
        self.intent(request_id, retry)
        c.feedback.principal(principal)
        with c.lock:
            c.require_enabled()
            if not c.review_enabled or not c.auto_downloads:
                raise ValueError('Movie Night server downloads are unavailable. Try again later.')
            row = self.require_eligible(principal, imdb)
            # Selection and its queue request are committed together. Existing groups
            # and previously accepted requests are never replaced by a mobile tap.
            with closing(c.feedback.connect()) as db, db:
                db.execute('BEGIN IMMEDIATE')
                saved = c.auto_downloads.enqueue(db, principal, [imdb], {imdb:row}, request_id, [imdb] if retry else [])
                if saved:
                    metadata = present_movie(row, int(c.clock()), 'Selected for Movie Night; server download requested.')
                    db.execute('INSERT INTO movie_mobile_selections VALUES(?,?,?,?) ON CONFLICT(principal,imdb) DO UPDATE SET metadata=excluded.metadata,updated=excluded.updated',
                               (principal, imdb, json.dumps(metadata), int(c.clock())))
                if not db.execute('SELECT 1 FROM movie_mobile_selections WHERE principal=? AND imdb=?', (principal, imdb)).fetchone():
                    raise ValueError('Invalid Movie Night selection request. Try again.')
            c.auto_downloads.start()
            snapshot = c.downloads(principal)
            request = next(r for r in snapshot['requests'] if r['imdb'] == imdb)
            job = next((j for j in snapshot['jobs'] if j['id'] == request['jobId'] and j['imdb'] == imdb), None)
            download = dict(request, state=job['state'] if job else request['state'])
            return {'selected':True, 'downloadRequested':True, 'download':download}

    def enrich(self, principal, requests, db):
        ids = [r['imdb'] for r in requests]
        if not ids:
            return requests
        # The existing request API returns at most100 recent requests. Read only
        # their metadata; retained history must never impose a lifetime pick cap.
        sql = 'SELECT imdb,metadata FROM movie_mobile_selections WHERE principal=? AND imdb IN (' + ','.join('?' for _ in ids) + ')'
        metadata = {r[0]:json.loads(r[1]) for r in db.execute(sql, [principal, *ids])}
        return [dict(r, selectionSource='nuvio-selection', movie=metadata[r['imdb']]) if r['imdb'] in metadata else r for r in requests]
