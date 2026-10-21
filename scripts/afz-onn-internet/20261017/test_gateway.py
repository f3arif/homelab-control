import io
import json
import threading
import unittest
import urllib.error
import urllib.request
from email.message import Message
from gateway import ADDON_ID,Gateway,route_kind,make_server

TOKEN='a'*43
UP='https://desktop-h3r6cqn.tailc9bb62.ts.net:8445'
ORIGIN='https://afz-zbook.tailc9bb62.ts.net:10000'
URL=UP+'/external-stream/tt0098904%3A3%3A11/'+'b'*28
class Reply(io.BytesIO):
    def __init__(self,body,status=200,headers=None):
        super().__init__(body)
        self.status=status
        self.headers=Message()
        for k,v in (headers or {}).items():self.headers[k]=str(v)

class Opener:
    def __init__(self):
        self.requests=[]
        self.fail=False
        self.location=None
    def open(self,req,timeout=None):
        self.requests.append(req)
        if self.fail:raise urllib.error.URLError('private-url-or-key-must-not-leak')
        if self.location:return Reply(b'',307,{'Location':self.location})
        if '/manifest.json' in req.full_url:
            return Reply(json.dumps({'id':'original','name':'Original','version':'1',
             'types':['movie','series'],'resources':['catalog','meta','stream'],
             'catalogs':[{'type':'movie','id':'afz_local_ready','name':'AFZ Local'}],
             'configurationUrl':UP+'/manage','logo':UP+'/art/logo/afz.png'}).encode())
        if '/stream/' in req.full_url:
            return Reply(json.dumps({'streams':[{'name':'Valid','url':URL},
                {'name':'Admin','externalUrl':UP+'/manage'},
                {'name':'Private','url':'http://100.71.26.69:8096/video'},
                {'name':'Unsafe AFZ path','url':UP+'/manage'}]}).encode())
        r=req.get_header('Range')
        if r:
            return Reply(b'VIDEO',206,{'Content-Type':'video/x-matroska',
                'Content-Length':5,'Content-Range':'bytes 10-14/100','Accept-Ranges':'bytes'})
        return Reply(b'VIDEO',200,{'Content-Type':'video/x-matroska','Content-Length':5})

class PureTests(unittest.TestCase):
    def setUp(self):self.g=Gateway(TOKEN,ORIGIN)
    def test_loopback_fetch_keeps_afz_asset_rewrite(self):
        g=Gateway(TOKEN,ORIGIN,upstream='http://127.0.0.1:18774')
        self.assertEqual(g.rewrite_url(URL),g.base+URL[len(UP):])
    def test_loopback_fetch_can_rewrite_art(self):
        g=Gateway(TOKEN,ORIGIN,upstream='http://127.0.0.1:18774')
        self.assertEqual(g.rewrite_url(UP+'/art/poster/tt0098904.jpg'),
                         g.base+'/art/poster/tt0098904.jpg')
    def test_valid_media(self):self.assertEqual(route_kind('/external-stream/tt0098904%3A3%3A11/'+'b'*28),'media')
    def test_art_revision_query_allowed(self):
        self.assertEqual(route_kind('/art/poster/tt0098904.jpg?media=series&rev=poster-v3'),'art')
    def test_art_url_query_override_denied(self):
        self.assertIsNone(route_kind('/art/poster/tt0098904.jpg?url=https://localhost'))
    def test_art_url_keeps_revision(self):
        url=UP+'/art/poster/tt0098904.jpg?media=series&rev=poster-v3'
        self.assertEqual(self.g.rewrite_url(url),self.g.base+url[len(UP):])
    def test_valid_genre_extra(self):self.assertEqual(route_kind('/catalog/movie/afz_for_you/genre=Science%20Fiction&skip=20.json'),'json')
    def test_control_routes_denied(self):
        for p in ['/manage','/api/state','/queue','/external-resolve','/configure']:
            self.assertIsNone(route_kind(p))
    def test_traversal_denied(self):
        for p in ['/art/poster/../x.jpg','/art/poster/%2e%2e/x.jpg',
                  '/art/poster/%252e%252e/x.jpg','/art/poster/x%00.jpg','/art/poster/a\\b.jpg']:
            self.assertIsNone(route_kind(p))
    def test_non_ascii_token_is_rejected(self):
        self.assertIsNone(self.g.authorize('/snowman-\u2603/manifest.json'))
    def test_redirect_control_characters_rejected(self):
        self.assertEqual(self.g.rewrite_url('https://cdn.example/file\r\nX-Test:yes'),'')
    def test_unknown_token_rejected(self):
        self.assertIsNone(self.g.authorize('/wrong/manifest.json'))
        self.assertIsNone(self.g.authorize('/manifest.json'))
    def test_query_url_cannot_override_upstream(self):
        self.assertIsNone(self.g.authorize('/'+TOKEN+'/manifest.json?url=http://localhost'))
    def test_bad_private_and_http_urls_removed(self):
        for u in ['http://example.com/video','https://100.71.26.69/video',
                  'https://127.0.0.1/video','https://localhost/video','https://other.ts.net/video',
                  'https://user:pass@public.example/file']:
            self.assertEqual(self.g.rewrite_url(u),'')
    def test_afz_stream_urls_rewritten(self):
        self.assertEqual(self.g.rewrite_url(URL),self.g.base+URL[len(UP):])
    def test_afz_admin_url_removed(self):
        self.assertEqual(self.g.rewrite_url(UP+'/manage'),'')
    def test_public_artwork_retained(self):
        u='https://images.metahub.space/poster/medium/tt0098904/img'
        self.assertEqual(self.g.rewrite_url(u),u)
    def test_only_supported_types_are_advertised(self):
        obj=self.g.transform({'types':['movie','series','tv','sport']},True)
        self.assertEqual(obj['types'],['movie','series'])
    def test_only_supported_catalogs_are_advertised(self):
        obj=self.g.transform({'catalogs':[{'id':'m','type':'movie'},{'id':'s','type':'series'},{'id':'t','type':'tv'}]},True)
        self.assertEqual([x['id'] for x in obj['catalogs']],['m','s'])
    def test_manifest_has_distinct_identity(self):
        obj=self.g.transform({'id':'original','configurationUrl':UP+'/manage'},True)
        self.assertEqual(obj['id'],ADDON_ID)
        self.assertEqual(obj['name'],'AFZ Internet')
        self.assertNotIn('configurationUrl',obj)

class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.opener=Opener()
        cls.g=Gateway(TOKEN,ORIGIN,opener=cls.opener)
        cls.server=make_server('127.0.0.1',0,cls.g)
        cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True);cls.thread.start()
        cls.base='http://127.0.0.1:'+str(cls.server.server_address[1])
    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown();cls.server.server_close();cls.thread.join()
    def setUp(self):
        self.opener.requests.clear();self.opener.fail=False;self.opener.location=None
    def request(self,path='/manifest.json',method='GET',headers=None,auth=True):
        req=urllib.request.Request(self.base+('/'+TOKEN if auth else '')+path,
                                  method=method,headers=headers or {})
        try:return urllib.request.urlopen(req,timeout=3)
        except urllib.error.HTTPError as e:return e
    def test_anonymous_request_denied_before_upstream(self):
        with self.request(auth=False) as r:self.assertEqual(r.status,404)
        self.assertEqual(self.opener.requests,[])
    def test_post_is_not_forwarded(self):
        with self.request(method='POST') as r:self.assertEqual(r.status,404)
        self.assertEqual(self.opener.requests,[])
    def test_manifest_fetched_and_transformed(self):
        with self.request() as r:
            obj=json.load(r);self.assertEqual(obj['id'],ADDON_ID)
            self.assertEqual(r.headers['Access-Control-Allow-Origin'],'*')
        self.assertEqual(self.opener.requests[0].full_url,UP+'/manifest.json')
    def test_bad_streams_removed(self):
        with self.request('/stream/series/tt0098904%3A3%3A11.json') as r:
            obj=json.load(r);self.assertEqual(len(obj['streams']),1)
            self.assertTrue(obj['streams'][0]['url'].startswith(self.g.base+'/external-stream/'))
    def test_byte_range_preserved(self):
        with self.request(URL[len(UP):],headers={'Range':'bytes=10-14','Authorization':'must-not-forward'}) as r:
            self.assertEqual(r.status,206);self.assertEqual(r.read(),b'VIDEO')
            self.assertEqual(r.headers['Content-Range'],'bytes 10-14/100')
        req=self.opener.requests[0]
        self.assertEqual(req.get_header('Range'),'bytes=10-14')
        self.assertIsNone(req.get_header('Authorization'))
    def test_head_has_length_without_body(self):
        with self.request(URL[len(UP):],method='HEAD') as r:
            self.assertEqual(r.status,200);self.assertEqual(r.headers['Content-Length'],'5')
            self.assertEqual(r.read(),b'')
        self.assertEqual(self.opener.requests[0].get_method(),'HEAD')
    def test_source_outage_is_safe_502(self):
        self.opener.fail=True
        with self.request() as r:
            self.assertEqual(r.status,502);self.assertNotIn(b'private-url',r.read())
    def test_private_redirect_denied(self):
        self.opener.location='http://127.0.0.1/private'
        with self.request(URL[len(UP):]) as r:self.assertEqual(r.status,502)
    def test_cors_preflight_stays_local(self):
        with self.request(method='OPTIONS') as r:self.assertEqual(r.status,204)
        self.assertFalse(self.opener.requests)
    def test_install_page(self):
        with self.request('/setup') as r:
            body=r.read()
            self.assertIn(b'AFZ Internet',body)
            self.assertIn(b'stremio://afz-zbook',body)

if __name__=='__main__':
    unittest.main(verbosity=2)
