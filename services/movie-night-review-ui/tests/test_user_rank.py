"""Owner ranking: additive, ordering-only; never starts, deletes or rewrites picks."""
import json, sqlite3, tempfile, unittest
from unittest.mock import patch
from test_downloads import Harness
from feedback import by_rank

IDS=['tt12345','tt12346','tt12347']


class ByRankTests(unittest.TestCase):
    def test_ranked_first_unranked_keep_order(self):
        self.assertEqual(['c','a','b','d'],by_rank(['a','b','c','d'],['c','x']))
        self.assertEqual(['a','b'],by_rank(['a','b'],[]))


class UserRankTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.h=Harness(self.tmp.name)
        self.net=patch('socket.create_connection',side_effect=AssertionError('no network'));self.net.start()
    def tearDown(self):
        self.h.close();self.net.stop();self.tmp.cleanup()

    def test_rank_orders_finalized_without_changing_selection(self):
        before=self.h.controller.feedback.saved('fixture')
        r=self.h.post('rank',{'ids':['tt12347','tt12345']})
        self.assertEqual(200,r.status_code)
        data=r.json()
        self.assertEqual(['tt12347','tt12345','tt12346'],data['finalized']['ids'])
        self.assertEqual(['tt12347','tt12345','tt12346'],[m['id'] for m in data['finalized']['movies']])
        self.assertTrue(data['finalized']['valid'])
        self.assertEqual(before,self.h.controller.feedback.saved('fixture'))  # stored picks untouched
        self.assertEqual(['tt12347','tt12345'],data['rank'])

    def test_rerank_keeps_other_ranked_titles_after(self):
        self.h.post('rank',{'ids':['tt12347','tt12345','tt12346']})
        self.h.post('rank',{'ids':['tt12346']})
        self.assertEqual(['tt12346','tt12347','tt12345'],self.h.controller.feedback.rank('fixture'))

    def test_invalid_rank_rejected_and_csrf_required(self):
        for ids in (None,[],['bad'],['tt12345','tt12345'],'tt12345'):
            self.assertEqual(409,self.h.post('rank',{'ids':ids}).status_code)
        self.assertEqual(403,self.h.client.post('/movie-night/api/rank',json={'ids':IDS}).status_code)
        self.assertEqual([],self.h.controller.feedback.rank('fixture'))

    def test_ready_catalog_follows_rank(self):
        metas=[{'id':i,'type':'movie','name':i,'releaseInfo':'2024'} for i in IDS]
        with patch.object(self.h.index,'metas',return_value=metas):
            self.assertEqual(IDS,[m['id'] for m in self.h.client.get('/movie-night/catalog/movie/downloaded.json').json()['metas']])
            self.h.post('rank',{'ids':['tt12346']})
            self.assertEqual(['tt12346','tt12345','tt12347'],[m['id'] for m in self.h.client.get('/movie-night/catalog/movie/downloaded.json').json()['metas']])

    def test_rank_table_is_additive(self):
        with sqlite3.connect(self.h.db) as db:
            tables={r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertTrue({'movie_feedback','movie_finalized','movie_rank'}<=tables)


class QueueRankTests(unittest.TestCase):
    def test_queue_drains_in_rank_order(self):
        tmp=tempfile.TemporaryDirectory();h=Harness(tmp.name)
        try:
            h.controller.feedback.set_rank('fixture',['tt12347','tt12346'])
            h.controller.enable_auto_downloads()
            q=h.controller.auto_downloads
            order=[]
            q.start=lambda:None
            with sqlite3.connect(h.db) as db:
                q.enqueue(db,'fixture',IDS,{i:{'name':i} for i in IDS},'r'*20,[])
            real=q._active
            def spy(rid,principal,imdb):
                order.append(imdb);raise ValueError('stop')
            q._active=spy
            q._drain()
            self.assertEqual(['tt12347','tt12346','tt12345'],order)
        finally:
            h.close();tmp.cleanup()


if __name__=='__main__':unittest.main()
