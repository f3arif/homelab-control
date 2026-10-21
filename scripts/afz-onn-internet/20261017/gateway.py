#!/usr/bin/env python3
"""Read-only, token-protected Stremio transport for AFZ Internet."""
import argparse
import hashlib
import hmac
import html
import ipaddress
import json
import re
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ADDON_ID = 'com.afzengineering.releasecatalog.internet'
UPSTREAM = 'https://desktop-h3r6cqn.tailc9bb62.ts.net:8445'
JSON_LIMIT = 16 * 1024 * 1024
MEDIA = re.compile(r'/(?:external-stream/tt\d+(?::\d+:\d+)?|direct-stream/tt\d+)/[a-f0-9]{20,64}\Z')
JSON_ROUTE = re.compile(r'/(?:catalog/(?:movie|series)/[A-Za-z0-9_.-]+(?:/[^?#]{1,1024})?|(?:meta|stream)/(?:movie|series)/[A-Za-z0-9_:.-]+)\.json\Z')
ART = re.compile(r'/art/(?:poster|episode|backdrop|logo)/[A-Za-z0-9_./-]+\.(?:jpg|jpeg|png|webp)\Z')
TOKEN = re.compile(r'[A-Za-z0-9_-]{40,96}\Z')

def route_kind(raw_path):
    if len(raw_path) > 2048 or '#' in raw_path:
        return None
    raw_path, separator, query = raw_path.partition('?')
    path = urllib.parse.unquote(raw_path)
    if separator:
        if not ART.fullmatch(path):
            return None
        pairs = urllib.parse.parse_qsl(query,keep_blank_values=True)
        if not pairs or len(pairs)>2 or len({k for k,v in pairs})!=len(pairs):
            return None
        for key,value in pairs:
            if key == 'media' and value in ('movie','series'):
                continue
            if key == 'rev' and re.fullmatch(r'[A-Za-z0-9_.-]{1,64}',value):
                continue
            return None
    if any(ord(c) < 32 for c in path) or '\\' in path or '%' in path:
        return None
    if any(x in ('.', '..') for x in path.split('/')):
        return None
    if path == '/manifest.json':
        return 'manifest'
    if path == '/setup':
        return 'setup'
    if JSON_ROUTE.fullmatch(path):
        return 'json'
    if ART.fullmatch(path):
        return 'art'
    if MEDIA.fullmatch(path):
        return 'media'
    return None

def public_url(value):
    try:
        if any(ord(c)<32 or ord(c)==127 for c in value):
            return False
        u = urllib.parse.urlsplit(value)
        if u.scheme != 'https' or not u.hostname or u.username or u.password:
            return False
        host = u.hostname.lower()
        if host in ('localhost', 'localhost.localdomain') or host.endswith(('.local', '.localhost', '.ts.net')):
            return False
        try:
            return ipaddress.ip_address(host).is_global
        except ValueError:
            return '.' in host and not host.endswith('.')
    except (ValueError, TypeError):
        return False

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

class Gateway:
    def __init__(self, token, public_origin, upstream=UPSTREAM, opener=None):
        if not TOKEN.fullmatch(token):
            raise ValueError('Invalid access token')
        if not public_origin.startswith('https://') or urllib.parse.urlsplit(public_origin).path:
            raise ValueError('An HTTPS origin without a path is required')
        self.token = token
        self.origin = public_origin.rstrip('/')
        self.base = self.origin+'/'+token
        self.upstream = upstream.rstrip('/')
        self.upstream_host = urllib.parse.urlsplit(upstream).netloc
        self.source_hosts = {self.upstream_host,urllib.parse.urlsplit(UPSTREAM).netloc}
        self.opener = opener or urllib.request.build_opener(NoRedirect())
        self.capacity = threading.BoundedSemaphore(16)

    def authorize(self, path):
        first, sep, rest = path.lstrip('/').partition('/')
        if not sep or not TOKEN.fullmatch(first) or not hmac.compare_digest(first, self.token):
            return None
        route = '/'+rest
        return route if route_kind(route) else None

    def rewrite_url(self, value):
        u = urllib.parse.urlsplit(value)
        if u.scheme == 'https' and u.netloc in self.source_hosts:
            path = u.path + ('?'+u.query if u.query else '')
            return self.base+path if route_kind(path) in ('json', 'manifest', 'art', 'media') else ''
        return value if public_url(value) else ''

    def transform(self, obj, manifest=False):
        def rewrite(v):
            if isinstance(v, dict):
                return {k:rewrite(x) for k,x in v.items()}
            if isinstance(v, list):
                return [rewrite(x) for x in v]
            if isinstance(v, str) and v.startswith(('http://','https://')):
                return self.rewrite_url(v)
            return v
        result = rewrite(obj)
        if manifest:
            allowed = ('version','description','types','resources','catalogs','logo','background')
            result = {k:result[k] for k in allowed if k in result}
            result['types']=[x for x in result.get('types',[]) if x in ('movie','series')]
            result['catalogs']=[x for x in result.get('catalogs',[]) if x.get('type') in ('movie','series')]
            result.update(id=ADDON_ID, name='AFZ Internet',
                description='AFZ movies and series. Works with Tailscale off on your TV.',
                behaviorHints={'configurable':False,'configurationRequired':False})
        if isinstance(result, dict) and isinstance(result.get('streams'), list):
            # Browser download/control actions are outside this TV transport.
            result['streams'] = [x for x in result['streams']
                                  if isinstance(x,dict) and x.get('url') and not x.get('externalUrl')]
        return result

    def setup_page(self):
        manifest = self.base+'/manifest.json'
        stremio = manifest.replace('https://','stremio://',1)
        return ('<!doctype html><html lang="en"><meta charset="utf-8">'
          '<meta name="viewport" content="width=device-width,initial-scale=1">'
          '<title>AFZ Internet</title><style>body{margin:0;background:#10131b;color:#f7f8fc;'
          'font:18px system-ui;display:grid;place-items:center;min-height:100vh}main{'
          'max-width:520px;padding:32px}h1{font-size:38px;margin:0 0 16px}p{line-height:1.6;'
          'color:#bac4d8}a,button{display:block;margin:18px 0;padding:16px 22px;border:0;'
          'border-radius:12px;background:#718bff;color:#07102e;text-decoration:none;'
          'font:600 18px system-ui;cursor:pointer}input{box-sizing:border-box;width:100%;'
          'padding:14px;border:1px solid #34405a;border-radius:10px;background:#171e2d;'
          'color:#eef2ff;font:14px system-ui}small{color:#95a3be}</style><main>'
          '<h1>AFZ Internet</h1><p>Watch with Tailscale off on your TV. '
          'Your AFZ home server must be online.</p>'
          '<a href="'+html.escape(stremio,quote=True)+'">Install add-on</a>'
          '<p>For Nuvio, open Add-ons, choose Add, and paste this link:</p>'
          '<input id="link" readonly aria-label="Add-on link" value="'+html.escape(manifest,quote=True)+'">'
          '<button onclick="navigator.clipboard.writeText(document.getElementById(\'link\').value)'
          '.then(()=>this.textContent=\'Copied\')">Copy add-on link</button>'
          '<small>Choose AFZ Internet when selecting a source.</small></main></html>').encode()

class Handler(BaseHTTPRequestHandler):
    timeout = 15
    protocol_version = 'HTTP/1.1'
    server_version = 'AFZInternet/1.0'

    def log_message(self, fmt, *args):
        pass  # Request paths contain the private access token.

    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin','*')
        self.send_header('Access-Control-Expose-Headers','Content-Range,Accept-Ranges,Content-Length,ETag')
        self.send_header('Cache-Control','no-store')
        self.send_header('Referrer-Policy','no-referrer')
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Connection','close')
        self.close_connection = True
        self.response_started = True
        super().end_headers()

    def body(self, status, body=b'', content_type='application/json'):
        self.send_response(status)
        self.send_header('Content-Type',content_type)
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def do_OPTIONS(self):
        if not self.server.gateway.authorize(self.path):
            return self.body(404,b'{}')
        self.send_response(204)
        self.send_header('Access-Control-Allow-Methods','GET,HEAD,OPTIONS')
        self.send_header('Access-Control-Allow-Headers','Range,If-Range,If-None-Match,If-Modified-Since')
        self.send_header('Content-Length','0')
        self.end_headers()

    def do_POST(self):
        self.body(404,b'{}')
    do_PUT = do_DELETE = do_PATCH = do_POST

    def do_GET(self):
        self.response_started = False
        gw = self.server.gateway
        route = gw.authorize(self.path)
        if route is None:
            return self.body(404,b'{}')
        kind = route_kind(route)
        if kind == 'setup':
            return self.body(200,gw.setup_page(),'text/html; charset=utf-8')
        if not gw.capacity.acquire(blocking=False):
            return self.body(429,b'{"error":"Busy; retry shortly"}')
        response = None
        try:
            headers = {'User-Agent':'AFZInternet/1.0','Accept-Encoding':'identity'}
            for name in ('Range','If-Range','If-None-Match','If-Modified-Since'):
                if kind in ('media','art') and self.headers.get(name):
                    headers[name] = self.headers[name]
            # For JSON/manifest HEAD, fetch once so the transformed length matches GET.
            method = 'HEAD' if self.command == 'HEAD' and kind in ('art','media') else 'GET'
            req = urllib.request.Request(gw.upstream+route,method=method,headers=headers)
            try:
                response = gw.opener.open(req,timeout=25)
            except urllib.error.HTTPError as exc:
                response = exc
            status = response.status
            if status in (301,302,303,307,308):
                location = gw.rewrite_url(response.headers.get('Location',''))
                if not location:
                    return self.body(502,b'{"error":"Source unavailable"}')
                self.send_response(status)
                self.send_header('Location',location)
                self.send_header('Content-Length','0')
                self.end_headers()
                return
            if status not in (200,206,304):
                return self.body(status if status in (404,409,416,429,503) else 502,
                                 b'{"error":"Source unavailable"}')
            if kind in ('json','manifest') and status != 304:
                raw = response.read(JSON_LIMIT+1)
                if len(raw) > JSON_LIMIT:
                    return self.body(502,b'{"error":"Response too large"}')
                obj = gw.transform(json.loads(raw),manifest=(kind=='manifest'))
                return self.body(status,json.dumps(obj,separators=(',',':'),ensure_ascii=False).encode())
            self.send_response(status)
            for name in ('Content-Type','Content-Length','Content-Range','Accept-Ranges',
                         'ETag','Last-Modified','Content-Encoding'):
                if response.headers.get(name):
                    self.send_header(name,response.headers[name])
            self.end_headers()
            if self.command != 'HEAD' and status != 304:
                while True:
                    chunk = response.read(64*1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except (BrokenPipeError,ConnectionResetError):
            pass
        except (OSError,ValueError,urllib.error.URLError):
            # No protected URLs or upstream exception strings in public errors.
            if not self.response_started:
                self.body(502,b'{"error":"AFZ is temporarily unavailable"}')
            else:
                self.close_connection = True
        finally:
            if response is not None:
                response.close()
            gw.capacity.release()

    do_HEAD = do_GET

class BoundedHTTPServer(ThreadingHTTPServer):
    def __init__(self,*args,**kwargs):
        self.connection_slots=threading.BoundedSemaphore(64)
        super().__init__(*args,**kwargs)
    def process_request(self,request,client_address):
        if not self.connection_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request,client_address)
        except BaseException:
            self.connection_slots.release()
            raise
    def process_request_thread(self,request,client_address):
        try:
            super().process_request_thread(request,client_address)
        finally:
            self.connection_slots.release()

def make_server(bind, port, gateway):
    server = BoundedHTTPServer((bind,port),Handler)
    server.daemon_threads = True
    server.gateway = gateway
    return server

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config',required=True)
    args = parser.parse_args()
    cfg = json.loads(Path(args.config).read_text(encoding='utf-8'))
    upstream=cfg.get('upstream',UPSTREAM)
    if upstream not in (UPSTREAM,'http://127.0.0.1:18774'):
        raise ValueError('Unreviewed upstream')
    gateway = Gateway(cfg['token'],cfg['publicOrigin'],upstream=upstream)
    make_server('127.0.0.1',int(cfg.get('port',19088)),gateway).serve_forever()

if __name__ == '__main__':
    main()
