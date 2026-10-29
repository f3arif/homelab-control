"""Exercise the independent identity boundary through real HTTP and Unix sockets."""
import http.client
from http.server import BaseHTTPRequestHandler
import json
import os
from pathlib import Path
import socketserver
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'gateway'))
from standalone_server import MovieNightServer, exact_origin, load_owner

PUBLIC = 'https://movie.example.ts.net:8453'
BACKEND = 'https://movie.example.ts.net:8447'
OWNER = 'owner@example.test'


class Backend(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.reply()
    def do_POST(self): self.reply()
    def reply(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        self.server.received.append((self.command, self.path, dict(self.headers), body))
        status = 200
        if self.command == 'POST' and (self.headers.get('Origin') != BACKEND or self.headers.get('X-Movie-Night-CSRF') != 'valid-csrf'):
            status = 403
        payload = json.dumps({'ok': status == 200}).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers(); self.wfile.write(payload)


class AccessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name); cls.root.chmod(0o700)
        cls.socket = cls.root / 'review.sock'
        cls.backend = socketserver.UnixStreamServer(str(cls.socket), Backend)
        cls.socket.chmod(0o600); cls.backend.received = []
        cls.worker = threading.Thread(target=cls.backend.serve_forever, daemon=True); cls.worker.start()
        cls.server = MovieNightServer(PUBLIC, BACKEND, OWNER, 0, str(cls.socket))
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True); cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join()
        cls.backend.shutdown(); cls.backend.server_close(); cls.worker.join(); cls.temp.cleanup()

    def request(self, path='/movie-night/api/shortlist', method='GET', headers=None, body=None):
        values = [('Host', 'movie.example.ts.net:8453'), ('Tailscale-User-Login', OWNER)] if headers is None else headers
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=5)
        connection.putrequest(method, path, skip_host=True)
        for key, value in values: connection.putheader(key, value)
        if body is not None: connection.putheader('Content-Length', str(len(body)))
        connection.endheaders(body)
        response = connection.getresponse(); result = response.status, dict(response.getheaders()), response.read()
        connection.close(); return result

    def headers(self, **extra):
        return [('Host','movie.example.ts.net:8453'), ('Tailscale-User-Login',OWNER)] + list(extra.items())

    def test_owner_can_read_without_cookie(self):
        status, headers, _ = self.request()
        self.assertEqual(status, 200); self.assertNotIn('Set-Cookie', headers)
        self.assertIn('no-store', headers['Cache-Control'])

    def test_entry_and_login_return_to_movie_night(self):
        for path in ('/', '/login'):
            status, headers, _ = self.request(path)
            self.assertEqual((status, headers['Location']), (303, '/movie-night/'))

    def test_missing_or_different_identity_denied_even_with_billing_cookie(self):
        for identity in (None, 'other@example.test', OWNER + ',other@example.test'):
            headers = [('Host','movie.example.ts.net:8453'),('Cookie','afz_owner=anything'),('Authorization','Bearer anything')]
            if identity is not None: headers.append(('Tailscale-User-Login',identity))
            self.assertEqual(self.request(headers=headers)[0],403)

    def test_duplicate_identity_denied(self):
        self.assertEqual(self.request(headers=self.headers() + [('Tailscale-User-Login',OWNER)])[0],403)

    def test_billing_and_query_and_encoded_routes_unavailable(self):
        for path in ('/api/billing/snapshot','/app.js','/style.css','/movie-night/api/shortlist?x=1','/movie-night%2fapi/shortlist','/movie-night/../api/billing/snapshot'):
            self.assertEqual(self.request(path)[0],404, path)

    def test_billing_login_post_unavailable(self):
        self.assertEqual(self.request('/login','POST',self.headers(Origin=PUBLIC),b'x=1')[0],404)

    def test_host_and_duplicate_host_denied(self):
        for headers in ([('Host','wrong'),('Tailscale-User-Login',OWNER)], self.headers() + [('Host','movie.example.ts.net:8453')]):
            self.assertEqual(self.request(headers=headers)[0],403)

    def test_writes_require_exact_public_origin_before_translation(self):
        for origin in (None,BACKEND,'https://evil.test','null'):
            h=self.headers(**{'Content-Type':'application/json','X-Movie-Night-CSRF':'valid-csrf'})
            if origin is not None: h.append(('Origin',origin))
            self.assertEqual(self.request('/movie-night/api/feedback','POST',h,b'{}')[0],403)

    def test_duplicate_origin_denied(self):
        h=self.headers(Origin=PUBLIC)+[('Origin',PUBLIC)]
        self.assertEqual(self.request('/movie-night/api/feedback','POST',h,b'{}')[0],403)

    def test_same_origin_write_preserves_csrf_and_stable_principal(self):
        h=self.headers(**{'Origin':PUBLIC,'Content-Type':'application/json','X-Movie-Night-CSRF':'valid-csrf','Cookie':'afz_owner=secret','Authorization':'Bearer secret'})
        self.assertEqual(self.request('/movie-night/api/feedback','POST',h,b'{}')[0],200)
        _,_,forwarded,_=self.backend.received[-1]
        self.assertEqual(forwarded['Origin'],BACKEND)
        self.assertEqual(forwarded['X-AFZ-Review-Principal'],'billing-owner')
        for name in ('Cookie','Authorization','Tailscale-User-Login'): self.assertNotIn(name,forwarded)

    def test_missing_csrf_reaches_backend_and_is_denied(self):
        h=self.headers(**{'Origin':PUBLIC,'Content-Type':'application/json'})
        self.assertEqual(self.request('/movie-night/api/feedback','POST',h,b'{}')[0],403)

    def test_cross_site_entry_only_for_document_and_in_app_navigations(self):
        for destination in ('document', 'empty', None):
            fetch={'Sec-Fetch-Site':'cross-site','Sec-Fetch-Mode':'navigate'}
            if destination is not None: fetch['Sec-Fetch-Dest']=destination
            h=self.headers(**fetch)
            for path in ('/', '/login'):
                status, response, _ = self.request(path,headers=h)
                self.assertEqual((status,response.get('Location')),(303,'/movie-night/'))
            for path in ('/movie-night', '/movie-night/'):
                self.assertEqual(self.request(path,headers=h)[0],200)
            # Exact routing still excludes API subresources and response bodies.
            self.assertEqual(self.request(headers=h)[0],403)
            self.assertEqual(self.request('/movie-night/api/downloads',headers=h)[0],403)

    def test_cross_site_entry_query_redirect_drops_params_and_does_not_forward(self):
        h=self.headers(**{'Sec-Fetch-Site':'cross-site','Sec-Fetch-Mode':'navigate','Sec-Fetch-Dest':'document'})
        before=len(self.backend.received)
        for url,canonical in (
            ('/movie-night/?utm_source=chatgpt','/movie-night/'),
            ('/movie-night?ref=chatgpt','/movie-night'),
            ('/login?ref=chatgpt','/movie-night/'),
            ('/?entry=chatgpt','/movie-night/'),
        ):
            status,headers,body=self.request(url,headers=h)
            self.assertEqual((status,headers.get('Location')),(303,canonical),url)
            self.assertNotIn('utm_source',body.decode())
            self.assertIn('no-store',headers.get('Cache-Control',''))
        self.assertEqual(len(self.backend.received),before)
        # The clean top-level navigation works after following the redirect.
        self.assertEqual(self.request('/movie-night/',headers=h)[0],200)

    def test_cross_site_non_navigation_and_post_still_denied(self):
        for mode,destination in (
            ('cors','empty'),('no-cors','image'),('navigate','iframe'),
            ('navigate','script'),('same-origin','document'),(None,'document'),
        ):
            fetch={'Sec-Fetch-Site':'cross-site'}
            if mode is not None: fetch['Sec-Fetch-Mode']=mode
            if destination is not None: fetch['Sec-Fetch-Dest']=destination
            self.assertEqual(self.request('/movie-night/',headers=self.headers(**fetch))[0],403)
        h=self.headers(**{'Sec-Fetch-Site':'cross-site','Sec-Fetch-Mode':'navigate',
                           'Sec-Fetch-Dest':'document','Origin':PUBLIC,
                           'Content-Type':'application/json','X-Movie-Night-CSRF':'valid-csrf'})
        self.assertEqual(self.request('/movie-night/api/feedback','POST',h,b'{}')[0],403)
        self.assertEqual(self.request('/movie-night%2f?utm_source=chatgpt',headers=h)[0],403)
        self.assertEqual(self.request('/movie-night/../api/billing/snapshot?x=1',headers=h)[0],403)

    def test_external_entry_still_requires_owner_host_and_exact_origin(self):
        h=self.headers(**{'Sec-Fetch-Site':'cross-site','Sec-Fetch-Mode':'navigate','Sec-Fetch-Dest':'document'})
        without_owner=[(k,v) for k,v in h if k!='Tailscale-User-Login']
        self.assertEqual(self.request('/movie-night/?ref=chatgpt',headers=without_owner)[0],403)
        self.assertEqual(self.request('/movie-night/?ref=chatgpt',headers=h+[('Origin','https://chatgpt.com')])[0],403)
        self.assertEqual(self.request('/movie-night/?ref=chatgpt',headers=h+[('Host','evil.test')])[0],403)
        self.assertEqual(self.request('/movie-night/?ref=chatgpt',headers=h+[('Sec-Fetch-Mode','navigate')])[0],403)

    def test_new_server_deletion_routes_preserve_owner_and_csrf(self):
        self.backend.received.clear()
        path = '/movie-night/api/delete-server/tt12262116'
        status, _, _ = self.request(path)
        self.assertEqual(status, 200)
        self.assertEqual(self.backend.received[-1][1], path)
        bad = self.headers(**{'Sec-Fetch-Site':'cross-site',
                              'Sec-Fetch-Mode':'cors','Sec-Fetch-Dest':'empty'})
        before = len(self.backend.received)
        self.assertEqual(self.request(path, headers=bad)[0], 403)
        self.assertEqual(len(self.backend.received), before)
        content = b'{"imdb":"tt12262116","confirmationToken":"test","confirmedTitle":"Demo"}'
        valid = self.headers(**{'Origin':PUBLIC,'Content-Type':'application/json',
                                'X-Movie-Night-CSRF':'valid-csrf'})
        self.assertEqual(self.request('/movie-night/api/delete-server', 'POST', valid, content)[0], 200)
        forwarded = self.backend.received[-1][2]
        self.assertEqual(forwarded['Origin'], BACKEND)
        self.assertEqual(forwarded['X-Movie-Night-CSRF'], 'valid-csrf')
        no_origin = self.headers(**{'Content-Type':'application/json',
                                   'X-Movie-Night-CSRF':'valid-csrf'})
        self.assertEqual(self.request('/movie-night/api/delete-server', 'POST', no_origin, content)[0], 403)
        self.assertEqual(self.request('/movie-night/api/delete-server', 'POST',
                                      self.headers(**{'Origin':'https://evil.test','Content-Type':'application/json'}),
                                      content)[0], 403)

    def test_oversized_body_rejected(self):
        h=self.headers(**{'Origin':PUBLIC,'Content-Type':'application/json'})
        self.assertEqual(self.request('/movie-night/api/feedback','POST',h,b'x'*8193)[0],400)

    def test_not_for_other_methods(self):
        for method in ('PUT','DELETE','OPTIONS','TRACE'):
            self.assertEqual(self.request(method=method)[0],501)

    def test_origin_validation(self):
        for value in ('http://remote.test','https://user@remote.test','https://remote.test/path','https://remote.test?x=1'):
            with self.assertRaises(ValueError): exact_origin(value)

    def test_private_owner_configuration_and_no_wildcards(self):
        path=self.root/'owner.json'; path.write_text(json.dumps({'version':1,'owner_login':OWNER}));path.chmod(0o600)
        self.assertEqual(load_owner(path),OWNER)
        path.chmod(0o644)
        with self.assertRaises(ValueError): load_owner(path)
        path.chmod(0o600);path.write_text(json.dumps({'version':1,'owner_login':'*@example.test'}))
        with self.assertRaises(ValueError): load_owner(path)


if __name__ == '__main__': unittest.main()
