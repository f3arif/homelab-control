"""Boundary and outage tests; no server, provider or download requests."""
import copy
import os
import re
import threading
import time
import types
import unittest
from unittest.mock import Mock, patch
from prepare_nuvio_landing_playback import HELPERS

class RequestError(Exception): pass
class RequestTimeout(RequestError): pass

ROOT='/srv/media/landing'
ITEM={'Id':'a'*32,'Type':'Movie','Name':'Existing movie','ProductionYear':2020,
      'Path':ROOT+'/Existing movie/file.mkv','ProviderIds':{'Imdb':'tt123'},
      'MediaSources':[{'Path':ROOT+'/Existing movie/file.mkv','IsRemote':False,
                       'Protocol':'File','Container':'mkv','Size':2000000}]}

class LandingTests(unittest.TestCase):
    def setUp(self):
        self.env=patch.dict(os.environ,{'AFZ_HP_JELLYFIN_ENABLED':'1','AFZ_HP_JELLYFIN_MOVIE_ROOT':ROOT})
        self.env.start(); self.addCleanup(self.env.stop)
        self.response=Mock(status_code=206,headers={'Content-Range':'bytes 0-0/2000000'})
        self.response.__enter__=Mock(return_value=self.response)
        self.response.__exit__=Mock(return_value=False)
        self.response.iter_content=Mock(return_value=iter([b'x']))
        self.request=Mock(return_value=self.response)
        self.ns={'os':os,'re':re,'threading':threading,'time':time,
                 'requests':types.SimpleNamespace(get=self.request,RequestException=RequestError),
                 'VIDEO_EXTS':{'.mkv','.mp4'},'jf_api_lock':threading.Lock(),
                 'jf_api_cache':{},'JELLYFIN_URL':'http://trusted.example',
                 'PUBLIC_BASE':'https://addon.example',
                 'jellyfin_headers':lambda:{'Authorization':'private-test-token'},
                 'jellyfin_movie_index':lambda **kw:{'tt123':[copy.deepcopy(ITEM)]}}
        exec(HELPERS,self.ns)

    def available(self,item=None):
        return self.ns['jellyfin_remote_movie_available'](copy.deepcopy(ITEM if item is None else item))

    def test_exact_file_is_probed_once_and_response_closed(self):
        self.assertTrue(self.available()); self.assertTrue(self.available())
        self.assertEqual(self.request.call_count,1)
        args,kw=self.request.call_args
        self.assertEqual(args[0],'http://trusted.example/Videos/'+'a'*32+'/stream')
        self.assertFalse(kw['allow_redirects']); self.assertTrue(kw['stream'])
        self.assertEqual(kw['headers']['Range'],'bytes=0-0')
        self.response.__exit__.assert_called_once()

    def test_root_boundaries_and_traversal_fail_without_network(self):
        for path in ['/srv/media/landing-other/file.mkv',ROOT+'/../secret.mkv',
                     'https://elsewhere/file.mkv',ROOT+'/x\\y.mkv']:
            with self.subTest(path=path):
                x=copy.deepcopy(ITEM); x['Path']=path; x['MediaSources'][0]['Path']=path
                self.assertFalse(self.available(x))
        self.request.assert_not_called()

    def test_remote_sources_placeholders_and_invalid_types_rejected(self):
        for field,value in [('IsRemote',True),('IsRemote',None),('Protocol','Http'),
                            ('Container','strm'),('Size',512),('Path','/elsewhere/file.mkv')]:
            with self.subTest(field=field):
                x=copy.deepcopy(ITEM); x['MediaSources'][0][field]=value
                self.assertFalse(self.available(x))
        for field,value in [('Id','../../etc/passwd'),('Type','Episode'),('Path',ROOT+'/file.strm')]:
            x=copy.deepcopy(ITEM); x[field]=value; self.assertFalse(self.available(x))
        self.request.assert_not_called()

    def test_missing_opt_in_and_broad_root_rejected(self):
        for key,val in [('AFZ_HP_JELLYFIN_ENABLED','0'),('AFZ_HP_JELLYFIN_MOVIE_ROOT',''),
                        ('AFZ_HP_JELLYFIN_MOVIE_ROOT','/'),('AFZ_HP_JELLYFIN_MOVIE_ROOT','/srv/../media')]:
            with patch.dict(os.environ,{key:val}): self.assertFalse(self.available())
        self.request.assert_not_called()

    def test_non_range_and_redirect_responses_fail(self):
        for status in [200,302,401,404,503]:
            self.ns['jf_api_cache'].clear(); self.response.status_code=status
            self.assertFalse(self.available())
        self.response.iter_content.assert_not_called()

    def test_changed_size_or_empty_body_rejected(self):
        self.response.headers['Content-Range']='bytes 0-0/1000'
        self.assertFalse(self.available())
        self.ns['jf_api_cache'].clear()
        self.response.headers['Content-Range']='bytes 0-0/2000000'
        self.response.iter_content.return_value=iter([])
        self.assertFalse(self.available())

    def test_outage_fails_closed_and_failure_is_cached(self):
        self.request.side_effect=RequestTimeout()
        self.assertFalse(self.available()); self.assertFalse(self.available())
        self.assertEqual(self.request.call_count,1)

    def test_no_credential_means_no_probe(self):
        self.ns['jellyfin_headers']=lambda:{}
        self.assertFalse(self.available()); self.request.assert_not_called()

    def test_catalog_uses_exact_identity_and_no_credential_urls(self):
        rows=self.ns['jellyfin_landing_movie_catalog']()
        self.assertEqual(len(rows),1); self.assertEqual(rows[0]['id'],'tt123')
        self.assertEqual(rows[0]['type'],'movie')
        self.assertNotIn('private-test-token',str(rows)); self.assertNotIn(ROOT,str(rows))

if __name__=='__main__': unittest.main()
