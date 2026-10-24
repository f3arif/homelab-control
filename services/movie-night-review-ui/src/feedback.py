"""Per-user preferences and finalized selections; never resolve or acquire media."""
from contextlib import closing
import json
import sqlite3
import time
from seen_policy import canonical_id

MIN_PICKS = 3
MAX_PICKS = 10
VISIBLE_MOVIES = 10

class FeedbackStore:
    def __init__(self,path):
        self.path=path
        with closing(self.connect()) as db,db:
            db.execute('CREATE TABLE IF NOT EXISTS movie_feedback(principal TEXT NOT NULL,imdb TEXT NOT NULL,value TEXT NOT NULL,metadata TEXT NOT NULL,updated INTEGER NOT NULL,PRIMARY KEY(principal,imdb))')
            db.execute('CREATE TABLE IF NOT EXISTS movie_refill_requests(principal TEXT PRIMARY KEY,requested REAL NOT NULL)')
            db.execute('CREATE TABLE IF NOT EXISTS movie_finalized(principal TEXT PRIMARY KEY,ids TEXT NOT NULL,valid INTEGER NOT NULL,updated INTEGER NOT NULL)')
    def connect(self):
        return sqlite3.connect(self.path,timeout=10)
    @staticmethod
    def principal(principal):
        if not isinstance(principal,str) or not principal or len(principal)>512:raise PermissionError('authorized principal required')
        return principal
    def ratings(self,principal):
        self.principal(principal)
        with closing(self.connect()) as db:
            return {r[0]:{'value':r[1],'metadata':json.loads(r[2])} for r in db.execute('SELECT imdb,value,metadata FROM movie_feedback WHERE principal=?',(principal,))}
    def rate(self,principal,movie,value):
        self.principal(principal)
        imdb=canonical_id(movie)
        if not imdb or value not in ('like','dislike','seen','clear'):raise ValueError('Choose Like, Seen or Not for me for a listed movie.')
        # Store only reviewed descriptive fields; no source URLs/credentials.
        metadata={k:movie[k] for k in ('id','name','releaseInfo','fitTags','synopsis','genres','intensityGuide') if k in movie}
        with closing(self.connect()) as db,db:
            if value=='clear':db.execute('DELETE FROM movie_feedback WHERE principal=? AND imdb=?',(principal,imdb))
            else:db.execute('INSERT INTO movie_feedback VALUES(?,?,?,?,?) ON CONFLICT(principal,imdb) DO UPDATE SET value=excluded.value,metadata=excluded.metadata,updated=excluded.updated',(principal,imdb,value,json.dumps(metadata),int(time.time())))
            saved=db.execute('SELECT ids FROM movie_finalized WHERE principal=?',(principal,)).fetchone()
            if value in ('dislike','seen') and saved and imdb in json.loads(saved[0]):
                db.execute('UPDATE movie_finalized SET valid=0 WHERE principal=?',(principal,))
    def saved(self,principal):
        self.principal(principal)
        with closing(self.connect()) as db:
            row=db.execute('SELECT ids,valid FROM movie_finalized WHERE principal=?',(principal,)).fetchone()
        return {'ids':json.loads(row[0]),'valid':bool(row[1])} if row else {'ids':[],'valid':False}
    def finalize(self,principal,ids,eligible,on_saved=None):
        self.principal(principal)
        if not isinstance(ids,list) or not MIN_PICKS<=len(ids)<=MAX_PICKS or any(not isinstance(x,str) for x in ids) or len(set(ids))!=len(ids):
            raise ValueError(f'Select {MIN_PICKS} to {MAX_PICKS} different movies to finalize.')
        if not set(ids)<=set(eligible):raise ValueError('A selected movie is no longer eligible. Refresh your picks.')
        with closing(self.connect()) as db,db:
            db.execute('BEGIN IMMEDIATE')
            if on_saved is None or on_saved(db) is not False:
                db.execute('INSERT INTO movie_finalized VALUES(?,?,1,?) ON CONFLICT(principal) DO UPDATE SET ids=excluded.ids,valid=1,updated=excluded.updated',(principal,json.dumps(ids),int(time.time())))
        return {'ids':ids,'valid':True,'queued':False}

    def refill_requested(self,principal):
        self.principal(principal)
        with closing(self.connect()) as db:
            row=db.execute('SELECT requested FROM movie_refill_requests WHERE principal=?',(principal,)).fetchone()
        return row[0] if row else None
    def request_refill(self,principal,published_epoch,now):
        self.principal(principal)
        with closing(self.connect()) as db,db:
            row=db.execute('SELECT requested FROM movie_refill_requests WHERE principal=?',(principal,)).fetchone()
            if not row or row[0]<=published_epoch:
                db.execute('INSERT INTO movie_refill_requests VALUES(?,?) ON CONFLICT(principal) DO UPDATE SET requested=excluded.requested',(principal,now))

def rank_reviewed(rows,ratings,limit=VISIBLE_MOVIES):
    eligible=[r for r in rows if ratings.get(r['id'],{}).get('value') not in ('dislike','seen')]
    liked_tags=set();liked_genres=set()
    for rating in ratings.values():
        if rating['value']=='like':
            liked_tags.update(rating['metadata'].get('fitTags',[]));liked_genres.update(rating['metadata'].get('genres',[]))
    def score(row):
        liked=ratings.get(row['id'],{}).get('value')=='like'
        return (-int(liked),-len(set(row.get('fitTags',[]))&liked_tags),-len(set(row.get('genres',[]))&liked_genres))
    eligible=sorted(eligible,key=score) # preserve reviewed input order for ties
    result=[]
    for row in eligible[:limit]:
        value=ratings.get(row['id'],{}).get('value')
        result.append(dict(row,feedback=value,similarToLiked=bool(liked_tags & set(row.get('fitTags',[])))))
    return result

