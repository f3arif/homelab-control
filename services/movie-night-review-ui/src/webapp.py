"""Factory-only Movie Night UI/API. No daemon, credential read or live activation."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing, nullcontext
from dataclasses import asdict
from html import escape
from pathlib import Path
import json
import secrets
import sqlite3
import threading
import time
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse, Response
from movie_night import ApprovalStore, Choice, QUOTA, ROOT, MIN_BYTES, CAP, select_compact, shortlist, stream_status, excluded_genres
from movie_posters import PosterCache, image_mime
from feedback import MIN_PICKS, MAX_PICKS, VISIBLE_MOVIES
from genre_settings import GENRES, GenreSettingsStore, SettingsConflict, genre_match


class Controller:
    def __init__(self, db, choices, inventory, worker, index, free, *,
                 enabled=False, shortlist_payload=None, stream_validator=None, clock=time.time, seen_policy=None, review_enabled=False, refill_provider=None):
        self.db=Path(db); self.choices=choices; self.inventory=inventory
        self.worker=worker; self.index=index; self.free=free
        self.enabled=enabled; self.shortlist_payload=shortlist_payload or (lambda:{})
        self.stream_validator=stream_validator; self.clock=clock
        from seen_policy import SeenPolicy
        from feedback import FeedbackStore
        self.seen_policy=seen_policy or SeenPolicy()
        self.feedback=FeedbackStore(self.db)
        self.genre_settings=GenreSettingsStore(self.db.parent)
        self.review_enabled=review_enabled
        self.refill_provider=refill_provider
        from similar_movies import SimilarMovies
        self.similar=SimilarMovies(self)
        original_payload=self.shortlist_payload
        self.shortlist_payload=lambda:self.similar.store.merge(original_payload())
        self.pool=ThreadPoolExecutor(max_workers=1,thread_name_prefix='movie-night')
        self.csrf={}; self.lock=threading.RLock();self.futures={}
        self.auto_downloads=None
        self.delete_service=None  # Owner-only, mounted-media delete confirmation
        self.lookups={}; self.lookup_pool=ThreadPoolExecutor(max_workers=1,thread_name_prefix='movie-sources')
        with closing(ApprovalStore(self.db)): pass

    def enable_auto_downloads(self,acquire=None):
        self.require_enabled()
        from auto_downloads import AutoDownloads
        self.auto_downloads=AutoDownloads(self,acquire)
        self.auto_downloads.recover()

    def close(self):
        self.similar.close()
        if self.auto_downloads:self.auto_downloads.close()
        if self.refill_provider and hasattr(self.refill_provider,'close'):self.refill_provider.close()
        self.lookup_pool.shutdown(wait=True)
        self.pool.shutdown(wait=True)

    def rows(self): return shortlist(self.shortlist_payload(),int(self.clock()),self.seen_policy,genre_settings=self.genre_settings.read())

    def review_pool(self):
        return shortlist(self.shortlist_payload(),int(self.clock()),self.seen_policy,limit=None,genre_settings=self.genre_settings.read())

    def review(self,principal):
        from feedback import rank_reviewed, by_rank
        with self.lock, (self.refill_provider.lock if hasattr(self.refill_provider,'lock') else nullcontext()):
            if self.review_enabled and hasattr(self.refill_provider,'maintain'):
                try:self.refill_provider.maintain()
                except Exception:pass # buffer upkeep must never block the page
            ratings=self.feedback.ratings(principal)
            payload=self.shortlist_payload(); now=int(self.clock())
            generated=payload.get('generatedEpoch')
            fresh=type(generated) is int and 0<=now-generated<=30*86400
            settings=self.genre_settings.read()
            pool=shortlist(payload,now,self.seen_policy,limit=None,genre_settings=settings)
            saved_pool=pool if fresh else shortlist(payload,generated if type(generated) is int else now,self.seen_policy,limit=None,genre_settings=settings)
            saved_rows={r['id']:r for r in saved_pool}
            # Fresh explicit additions remain descriptive when weekly rows age out.
            saved_rows.update({r['id']:r for r in pool})
            manual={r['id'] for r in pool if r.get('manualSuggestion')}
            genre_blocked={r['id']:dict(r,releaseInfo=str(r.get('year',''))) for r in payload.get('movies',[])+payload.get('retainedIneligibleSelections',[])+payload.get('genreFilteredMovies',[]) if r['id'] not in manual and not genre_match(r,settings)}
            saved_rows.update(genre_blocked)
            eligible={r['id']:r for r in pool if ratings.get(r['id'],{}).get('value') not in ('dislike','seen')}
            saved=self.feedback.saved(principal)
            rank=self.feedback.rank(principal)
            saved=dict(saved,ids=by_rank(saved['ids'],rank))
            refill_at=self.feedback.refill_requested(principal)
            refill_pending=refill_at is not None and refill_at>payload.get('publishedEpoch',0)
            valid=saved['valid'] and MIN_PICKS<=len(saved['ids'])<=MAX_PICKS and set(saved['ids'])<=set(eligible)
            ranked=rank_reviewed(pool,ratings,limit=len(pool),genre_settings=settings)
            added=set(payload.get('requestedSuggestionIds',[]))
            visible=[r for r in ranked if r['id'] in added]+[r for r in ranked if r['id'] not in added][:VISIBLE_MOVIES]
            return {'movies':visible,'reviewEnabled':self.review_enabled,'similarSearchEnabled':self.review_enabled,
                    'downloadPolicy':{'minBytes':5_000_000_000,'maxBytes':CAP,'quality':'1080p','storage':'8 TB drive','host':'afz-zbook'},
                    'actionsEnabled':self.enabled,'autoDownloads':bool(self.auto_downloads and self.enabled),
                    'downloadRequestedIds':[x['imdb'] for x in self.auto_downloads.requests(principal)] if self.auto_downloads else [],'shortlistFresh':fresh,'seenStateComplete':self.seen_policy.complete,
                    'eligibleIds':list(eligible),'selectionLimits':{'min':MIN_PICKS,'max':MAX_PICKS,'visible':VISIBLE_MOVIES},
                    'disliked':[dict(v['metadata'],id=k) for k,v in ratings.items() if v['value']=='dislike'],
                    'seen':[dict(v['metadata'],id=k) for k,v in ratings.items() if v['value']=='seen'],
                    'finalized':{'ids':saved['ids'],'valid':valid,'excludedIds':[i for i in saved['ids'] if i in genre_blocked],'reason':None if valid else ('genre-filter' if set(saved['ids']) & set(genre_blocked) else 'shortlist-stale' if not fresh else 'eligibility-changed'),
                                 'movies':[saved_rows.get(i,ratings.get(i,{}).get('metadata',{'id':i,'name':'Saved selection','releaseInfo':''})) for i in saved['ids']]},
                    'rank':rank,'excludedGenres':settings['excluded'],'genreSettings':dict(settings,options=list(GENRES)),
                    'reserveCount':max(0,len(eligible)-len(visible)),
                    'refillRequest':{'pending':refill_pending,'requested':refill_at is not None, **(self.refill_provider.status() if self.refill_provider else {})},
                    'replacementAvailable':len(eligible)>VISIBLE_MOVIES}

    def save_genres(self,principal,data):
        if not self.review_enabled:raise ValueError('Movie review is disabled pending activation.')
        self.feedback.principal(principal)
        with self.lock, (self.refill_provider.lock if hasattr(self.refill_provider,'lock') else nullcontext()):
            self.genre_settings.save(data)
            # A settings save can refresh metadata, but never finalize or enqueue media.
            return self.review(principal)

    def request_refill(self,principal,request_id=None):
        if not self.review_enabled:raise ValueError('Movie review is disabled pending activation.')
        if request_id is not None and (not isinstance(request_id,str) or not 1<=len(request_id)<=80):raise ValueError('Invalid refill request ID')
        with self.lock:
            if self.refill_provider and hasattr(self.refill_provider,'duplicate') and self.refill_provider.duplicate(request_id):return self.review(principal)
            self.feedback.request_refill(principal,self.shortlist_payload().get('publishedEpoch',0),self.clock())
            if self.refill_provider:
                if hasattr(self.refill_provider,'request'):self.refill_provider.request(request_id)
                else:self.refill_provider.fulfill()
            return self.review(principal)

    def rate(self,principal,imdb,value):
        if not self.review_enabled:raise ValueError('Movie review is disabled pending activation.')
        with self.lock:
            pool={r['id']:r for r in self.review_pool()}
            previous=self.feedback.ratings(principal).get(imdb)
            movie=pool.get(imdb) or (previous['metadata'] if previous else None)
            if not movie:raise ValueError('A selected movie is no longer eligible. Refresh your picks.')
            self.feedback.rate(principal,movie,value)
            result=self.review(principal)
            if value in ('dislike','seen') and getattr(self.refill_provider,'automatic',False) and len(result['eligibleIds'])<VISIBLE_MOVIES:
                return self.request_refill(principal,'auto-'+secrets.token_hex(16))
            return result

    def set_rank(self,principal,ids):
        if not self.review_enabled:raise ValueError('Movie review is disabled pending activation.')
        with self.lock:
            self.feedback.set_rank(principal,ids)
            return self.review(principal)

    def ready_metas(self,principal):
        from feedback import by_rank
        return by_rank(self.index.metas(),self.feedback.rank(principal),key=lambda m:m['id'])

    def finalize(self,principal,ids,*,start_downloads=False,request_id=None,retry=None):
        if not self.review_enabled:raise ValueError('Movie review is disabled pending activation.')
        with self.lock:
            ratings=self.feedback.ratings(principal)
            eligible={r['id'] for r in self.review_pool() if ratings.get(r['id'],{}).get('value') not in ('dislike','seen')}
            callback=None
            if self.auto_downloads:
                self.require_enabled()
                if start_downloads is not True:raise ValueError('Reload Movie Night to finalize and download.')
                rows={r['id']:r for r in self.review_pool()}
                callback=lambda db:self.auto_downloads.enqueue(db,principal,ids,rows,request_id,retry or [])
            self.feedback.finalize(principal,ids,eligible,on_saved=callback)
            if self.auto_downloads:self.auto_downloads.start()
            return self.review(principal)

    def require_finalized(self,imdb,principal):
        if not self.review_enabled:return # preserve existing non-review/manual integration
        state=self.review(principal)['finalized']
        if not state['valid'] or imdb not in state['ids']:
            raise ValueError(f'Finalize {MIN_PICKS} to {MAX_PICKS} eligible movies before reviewing a download.')


    def token(self, principal):
        with self.lock: return self.csrf.setdefault(principal,secrets.token_urlsafe(32))

    def check_token(self, principal, token):
        with self.lock:
            expected=self.csrf.get(principal)
            return bool(expected and secrets.compare_digest(expected,str(token)))

    def preview_server_delete(self, imdb, principal):
        self.require_enabled()
        if not self.delete_service:
            raise ValueError("Server deletion is unavailable.")
        return self.delete_service.preview(principal, imdb)

    def delete_server_copy(self, imdb, token, confirmed_title, principal):
        self.require_enabled()
        if not self.delete_service:
            raise ValueError("Server deletion is unavailable.")
        with self.lock:
            return self.delete_service.delete(principal, imdb, token, confirmed_title)

    def removed_media_ids(self):
        reader = getattr(self.index, 'removed_ids', None)
        return reader() if callable(reader) else set()

    def require_not_removed(self, imdb):
        if imdb in self.removed_media_ids():
            raise ValueError('Owner intentionally removed server copy; no automatic re-download')

    def removed_status(self, status, imdb):
        if imdb in self.removed_media_ids():
            return dict(status, state='removed', downloaded=False, indexed=False,
                        playbackTested=False, processing=False)
        return status

    def require_enabled(self):
        if not self.enabled: raise ValueError('Downloads and source checks are disabled pending activation approval.')

    def require_owner(self, store, pid, principal):
        row=store.db.execute('SELECT principal FROM plans WHERE id=?',(pid,)).fetchone()
        if not row or row[0]!=principal: raise PermissionError('confirmation unavailable')

    def recover_jobs(self):
        # A restart never retries an interrupted media request or switches its source.
        with closing(ApprovalStore(self.db)) as store:
            for pid, in store.db.execute("SELECT id FROM jobs WHERE state='downloading'").fetchall():
                store.transition(pid,'failed')
            removed=self.removed_media_ids()
            queued=[]
            for pid, imdb in store.db.execute("SELECT id,title FROM jobs WHERE state='approved'").fetchall():
                if imdb in removed:store.transition(pid,'failed')
                else:queued.append(pid)
        for pid in queued:self.futures[pid]=self.pool.submit(self.worker.run,pid)

    def prepare(self,imdb,principal):
        self.require_enabled();self.require_finalized(imdb,principal)
        self.require_not_removed(imdb)
        with self.lock:
            now=self.clock()
            for pid,entry in list(self.lookups.items()):
                if now-entry[2]>900 and entry[3].done():del self.lookups[pid]
            for pid,(owner,title,created,future) in self.lookups.items():
                if owner==principal and title==imdb and not future.done():
                    return {'lookupId':pid,'state':'checking-sources'}
            if len(self.lookups)>=32:raise ValueError('Too many source checks. Try again shortly.')
            pid=secrets.token_hex(16)
            self.lookups[pid]=(principal,imdb,now,self.lookup_pool.submit(self.propose,imdb,principal))
            return {'lookupId':pid,'state':'checking-sources'}

    def lookup(self,pid,principal):
        entry=self.lookups.get(pid)
        if not entry or entry[0]!=principal or self.clock()-entry[2]>900:raise PermissionError()
        self.require_not_removed(entry[1])
        future=entry[3]
        if not future.done():return {'lookupId':pid,'state':'checking-sources'}
        return future.result()

    def downloads(self,principal):
        with closing(ApprovalStore(self.db)) as store:
            # Queue linkage and jobs must be read from one SQLite snapshot.
            # Otherwise a concurrent dispatch can appear linked without its job.
            store.db.execute('BEGIN')
            rows=store.db.execute('SELECT j.id,j.payload FROM jobs j JOIN plans p ON p.id=j.id WHERE p.principal=? ORDER BY p.rowid DESC LIMIT 100',(principal,)).fetchall()
            result=[]
            for pid,raw in rows:
                choice=json.loads(raw)['choice'];status=store.status(pid)
                result.append({'id':pid,'name':choice['title'],'imdb':choice['imdb'],'size':choice['size'],
                               'destination':choice['destination'],**status})
            requests=self.auto_downloads.requests(principal,db=store.db) if self.auto_downloads else []
            removed=self.removed_media_ids()
            for item in result:
                if item['imdb'] in removed:
                    item['state']='removed'
                    item['downloaded']=False
                    item['indexed']=False
                    item['playbackTested']=False
            for item in requests:
                if item['imdb'] in removed:
                    item['state']='removed'
                    item['canRetry']=False
                    item['message']='Removed from your 8 TB server.'
            return {'jobs':result,'requests':requests}

    def propose(self, imdb, principal):
        self.require_enabled()
        self.require_finalized(imdb,principal)
        self.require_not_removed(imdb)
        choice=select_compact(self.choices(imdb))
        if not choice: raise ValueError('No matching compact source')
        self.require_finalized(imdb,principal)
        current=self.inventory.verify(choice)
        self.require_not_removed(imdb)
        if current!=choice: raise ValueError('Source metadata changed. Refresh sources before confirmation.')
        if any(p.exists() or p.is_symlink() for p in [self.worker.root/'Movies'/Path(choice.destination).name,self.worker.root/'Movies'/(Path(choice.destination).name+'.part')]):
            raise ValueError('This file is already present; it will not be overwritten.')
        with closing(ApprovalStore(self.db)) as store:
            plan=store.propose(choice,principal,int(self.clock()),self.free())
            committed=sum(json.loads(x[0])['choice']['size']+1 for x in store.db.execute('SELECT payload FROM jobs'))
        # The binding covers the displayed quota value as well as all source metadata.
        with closing(ApprovalStore(self.db)) as store:
            payload=json.loads(store.db.execute('SELECT payload FROM plans WHERE id=?',(plan['confirmationId'],)).fetchone()[0])
            payload['quotaRemainingBytes']=QUOTA-committed
            from movie_night import canonical
            from hashlib import sha256
            with store.db: store.db.execute('UPDATE plans SET payload=? WHERE id=?',(canonical(payload),plan['confirmationId']))
            plan.update(payload);plan['binding']=sha256(canonical(payload).encode()).hexdigest()
        return plan

    def approve(self, pid, binding, reply, principal):
        self.require_enabled()
        with self.lock, closing(ApprovalStore(self.db)) as store:
            self.require_owner(store,pid,principal)
            saved=store.db.execute('SELECT payload FROM plans WHERE id=?',(pid,)).fetchone()
            prior=store.status(pid)
            choice=Choice(**json.loads(saved[0])['choice'])
            # Replays return the durable job; they never fetch links or dispatch again.
            if prior:
                result=store.approve(pid,binding,principal,reply,choice,int(self.clock()),int(self.clock()),self.free(),completed_present=True)
                return self.removed_status(result,choice.imdb)
            self.require_not_removed(choice.imdb)
            self.require_finalized(choice.imdb,principal)
            current=self.inventory.verify(choice)
            existing=(self.worker.root/'Movies'/Path(choice.destination).name).exists()
            result=store.approve(pid,binding,principal,reply,current,int(self.clock()),int(self.clock()),self.free(),existing=existing,completed_present=True)
            if result['newJob']:
                self.futures[pid]=self.pool.submit(self.worker.run,pid)
            return result

    def status(self, pid, principal):
        with closing(ApprovalStore(self.db)) as store:
            self.require_owner(store,pid,principal)
            status=store.status(pid) or {'state':'awaiting-confirmation','downloaded':False,'indexed':False,'playbackTested':False}
            future=self.futures.get(pid)
            row=store.db.execute('SELECT title FROM jobs WHERE id=?',(pid,)).fetchone()
            result={**status,'processing':bool(future and not future.done())}
            return self.removed_status(result,row[0]) if row else result

    def cancel(self, pid, principal):
        with self.lock, closing(ApprovalStore(self.db)) as store:
            self.require_owner(store,pid,principal)
            status=store.status(pid)
            if not status or status['state'] not in {'approved','downloading'}:
                raise ValueError('No cancellable transfer. Existing completed files are preserved.')
            with store.db: store.db.execute('INSERT OR IGNORE INTO cancellations VALUES (?)',(pid,))
            return {'state':'cancellation-requested'}

    def check_stream(self, imdb, principal, sample):
        self.require_enabled()
        choice=select_compact(self.choices(imdb))
        if not choice or not self.stream_validator:
            return {'status':'validation-required','playbackTested':False}
        # Validator resolves/probes only when separately enabled; URLs never enter state.
        return self.stream_validator.check(choice,principal,sample)


def create_app(controller, authorize=None, *, allowed_origin='http://localhost', prefix='/movie-night'):
    """authorize must be supplied by the existing trusted control boundary.

    No fallback principal, IP-based trust, header identity, or new login is invented.
    Defaults deny every request. No port is opened by this factory.
    """
    app=FastAPI(docs_url=None,redoc_url=None,openapi_url=None)
    assets=Path(__file__).parent
    posters=PosterCache(controller.db.parent/'posters')
    def identity(request, write=False):
        principal=authorize(request) if authorize else None
        if not principal: raise HTTPException(403,'Existing authorized session required')
        if write and (request.headers.get('origin')!=allowed_origin or not controller.check_token(principal,request.headers.get('x-movie-night-csrf',''))):
            raise HTTPException(403,'Confirmation session mismatch')
        return principal
    def safe(call):
        try: return call()
        except HTTPException: raise
        except PermissionError: raise HTTPException(404,'Confirmation unavailable')
        except (ValueError,sqlite3.IntegrityError) as exc:
            allowed={'Reload Movie Night to finalize and download.','Invalid download retry.','Download request ID was already used. Reload Movie Night.',
                     'No matching compact source','Too many source checks. Try again shortly.','Downloads and source checks are disabled pending activation approval.',
                     'Source metadata changed. Refresh sources before confirmation.',
                     'This file is already present; it will not be overwritten.',
                     'No cancellable transfer. Existing completed files are preserved.',
                     'Server deletion is unavailable.','Owner session unavailable.',
                     'Owner intentionally removed server copy; no automatic re-download',
                     'Invalid movie ID.','Invalid movie ranking.','Transfer state unavailable; no movie was deleted.',
                     'A transfer is active; no movie was deleted.',
                     'Server file no longer available. Refresh Movie Night.',
                     'Server file identity changed; no movie was deleted.',
                     'Server metadata unavailable; no movie was deleted.',
                     'Confirmation expired. Review the movie again.',
                     'Server file changed. Review the movie again.',
                     'Server index changed. Review the movie again.',
                     'choice changed; new confirmation required','stale choice; new confirmation required',
                     'insufficient storage or quota','explicit yes to this confirmation required',
                     'approval binding mismatch','Movie review is disabled pending activation.',
                     'Choose Like or Dislike for a listed movie.',f'Select {MIN_PICKS} to {MAX_PICKS} different movies to finalize.',
                     'A selected movie is no longer eligible. Refresh your picks.',
                     f'Finalize {MIN_PICKS} to {MAX_PICKS} eligible movies before reviewing a download.'}
            message=str(exc) if str(exc) in allowed else 'Source or confirmation unavailable. Refresh before confirming again.'
            raise HTTPException(409,message)
        except Exception: raise HTTPException(503,'Source or worker unavailable; nothing new was started.')
    async def body(request):
        raw=await request.body()
        if len(raw)>8192: raise HTTPException(413,'Request too large')
        try:
            data=json.loads(raw)
            if not isinstance(data,dict): raise ValueError()
            return data
        except (ValueError,TypeError): raise HTTPException(400,'Invalid request')

    @app.get(prefix,include_in_schema=False)
    @app.get(prefix+'/',include_in_schema=False)
    def page(request:Request):
        principal=identity(request)
        base=request.scope.get('root_path','')+prefix
        html=(assets/'screen.html').read_text().replace('__BASE__',escape(base,quote=True)).replace('__CSRF__',escape(controller.token(principal),quote=True)).replace('__MIN_PICKS__',str(MIN_PICKS)).replace('__MAX_PICKS__',str(MAX_PICKS))
        return HTMLResponse(html,headers={'Cache-Control':'no-store','Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; frame-ancestors 'none'",'Referrer-Policy':'no-referrer'})

    @app.get(prefix+'/screen.js')
    def javascript(request:Request): identity(request);return FileResponse(assets/'screen.js',media_type='application/javascript',headers={'Cache-Control':'private, no-store'})
    @app.get(prefix+'/screen.css')
    def css(request:Request): identity(request);return FileResponse(assets/'screen.css',media_type='text/css',headers={'Cache-Control':'private, no-store'})
    @app.get(prefix+'/posters/{imdb}.img')
    def poster(request:Request,imdb:str):
        identity(request)
        data=posters.get(imdb)
        if data is None:raise HTTPException(404,'Poster unavailable')
        return Response(content=data,media_type=image_mime(data),headers={'Cache-Control':'private, max-age=86400','X-Content-Type-Options':'nosniff'})
    @app.get(prefix+'/api/shortlist')
    def rows(request:Request):
        principal=identity(request)
        return JSONResponse(safe(lambda:controller.review(principal)),headers={'Cache-Control':'private, no-store'})
    @app.post(prefix+'/api/feedback')
    async def feedback(request:Request):
        principal=identity(request,True);data=await body(request)
        if data.get('action') in ('search-titles','title-preview','find-similar','similar-status','add-similar'):
            try:return controller.similar.action(principal,data)
            except ValueError as exc:raise HTTPException(400,str(exc))
            except Exception:raise HTTPException(503,'Movie search is temporarily unavailable. Try again shortly.')
        if data.get('action')=='set-genre-settings':
            try:return controller.save_genres(principal,data.get('settings'))
            except SettingsConflict as exc:raise HTTPException(409,str(exc))
            except ValueError as exc:raise HTTPException(400,str(exc))
            except OSError:raise HTTPException(503,'Genre settings could not be saved. Reload to check before trying again.')
        if data.get('action')=='request-refill':return safe(lambda:controller.request_refill(principal,data.get('requestId')))
        return safe(lambda:controller.rate(principal,str(data.get('imdb','')),str(data.get('value',''))))
    @app.post(prefix+'/api/rank')
    async def rank(request:Request):
        principal=identity(request,True);data=await body(request)
        return safe(lambda:controller.set_rank(principal,data.get('ids')))
    @app.post(prefix+'/api/finalize')
    async def finalize(request:Request):
        principal=identity(request,True);data=await body(request)
        return safe(lambda:controller.finalize(principal,data.get('ids'),start_downloads=data.get('startDownloads'),request_id=data.get('requestId'),retry=data.get('retryDownloads')))

    @app.post(prefix+'/api/propose')
    async def propose(request:Request):
        principal=identity(request,True);data=await body(request)
        return safe(lambda:controller.prepare(str(data.get('imdb','')),principal))
    @app.get(prefix+'/api/lookup/{pid}')
    def lookup(pid:str,request:Request):return safe(lambda:controller.lookup(pid,identity(request)))
    @app.get(prefix+'/api/downloads')
    def downloads(request:Request):return safe(lambda:controller.downloads(identity(request)))
    @app.get(prefix+'/api/delete-server/{imdb}')
    def preview_server_delete(imdb: str, request: Request):
        principal=identity(request)
        return JSONResponse(safe(lambda: dict(controller.preview_server_delete(imdb,principal),
                                              csrfToken=controller.token(principal))),
                            headers={'Cache-Control':'private, no-store'})
    @app.post(prefix+'/api/delete-server')
    async def delete_server_copy(request: Request):
        principal=identity(request,True)
        data=await body(request)
        if (set(data) != {'imdb','confirmationToken','confirmedTitle'}
                or not all(isinstance(data[k],str) for k in ('imdb','confirmationToken','confirmedTitle'))
                or not 1 <= len(data['confirmedTitle']) <= 200
                or not 1 <= len(data['confirmationToken']) <= 128):
            raise HTTPException(400,'Invalid deletion confirmation')
        return safe(lambda: controller.delete_server_copy(
            data['imdb'], data['confirmationToken'], data['confirmedTitle'],principal))

    @app.post(prefix+'/api/approve')
    async def approve(request:Request):
        principal=identity(request,True);data=await body(request)
        return safe(lambda:controller.approve(str(data.get('confirmationId','')),str(data.get('binding','')),str(data.get('reply','')),principal))
    @app.get(prefix+'/api/status/{pid}')
    def status(pid:str,request:Request): return safe(lambda:controller.status(pid,identity(request)))
    @app.post(prefix+'/api/cancel')
    async def cancel(request:Request):
        principal=identity(request,True);data=await body(request)
        if data.get('requestId') and controller.auto_downloads:
            return safe(lambda:controller.auto_downloads.cancel(str(data['requestId']),principal))
        return safe(lambda:controller.cancel(str(data.get('confirmationId','')),principal))
    @app.post(prefix+'/api/check-stream')
    async def check_stream(request:Request):
        principal=identity(request,True);data=await body(request)
        return safe(lambda:controller.check_stream(str(data.get('imdb','')),principal,data.get('sample') or {}))
    @app.post(prefix+'/api/probe')
    async def probe(request:Request):
        principal=identity(request,True); data=await body(request)
        safe(controller.require_enabled)
        if not controller.stream_validator: raise HTTPException(409,'Stream validator unavailable')
        pid,content=safe(lambda:controller.stream_validator.probe(principal,str(data.get('deviceId','')),data.get('generation')))
        return Response(content,media_type='application/octet-stream',headers={'Cache-Control':'no-store, no-transform','Content-Encoding':'identity','X-Movie-Night-Probe':pid})
    @app.get(prefix+'/play/{lease}')
    def play(lease:str,request:Request):
        principal=identity(request)
        if not controller.stream_validator: raise HTTPException(409,'Stream validator unavailable')
        return safe(lambda:controller.stream_validator.play(lease,principal,request.headers.get('range')))
    @app.get(prefix+'/catalog/movie/downloaded.json')
    def downloaded(request:Request): return {'metas':controller.ready_metas(identity(request))}
    @app.api_route(prefix+'/media/{imdb}',methods=['GET','HEAD'])
    def media(imdb:str,request:Request):
        identity(request)
        path=controller.index.resolve(imdb,include_pending=request.method=='HEAD')
        if not path: raise HTTPException(404,'No validated local file')
        return FileResponse(path,filename=path.name,headers={'Cache-Control':'private, no-store'})
    return app

