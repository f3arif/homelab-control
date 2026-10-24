"""Fulfill owner requests from a finite, pre-reviewed local bank. No network or DB writes."""
import hashlib,json,os,sqlite3,tempfile,time
from pathlib import Path
from publish_reviewed import read_json,validate_rows,publish,preference_snapshot
from movie_night import shortlist, excluded_genres

class ReviewedRefill:
    def __init__(self,state):self.state=Path(state)
    def candidates(self):
        now=int(time.time())
        raw,current=read_json(self.state/'reviewed-shortlist.json')
        _,bank=read_json(self.state/'reviewed-refill-bank.json')
        # Keep eligible reserves usable after an owner changes genre preferences.
        if isinstance(bank.get('movies'),list):bank=dict(bank,movies=[r for r in bank['movies'] if not excluded_genres(r)])
        rows,known=validate_rows(bank,now,minimum=1,max_age=7*86400)
        _,disliked=preference_snapshot(self.state/'preferences.sqlite3')
        used=set(current.get('publishedHistoryIds',[])) | {r['id'] for r in current.get('movies',[])}
        seen=known | set(current.get('knownSeenIds',[]))
        eligible={r['id'] for r in shortlist(dict(bank,knownSeenIds=sorted(seen)),now,limit=None)}
        fresh=[r for r in rows if r['id'] in eligible-used-disliked]
        return raw,current,bank,fresh,disliked,seen
    def status(self):
        try:return {'available':len(self.candidates()[3]),'supply':'finite-reviewed-bank'}
        except (OSError,ValueError,sqlite3.Error):return {'available':0,'supply':'review-needed'}
    def fulfill(self,expected_hash=None):
        try:
            raw,current,bank,fresh,disliked,seen=self.candidates()
            if expected_hash and hashlib.sha256(raw).hexdigest()!=expected_hash:return {'fulfilled':False,'reason':'state-changed'}
            if not fresh:return {'fulfilled':False,'reason':'review-needed'}
            from feedback import FeedbackStore,rank_reviewed
            from contextlib import closing
            with closing(sqlite3.connect('file:'+str(self.state/'preferences.sqlite3')+'?mode=ro',uri=True)) as db:
                ratings={i:{'value':v,'metadata':json.loads(m)} for i,v,m in db.execute('SELECT imdb,value,metadata FROM movie_feedback WHERE principal=?',('billing-owner',))}
            ordered=rank_reviewed(fresh,ratings,limit=len(fresh));order={r['id']:i for i,r in enumerate(ordered)}
            fresh.sort(key=lambda r:order[r['id']])
            now=int(time.time())
            eligible={r['id'] for r in shortlist(current,now,limit=None)}-disliked-seen
            keep=[r for r in current.get('movies',[]) if r['id'] in eligible]
            # Fill five cards when depleted, otherwise add a five-title reserve batch.
            count=max(1,5-len(keep)) if len(keep)<5 else 5
            incoming={'generatedEpoch':now, # continuous refill keeps the shortlist fresh
                      'knownSeenIds':sorted(seen),'movies':keep+fresh[:count]}
            fd,name=tempfile.mkstemp(prefix='.refill-input-',dir=self.state)
            try:
                with os.fdopen(fd,'w') as stream:json.dump(incoming,stream)
                receipt=publish(self.state,name,hashlib.sha256(raw).hexdigest(),refill=True)
            finally:os.unlink(name)
            return dict(receipt,fulfilled=True,added=len(fresh[:count]))
        except (OSError,ValueError,sqlite3.Error):
            # Keep the request pending and preferences intact; permit a later retry.
            return {'fulfilled':False,'reason':'review-needed'}
