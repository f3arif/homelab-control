"""Selection boundary regression using disposable preferences and provider only."""
import re
import tempfile
import unittest
from test_downloads import Harness


class PickLimits(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.h=Harness(self.tmp.name)
        template=self.h.payload['movies'][0]
        self.h.payload['movies'].extend(dict(template,id='tt'+str(12348+i),name='Fixture Extra '+str(i)) for i in range(8))
        self.ids=[row['id'] for row in self.h.payload['movies']]

    def tearDown(self):
        self.h.close();self.tmp.cleanup()

    def test_three_four_five_and_ten_finalize_and_survive_readback(self):
        for count in (3,4,5,10):
            with self.subTest(count=count):
                response=self.h.post('finalize',{'ids':self.ids[:count]})
                self.assertEqual(200,response.status_code)
                state=self.h.client.get('/movie-night/api/shortlist').json()
                self.assertEqual(self.ids[:count],state['finalized']['ids'])
                self.assertTrue(state['finalized']['valid'])
                self.assertEqual([],self.h.controller.downloads('fixture')['jobs'])
        self.assertEqual(0,self.h.provider.resolves)

    def test_invalid_counts_and_duplicates_preserve_saved_selection(self):
        self.h.post('finalize',{'ids':self.ids[:10]})
        for ids in ([],self.ids[:2],self.ids,self.ids[:9]+[self.ids[0]]):
            with self.subTest(ids=ids):
                self.assertEqual(409,self.h.post('finalize',{'ids':ids}).status_code)
                self.assertEqual(self.ids[:10],self.h.controller.review('fixture')['finalized']['ids'])

    def test_same_limits_reach_html_and_api_and_ten_cards(self):
        html=self.h.client.get('/movie-night').text
        self.assertIn('name="mn-min-picks" content="3"',html)
        self.assertIn('name="mn-max-picks" content="10"',html)
        self.assertNotIn('__MAX_PICKS__',html)
        state=self.h.client.get('/movie-night/api/shortlist').json()
        self.assertEqual({'min':3,'max':10,'visible':10},state['selectionLimits'])
        self.assertEqual(10,len(state['movies']));self.assertEqual(1,state['reserveCount'])

    def test_tenth_finalized_title_can_reach_download_review_gate(self):
        self.h.post('finalize',{'ids':self.ids[:10]})
        self.h.controller.require_finalized(self.ids[9],'fixture')
        with self.assertRaises(ValueError):self.h.controller.require_finalized(self.ids[10],'fixture')
        self.assertEqual(0,self.h.provider.resolves)

    def test_seen_still_excluded_at_higher_limit(self):
        self.h.controller.rate('fixture',self.ids[9],'seen')
        self.assertEqual(409,self.h.post('finalize',{'ids':self.ids[:10]}).status_code)
        self.assertNotIn(self.ids[9],self.h.controller.review('fixture')['eligibleIds'])

    def test_higher_limit_still_requires_csrf(self):
        self.assertEqual(403,self.h.client.post('/movie-night/api/finalize',json={'ids':self.ids[:10]},headers={'Origin':'http://testserver'}).status_code)


if __name__=='__main__':unittest.main()
