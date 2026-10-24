"""Durable Finalize & download queue. Imports, reads and old picks start nothing."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing, nullcontext
from pathlib import Path
from uuid import uuid4
import json
import re
from movie_night import ApprovalStore, RESERVE, select_compact


class AutoDownloads:
    def __init__(self, controller, acquire=None):
        self.c=controller;self.acquire=acquire
        self.pool=ThreadPoolExecutor(max_workers=1,thread_name_prefix='movie-auto-sources')
        self.future=None;self.closed=False
        with closing(self.c.feedback.connect()) as db,db:
            db.execute('CREATE TABLE IF NOT EXISTS movie_download_queue(id TEXT PRIMARY KEY,principal TEXT NOT NULL,imdb TEXT NOT NULL,name TEXT NOT NULL,state TEXT NOT NULL,job_id TEXT,message TEXT NOT NULL,updated INTEGER NOT NULL,UNIQUE(principal,imdb))')
            db.execute('CREATE TABLE IF NOT EXISTS movie_download_requests(principal TEXT NOT NULL,id TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(principal,id))')

    def close(self):
        with self.c.lock:self.closed=True
        self.pool.shutdown(wait=True)

    def enqueue(self, db, principal, ids, rows, request_id, retry):
        """Called inside the same transaction that saves finalization."""
        if not isinstance(request_id,str) or not re.fullmatch(r'[A-Za-z0-9-]{16,80}',request_id):
            raise ValueError('Reload Movie Night to finalize and download.')
        if not isinstance(retry,list) or len(retry)>len(ids) or any(not isinstance(x,str) for x in retry) or not set(retry)<=set(ids):
            raise ValueError('Invalid download retry.')
        body=json.dumps([ids,sorted(set(retry))],separators=(',',':'))
        previous=db.execute('SELECT body FROM movie_download_requests WHERE principal=? AND id=?',(principal,request_id)).fetchone()
        if previous:
            if previous[0]!=body:raise ValueError('Download request ID was already used. Reload Movie Night.')
            return False # an old replay must not overwrite a newer selection
        db.execute('INSERT INTO movie_download_requests VALUES(?,?,?)',(principal,request_id,body))
        now=int(self.c.clock())
        for imdb in ids:
            db.execute('INSERT OR IGNORE INTO movie_download_queue VALUES(?,?,?,?,?,NULL,?,?)',
                       (str(uuid4()),principal,imdb,rows[imdb]['name'],'queued','Waiting for a source check.',now))
            if imdb in retry:
                db.execute("UPDATE movie_download_queue SET state='queued',message='Waiting for a source check.',updated=? WHERE principal=? AND imdb=? AND job_id IS NULL AND state IN ('unavailable','failed','cancelled')",(now,principal,imdb))
        return True

    def start(self):
        with self.c.lock:
            if not self.closed and (self.future is None or self.future.done()):
                self.future=self.pool.submit(self._drain)

    def recover(self):
        # A source check is safe to repeat; linked jobs have their own recovery.
        with closing(self.c.feedback.connect()) as db,db:
            db.execute("UPDATE movie_download_queue SET state='queued' WHERE state='checking' AND job_id IS NULL")
        self.start()

    def requests(self, principal, db=None):
        with (closing(self.c.feedback.connect()) if db is None else nullcontext(db)) as db:
            rows=db.execute('SELECT id,imdb,name,state,job_id,message FROM movie_download_queue WHERE principal=? ORDER BY rowid DESC LIMIT 100',(principal,)).fetchall()
        return [dict(id=r[0],imdb=r[1],name=r[2],state=r[3],jobId=r[4],message=r[5],
                     canRetry=r[4] is None and r[3] in ('unavailable','failed','cancelled')) for r in rows]

    def cancel(self, request_id, principal):
        with self.c.lock,closing(self.c.feedback.connect()) as db,db:
            row=db.execute('SELECT job_id,state FROM movie_download_queue WHERE id=? AND principal=?',(request_id,principal)).fetchone()
            if not row:raise PermissionError()
            if row[0]:return self.c.cancel(row[0],principal)
            if row[1] not in ('queued','checking'):raise ValueError('No cancellable transfer. Existing completed files are preserved.')
            db.execute("UPDATE movie_download_queue SET state='cancelled',message='Cancelled before a server transfer.',updated=? WHERE id=?",(int(self.c.clock()),request_id))
            return {'state':'cancelled'}

    def _active(self, request_id, principal, imdb):
        if self.closed:raise ValueError('queue stopped')
        with closing(self.c.feedback.connect()) as db:
            row=db.execute('SELECT state FROM movie_download_queue WHERE id=? AND principal=?',(request_id,principal)).fetchone()
        if row!=('checking',):raise ValueError('download request no longer active')
        self.c.require_enabled();self.c.require_finalized(imdb,principal)

    def _finish(self, request_id, state, message):
        with closing(self.c.feedback.connect()) as db,db:
            db.execute("UPDATE movie_download_queue SET state=?,message=?,updated=? WHERE id=? AND state='checking'",(state,message,int(self.c.clock()),request_id))

    def _drain(self):
        while not self.closed:
            # The controller lock closes the empty-queue/enqueue race with start().
            with self.c.lock,closing(self.c.feedback.connect()) as db,db:
                db.execute('BEGIN IMMEDIATE')
                row=db.execute("SELECT id,principal,imdb FROM movie_download_queue WHERE state='queued' ORDER BY rowid LIMIT 1").fetchone()
                if not row:
                    self.future=None
                    return
                request_id,principal,imdb=row
                db.execute("UPDATE movie_download_queue SET state='checking',message='Finding a cached 1080p file (5–15 GB).' WHERE id=?",(request_id,))
            try:
                self._active(request_id,principal,imdb)
                with closing(ApprovalStore(self.c.db)) as store:
                    prior=store.db.execute('SELECT j.id,p.principal FROM jobs j JOIN plans p ON p.id=j.id WHERE j.title=?',(imdb,)).fetchone()
                    if prior:
                        if prior[1]!=principal:raise ValueError('existing file')
                        with store.db:store.db.execute("UPDATE movie_download_queue SET state='linked',job_id=?,message='' WHERE id=? AND state='checking'",(prior[0],request_id))
                        continue
                choice=select_compact(self.c.choices(imdb))
                if not choice and self.acquire:
                    def guard(size=1):
                        self._active(request_id,principal,imdb)
                        with closing(ApprovalStore(self.c.db)) as store:
                            from movie_night import QUOTA
                            reserved=sum(json.loads(x[0])['choice']['size']-x[1] for x in store.db.execute("SELECT payload,bytes FROM jobs WHERE state IN ('approved','downloading')"))
                            committed=sum(json.loads(x[0])['choice']['size']+1 for x in store.db.execute('SELECT payload FROM jobs'))
                        if self.c.free()-reserved-size<RESERVE or QUOTA-committed<size+1:raise ValueError('insufficient storage or quota')
                    guard();choice=self.acquire(imdb,guard)
                if not choice:
                    self._finish(request_id,'unavailable','No cached 1080p file between 5 and 15 GB is available. Try again later.');continue
                self._active(request_id,principal,imdb)
                if self.c.inventory.verify(choice)!=choice:raise ValueError('source changed')
                checked=int(self.c.clock())
                with self.c.lock:
                    self._active(request_id,principal,imdb)
                    path=self.c.worker.root/'Movies'/Path(choice.destination).name
                    if any(p.exists() or p.is_symlink() for p in (path,Path(str(path)+'.part'))):raise ValueError('existing file')
                    with closing(ApprovalStore(self.c.db)) as store:
                        pid=store.approve_finalized(choice,principal,request_id,int(self.c.clock()),self.c.free(),checked)
                    self.c.futures[pid]=self.c.pool.submit(self.c.worker.run,pid)
            except Exception as exc:
                if self.closed:return # leave a checking request recoverable after shutdown
                # Never expose provider exceptions, credentials or temporary URLs.
                message='Source service unavailable. Try again later.'
                if str(exc)=='insufficient storage or quota':message='Not enough free storage or transfer budget. No server transfer started.'
                elif str(exc)=='8 TB drive unavailable; downloads paused.':message=str(exc)
                elif str(exc)=='existing file':message='An existing or partial server file needs review; it will not be overwritten.'
                elif str(exc)=='source changed':message='Source details changed during checking. Try again.'
                elif str(exc).startswith('Finalize '):message='Your selection changed. Finalize eligible picks before retrying.'
                self._finish(request_id,'failed',message)
