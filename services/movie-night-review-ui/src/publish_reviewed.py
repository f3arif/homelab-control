"""Local atomic weekly publisher. No network, acquisition, service or preference writes."""
import argparse
from contextlib import closing
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import tempfile
import time
from urllib.parse import urlsplit
from movie_night import shortlist, excluded_genres
from trailer_policy import reviewed_trailer
from discovery_policy import screened
from seen_policy import SeenPolicy, canonical_id, KNOWN_SEEN_IDS

MAX_BYTES=262144
DEFAULT_STATE='/home/coolyo/afz-stremio-secondhost-20260918/state/movie-night-review'

def read_json(path):
    raw=Path(path).read_bytes()
    if len(raw)>MAX_BYTES:raise ValueError('JSON too large')
    data=json.loads(raw)
    if not isinstance(data,dict):raise ValueError('Object required')
    return raw,data

def validate_rows(payload,now,minimum=10,max_age=86400):
    generated=payload.get('generatedEpoch')
    if type(generated) is not int or not 0<=now-generated<=max_age:
        raise ValueError('Input must be reviewed within the past 24 hours')
    rows=payload.get('movies')
    if not isinstance(rows,list) or not minimum<=len(rows)<=100:raise ValueError('Supply 10–100 reviewed candidates')
    seen_ids=payload.get('knownSeenIds',[])
    if not isinstance(seen_ids,list) or any(canonical_id({'id':x})!=x for x in seen_ids):raise ValueError('Canonical knownSeenIds required')
    ids=set()
    for row in rows:
        if not isinstance(row,dict):raise ValueError('Movie object required')
        imdb=canonical_id(row)
        if not imdb or row.get('id')!=imdb or imdb in ids:raise ValueError('Unique canonical movie IDs required')
        ids.add(imdb)
        if row.get('trailer') is not None and reviewed_trailer(row['trailer'],imdb) is None:raise ValueError('Invalid reviewed official trailer')
        for key,limit in [('name',160),('synopsis',450),('intensityGuide',240)]:
            if not isinstance(row.get(key),str) or not 1<=len(row[key])<=limit:raise ValueError('Missing or oversized '+key)
        if not isinstance(row.get('genres'),list) or not 1<=len(row['genres'])<=10 or any(not isinstance(g,str) or not 1<=len(g)<=40 for g in row['genres']):raise ValueError('Genres required')
        sources=row.get('sources',[])
        if not isinstance(sources,list) or not 1<=len(sources)<=5:raise ValueError('Source-backed review required')
        for source in sources:
            if not isinstance(source,str):raise ValueError('Invalid source link')
            url=urlsplit(source)
            if url.scheme!='https' or not url.hostname or url.username or url.password or url.query or url.fragment:raise ValueError('Plain HTTPS source links required')
        if excluded_genres(row):raise ValueError('Drama and Comedy genres are excluded, including mixed genres')
        # Reject malformed policy fields; intentionally excluded seen/high-scare entries may be omitted.
        if not screened(row,now) and (type(row.get('year')) is not int or row['year']<2016 or row.get('intensityReviewed') is not True or row.get('intenseSupernatural') is not False or row.get('scareLevel') not in ('low','moderate')):
            raise ValueError('Outside reviewed 2016+ low/moderate policy')
        if not set(row.get('fitTags',[])) & {'obsession','relationship tension','twists','suspense'}:raise ValueError('Preference fit required')
    return rows,set(seen_ids)

def preference_snapshot(db):
    with closing(sqlite3.connect('file:'+str(db)+'?mode=ro',uri=True,timeout=5)) as con:
        con.execute('BEGIN')
        ratings=con.execute('SELECT imdb,value FROM movie_feedback WHERE principal=?',('billing-owner',)).fetchall()
        saved=con.execute('SELECT ids FROM movie_finalized WHERE principal=?',('billing-owner',)).fetchone()
    return {i for i,v in ratings if v=='like'} | set(json.loads(saved[0]) if saved else []), {i for i,v in ratings if v in ('dislike','seen')}

def publish(state,input_path,expected_hash,dry_run=False,now=None,*,refill=False):
    now=int(time.time()) if now is None else now
    state=Path(state)
    info=state.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode & 0o077:raise ValueError('Private owned state directory required')
    target=state/'reviewed-shortlist.json'
    if target.is_symlink():raise ValueError('Symlink target rejected')
    _,incoming=read_json(input_path);rows,new_seen=validate_rows(incoming,now,minimum=1 if refill else 10,max_age=7*86400 if refill else 86400)
    # Separate publishers serialize; the live reader always sees complete old/new JSON.
    with (state/'.publisher.lock').open('a') as lock, closing(sqlite3.connect('file:'+str(state/'preferences.sqlite3')+'?mode=ro',uri=True,timeout=5)) as guard_db:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if guard_db.execute('PRAGMA journal_mode').fetchone()[0] not in ('delete','truncate','persist'):
            raise ValueError('Unsupported preference journal; no publication performed')
        guard_db.execute('BEGIN')
        guard_db.execute('SELECT count(*) FROM movie_feedback').fetchone()
        original,current=read_json(target)
        if hashlib.sha256(original).hexdigest()!=expected_hash:raise ValueError('Shortlist changed; inspect before publishing')
        retained,disliked=preference_snapshot(state/'preferences.sqlite3')
        known=set(current.get('knownSeenIds',[])) | new_seen | set(KNOWN_SEEN_IDS)
        known.update(canonical_id(r) for r in current.get('movies',[])+rows if r.get('seen') is True)
        known.discard(None)
        incoming_ids={r['id'] for r in rows}
        # Keep eligible existing choices, never re-add a disliked or known-seen title.
        carry=[r for r in current.get('movies',[])+current.get('retainedIneligibleSelections',[]) if canonical_id(r) in retained and canonical_id(r) not in incoming_ids]
        merged=rows+carry
        policy=SeenPolicy(lambda:{'states':{i:True for i in known},'complete':False})
        eligible={r['id'] for r in shortlist({'generatedEpoch':now,'movies':merged},now,policy,limit=None)}
        accepted=[r for r in merged if canonical_id(r) in eligible and canonical_id(r) not in disliked]
        if len(accepted)<(1 if refill else 10):raise ValueError('Fewer than 10 eligible candidates after exclusions; add reviewed reserves')
        payload={'generatedEpoch':incoming['generatedEpoch'],'publishedEpoch':time.time() if refill else now,'movies':accepted,'knownSeenIds':sorted(known),
                 'publishedHistoryIds':sorted(set(current.get('publishedHistoryIds',[])) | {r['id'] for r in current.get('movies',[])} | {r['id'] for r in accepted}),
                 'seenCoverage':'Known exclusions only; complete history is not available.',
                 'retainedSelectionIds':sorted(retained & eligible - disliked),
                 'excludedGenres':['Drama','Comedy'],
                 'retainedIneligibleSelections':[r for r in merged if canonical_id(r) in retained and excluded_genres(r)]}
        data=(json.dumps(payload,ensure_ascii=False,indent=2)+'\n').encode()
        if len(data)>MAX_BYTES:raise ValueError('Published JSON too large')
        receipt={'dryRun':dry_run,'eligiblePool':len(accepted),'reservesAtFiveVisible':max(0,len(accepted)-5),'retainedSelections':len(retained & eligible - disliked),'previousSha256':expected_hash,'sha256':hashlib.sha256(data).hexdigest(),'preferencesWritten':False,'downloadsEnabled':False}
        if dry_run:return receipt
        # Recheck feedback so a concurrent selection cannot be omitted by publication.
        if preference_snapshot(state/'preferences.sqlite3')!=(retained,disliked):raise ValueError('Preferences changed; retry publication after review')
        if hashlib.sha256(target.read_bytes()).hexdigest()!=expected_hash:raise ValueError('Concurrent shortlist write')
        backups=state/'publication-backups';backups.mkdir(mode=0o700,exist_ok=True)
        backup=backups/(expected_hash+'.json')
        if not backup.exists():
            with backup.open('xb') as stream:stream.write(original)
        fd,temp=tempfile.mkstemp(prefix='.reviewed-',dir=state)
        try:
            with os.fdopen(fd,'wb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
            os.replace(temp,target)
            folder=os.open(state,os.O_RDONLY|os.O_DIRECTORY)
            try:os.fsync(folder)
            finally:os.close(folder)
        finally:
            if os.path.exists(temp):os.unlink(temp)
        return receipt

def inspect_state(state):
    state=Path(state)
    raw,payload=read_json(state/'reviewed-shortlist.json')
    with closing(sqlite3.connect('file:'+str(state/'preferences.sqlite3')+'?mode=ro',uri=True)) as db:
        ratings=[{'id':r[0],'value':r[1],'metadata':json.loads(r[2])} for r in db.execute('SELECT imdb,value,metadata FROM movie_feedback WHERE principal=?',('billing-owner',))]
        saved=db.execute('SELECT ids,valid FROM movie_finalized WHERE principal=?',('billing-owner',)).fetchone()
        has_requests=db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='movie_refill_requests'").fetchone()
        request=db.execute('SELECT requested FROM movie_refill_requests WHERE principal=?',('billing-owner',)).fetchone() if has_requests else None
    return {'currentSha256':hashlib.sha256(raw).hexdigest(),'ratings':ratings,'finalizedIds':json.loads(saved[0]) if saved else [],
            'knownSeenIds':sorted(set(payload.get('knownSeenIds',[]))|set(KNOWN_SEEN_IDS)),
            'refillPending':bool(request and request[0]>payload.get('publishedEpoch',0)),
            'poolCount':len(payload.get('movies',[])),'generatedEpoch':payload.get('generatedEpoch')}

def main():
    os.umask(0o077)
    parser=argparse.ArgumentParser()
    parser.add_argument('--state',default=DEFAULT_STATE)
    parser.add_argument('--input')
    parser.add_argument('--inspect',action='store_true')
    parser.add_argument('--expected-sha256')
    parser.add_argument('--dry-run',action='store_true')
    args=parser.parse_args()
    if not args.inspect and (not args.input or not args.expected_sha256):parser.error('--input and --expected-sha256 are required for publishing')
    try:result=inspect_state(args.state) if args.inspect else publish(args.state,args.input,args.expected_sha256,args.dry_run)
    except (ValueError,OSError,sqlite3.Error) as exc:raise SystemExit('Publication stopped: '+str(exc))
    print(json.dumps(result,sort_keys=True))
if __name__=='__main__':main()
