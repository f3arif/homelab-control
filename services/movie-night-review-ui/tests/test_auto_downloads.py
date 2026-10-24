from contextlib import closing
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
import json
import sqlite3
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from uuid import uuid4
from test_downloads import Harness
from movie_night import ApprovalStore,RESERVE

IDS=['tt12345','tt12346','tt12347']


class AutoDownloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.h=Harness(self.tmp.name)
        self.net=patch('socket.create_connection',side_effect=AssertionError('real network forbidden'));self.net.start()
        self.h.controller.enable_auto_downloads()
        self.release=threading.Event()
    def tearDown(self):
        self.release.set();self.h.close();self.net.stop();self.tmp.cleanup()
    def finalize(self,**changes):
        data=dict(ids=IDS,startDownloads=True,requestId=str(uuid4()));data.update(changes)
        return self.h.post('finalize',data)
    def settle(self):
        q=self.h.controller.auto_downloads
        end=time.monotonic()+6
        while time.monotonic()<end:
            rows=q.requests('fixture')
            if not any(r['state'] in ('queued','checking') for r in rows):break
            time.sleep(.01)
        else:self.fail('source queue did not finish')
        for f in list(self.h.controller.futures.values()):f.result(5)
        return self.h.controller.downloads('fixture')
    def count(self,table):
        with sqlite3.connect(self.h.db) as db:return db.execute('SELECT COUNT(*) FROM '+table).fetchone()[0]
    def test_old_picks_reads_and_activation_never_enqueue(self):
        self.h.client.get('/movie-night');state=self.h.client.get('/movie-night/api/shortlist').json()
        self.assertTrue(state['autoDownloads']);self.assertEqual(IDS,state['finalized']['ids'])
        self.assertEqual([],state['downloadRequestedIds']);self.assertEqual(0,self.count('movie_download_queue'))
        self.assertEqual(0,self.h.provider.resolves)
    def test_finalize_queues_and_downloads_without_manual_approval(self):
        self.assertEqual(200,self.finalize().status_code);result=self.settle()
        self.assertEqual(3,len(result['requests']));self.assertEqual(1,len(result['jobs']))
        self.assertTrue(result['jobs'][0]['indexed']);self.assertEqual(1,self.h.provider.resolves)
        with sqlite3.connect(self.h.db) as db:
            payload=json.loads(db.execute('SELECT payload FROM jobs').fetchone()[0])
            self.assertEqual('finalize-and-download',payload['authorization'])
            self.assertEqual('fixture',payload['authorizedBy'])
    def test_old_cached_page_cannot_silently_start_downloads(self):
        response=self.h.post('finalize',{'ids':IDS})
        self.assertEqual(409,response.status_code);self.assertIn('Reload Movie Night',response.text)
        self.assertEqual(0,self.count('movie_download_queue'))
    def test_bad_counts_ids_and_token_start_nothing(self):
        for ids in ([],IDS[:2],IDS+['tt99999'],[IDS[0]]*3,IDS*4):
            self.assertEqual(409,self.finalize(ids=ids).status_code)
        self.assertEqual(403,self.h.client.post('/movie-night/api/finalize',json={'ids':IDS,'startDownloads':True}).status_code)
        self.assertEqual(0,self.count('movie_download_queue'))
    def test_failed_enqueue_rolls_back_finalized_selection(self):
        response=self.finalize(ids=IDS[::-1],requestId='bad')
        self.assertEqual(409,response.status_code)
        self.assertEqual(IDS,self.h.controller.feedback.saved('fixture')['ids'])
        self.assertEqual(0,self.count('movie_download_queue'))
    def test_duplicate_and_parallel_finalization_dispatch_once(self):
        key=str(uuid4());self.assertEqual(200,self.finalize(requestId=key).status_code)
        self.settle()
        with ThreadPoolExecutor(max_workers=4) as pool:
            results=list(pool.map(lambda _:self.finalize(requestId=key),range(4)))
        self.assertTrue(all(r.status_code==200 for r in results));self.finalize();self.settle()
        self.assertEqual(3,self.count('movie_download_queue'));self.assertEqual(1,self.count('jobs'))
        self.assertEqual(1,self.h.provider.resolves)
    def test_idempotency_key_cannot_be_rebound(self):
        key=str(uuid4());self.finalize(requestId=key);self.settle()
        self.assertEqual(409,self.finalize(ids=IDS[::-1],requestId=key).status_code)
        self.assertEqual(IDS,self.h.controller.feedback.saved('fixture')['ids'])
    def test_late_replay_preserves_newer_saved_order(self):
        key=str(uuid4());self.finalize(requestId=key);self.settle()
        self.finalize(ids=IDS[::-1]);self.settle()
        self.finalize(requestId=key);self.settle()
        self.assertEqual(IDS[::-1],self.h.controller.feedback.saved('fixture')['ids'])
    def test_unavailable_is_visible_and_not_retried_by_reload_or_finalize(self):
        calls=[];self.h.controller.choices=lambda imdb:calls.append(imdb) or []
        self.finalize();result=self.settle();self.assertEqual(3,len(calls))
        self.assertEqual({'unavailable'},{r['state'] for r in result['requests']})
        self.h.client.get('/movie-night/api/downloads');self.finalize();self.settle()
        self.assertEqual(3,len(calls));self.assertEqual(0,self.h.provider.resolves)
    def test_explicit_retry_is_idempotent(self):
        self.h.controller.choices=lambda _:[];self.finalize();self.settle()
        self.h.controller.choices=lambda imdb:[self.h.choice] if imdb==IDS[0] else []
        key=str(uuid4());self.finalize(retryDownloads=[IDS[0]],requestId=key);self.settle()
        self.finalize(retryDownloads=[IDS[0]],requestId=key);self.settle()
        self.assertEqual(1,self.h.provider.resolves);self.assertEqual(1,self.count('jobs'))
    def test_cancel_source_check_prevents_transfer_and_is_owner_bound(self):
        entered=threading.Event()
        def choices(imdb):
            if imdb==IDS[0]:entered.set();self.release.wait(5);return [self.h.choice]
            return []
        self.h.controller.choices=choices;self.finalize();self.assertTrue(entered.wait(2))
        q=self.h.controller.auto_downloads;r=next(r for r in q.requests('fixture') if r['imdb']==IDS[0])
        with self.assertRaises(PermissionError):q.cancel(r['id'],'other')
        self.assertEqual(200,self.h.post('cancel',{'requestId':r['id']}).status_code)
        self.release.set();self.settle();self.assertEqual(0,self.h.provider.resolves)
        self.assertEqual([],q.requests('other'))
        self.assertEqual('cancelled',next(r for r in q.requests('fixture') if r['imdb']==IDS[0])['state'])
    def test_cancel_linked_job_preserves_partial(self):
        self.h.slow=True;self.finalize();self.assertTrue(self.h.entered.wait(2))
        r=next(r for r in self.h.controller.auto_downloads.requests('fixture') if r['imdb']==IDS[0])
        self.assertEqual(200,self.h.post('cancel',{'requestId':r['id']}).status_code)
        self.h.block.set();result=self.settle();self.assertEqual('cancelled',result['jobs'][0]['state'])
        self.assertTrue(list(self.h.media.rglob('*.part')))
    def test_seen_during_lookup_stops_dispatch(self):
        entered=threading.Event()
        def choices(imdb):entered.set();self.release.wait(5);return [self.h.choice]
        self.h.controller.choices=choices;self.finalize();self.assertTrue(entered.wait(2))
        self.h.controller.rate('fixture',IDS[0],'seen');self.release.set();self.settle()
        self.assertEqual(0,self.h.provider.resolves);self.assertEqual(0,self.count('jobs'))
    def test_provider_change_and_private_error_sanitized(self):
        self.h.provider.changed=True;self.finalize();result=self.settle()
        self.assertEqual(0,self.count('jobs'));self.assertEqual(0,self.h.provider.resolves)
        self.assertIn('changed',next(r for r in result['requests'] if r['imdb']==IDS[0])['message'])
        def bad(_):raise RuntimeError('SECRET https://private.invalid/key')
        self.h.controller.choices=bad;self.finalize(retryDownloads=IDS);result=self.settle()
        self.assertNotIn('SECRET',json.dumps(result));self.assertNotIn('private.invalid',json.dumps(result))
    def test_low_space_and_existing_partial_never_transfer(self):
        self.h.controller.free=lambda:RESERVE;self.finalize();result=self.settle()
        self.assertIn('storage',next(r for r in result['requests'] if r['imdb']==IDS[0])['message'])
        self.h.controller.free=lambda:200_000_000_000
        p=self.h.media/'Movies';p.mkdir(exist_ok=True);(p/'tt12345.2024.mkv.part').write_bytes(b'keep')
        self.finalize(retryDownloads=[IDS[0]]);self.settle()
        self.assertEqual(b'keep',(p/'tt12345.2024.mkv.part').read_bytes());self.assertEqual(0,self.h.provider.resolves)
    def test_no_source_falls_back_only_after_explicit_finalization(self):
        calls=[];self.h.controller.choices=lambda _:[]
        def acquire(imdb,guard):
            calls.append(imdb);guard(self.h.choice.size)
            return self.h.choice if imdb==IDS[0] else None
        self.h.controller.auto_downloads.acquire=acquire
        self.h.controller.review('fixture');self.assertEqual([],calls)
        self.finalize();self.settle();self.assertEqual(IDS,calls);self.assertEqual(1,self.h.provider.resolves)
    def test_recovery_only_resumes_previously_queued_requests(self):
        q=self.h.controller.auto_downloads
        with patch.object(q,'start'):self.finalize()
        self.assertEqual(0,self.h.provider.resolves);q.close()
        with sqlite3.connect(self.h.db) as db:db.execute("UPDATE movie_download_queue SET state='checking' WHERE imdb=?",(IDS[0],))
        self.h.controller.enable_auto_downloads();self.settle();self.assertEqual(1,self.h.provider.resolves)
        self.h.controller.auto_downloads.recover();self.settle();self.assertEqual(1,self.h.provider.resolves)
    def test_shutdown_during_source_check_is_recoverable(self):
        entered=threading.Event()
        def choices(imdb):
            if imdb==IDS[0]:entered.set();self.release.wait(5);return [self.h.choice]
            return []
        self.h.controller.choices=choices;self.finalize();self.assertTrue(entered.wait(2))
        q=self.h.controller.auto_downloads;q.closed=True;self.release.set();q.future.result(5);q.close()
        self.assertEqual('checking',next(r for r in q.requests('fixture') if r['imdb']==IDS[0])['state'])
        self.h.controller.enable_auto_downloads();self.settle();self.assertEqual(1,self.h.provider.resolves)
    def test_failed_transfer_is_preserved_without_automatic_retry(self):
        self.h.truncated=True;self.finalize();result=self.settle()
        self.assertEqual('failed',result['jobs'][0]['state']);self.assertFalse(result['requests'][-1]['canRetry'])
        self.finalize(retryDownloads=[IDS[0]]);self.settle();self.assertEqual(1,self.h.provider.resolves)
    def test_atomic_link_survives_missing_dispatch(self):
        with patch.object(self.h.controller.pool,'submit') as submit:
            self.finalize()
            end=time.monotonic()+5
            while time.monotonic()<end and self.count('jobs')==0:time.sleep(.01)
            self.assertEqual(1,self.count('jobs'))
        # Simulate crash after DB commit but before dispatch, then recover once.
        self.h.controller.futures.clear();self.h.controller.recover_jobs();self.settle()
        self.assertEqual(1,self.h.provider.resolves)
    def test_disabled_downloads_reject_finalize(self):
        self.h.controller.enabled=False
        self.assertEqual(409,self.finalize().status_code);self.assertEqual(0,self.count('movie_download_queue'))


if __name__=='__main__':unittest.main()
