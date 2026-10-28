"""Movie Night only, authenticated by an exact Tailscale Serve owner identity.

Bind only to loopback behind Serve. Never publish this listener directly. Serve
removes client-supplied identity headers. Local processes on this host remain in
the trusted boundary, as they are for the existing owner-only review socket.
"""
import argparse
import json
import os
import stat
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from movie_gateway import DEFAULT_SOCKET, dispatch, dispatch_media, MEDIA_PATH, PRINCIPAL
from nuvio_ready_catalog import handle as handle_nuvio_catalog

# Only these public entry pages may be opened from another site.
ENTRY_PATHS = frozenset(('/', '/login', '/movie-night', '/movie-night/'))


def exact_origin(value):
    url = urlsplit(value)
    if (url.scheme not in ('http', 'https') or not url.hostname or url.path
            or url.query or url.fragment or url.username or url.password
            or (url.scheme == 'http' and url.hostname not in ('localhost', '127.0.0.1'))):
        raise ValueError('An exact HTTPS origin is required')
    return url.netloc


def load_owner(path):
    path = Path(path)
    for item, kind in ((path.parent, stat.S_ISDIR), (path, stat.S_ISREG)):
        info = item.lstat()
        if not kind(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('Owner configuration must be private and owned by this user')
    record = json.loads(path.read_text())
    if set(record) != {'version', 'owner_login'} or record['version'] != 1:
        raise ValueError('Invalid owner configuration')
    owner = record['owner_login']
    if (not isinstance(owner, str) or not 3 <= len(owner) <= 254 or '@' not in owner
            or not owner.isascii() or any(c.isspace() for c in owner) or '*' in owner):
        raise ValueError('One exact owner login is required')
    return owner


class MovieNightServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, public_origin, backend_origin, owner_login, port=8767,
                 movie_socket=DEFAULT_SOCKET):
        self.host = exact_origin(public_origin)
        exact_origin(backend_origin)
        self.public_origin = public_origin
        # The existing backend retains its configured origin and stable principal.
        # dispatch only reaches this value AFTER checking the actual public origin.
        self.origin = backend_origin
        self.owner_login = owner_login
        self.movie_socket = movie_socket
        super().__init__(('127.0.0.1', port), Handler)


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, *args):
        pass  # No identities, cookies, titles or request bodies in access logs.

    def send(self, status, body='', mime='text/html', location=None):
        payload = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Cache-Control', 'private, no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        if location:
            self.send_header('Location', location)
        self.end_headers()
        self.wfile.write(payload)

    def boundary(self, post=False):
        if self.headers.get_all('Host', []) != [self.server.host]:
            self.send(403, 'Address not allowed', 'text/plain'); return False
        origins = self.headers.get_all('Origin', [])
        if (origins and origins != [self.server.public_origin]) or (post and not origins):
            self.send(403, 'Origin not allowed', 'text/plain'); return False
        sites = self.headers.get_all('Sec-Fetch-Site', [])
        if len(sites) > 1:
            self.send(403, 'Request not allowed', 'text/plain'); return False
        if sites == ['cross-site']:
            # In-app browsers can omit Sec-Fetch-Dest or mark it empty; the
            # browser-controlled navigation mode is still required. Reject
            # cross-site subresources, API calls, and all writes as before.
            dest = self.headers.get_all('Sec-Fetch-Dest', [])
            entry = (not post and self.command == 'GET'
                     and self.path.partition('?')[0] in ENTRY_PATHS
                     and self.headers.get_all('Sec-Fetch-Mode', []) == ['navigate']
                     and dest in ([], ['document'], ['empty']))
            if not entry:
                self.send(403, 'Cross-site request denied', 'text/plain'); return False
        return True

    def session(self):
        # Cookies (including afz_owner) and bearer headers are never credentials here.
        # Missing, tagged-device, duplicate or different user identities fail closed.
        return self.headers.get_all('Tailscale-User-Login', []) == [self.server.owner_login]

    def denied(self):
        if self.path.partition('?')[0] in ENTRY_PATHS:
            self.send(403, '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Movie Night · Private access</title><main><h1>Movie Night</h1><p>Connect Tailscale using your owner account, then open this page again.</p><p>This address uses your Tailscale sign-in. No billing password is needed.</p></main></html>')
        else:
            self.send(403, '{"error":"movie_night_owner_required"}', 'application/json')

    def do_GET(self):
        if not self.boundary():
            return
        if not self.session():
            self.denied(); return
        path, separator, _ = self.path.partition('?')
        if separator and path in ENTRY_PATHS:
            # Drop tracking parameters rather than forwarding unknown query
            # strings to the exact-route-only private backend.
            self.send(303, location='/movie-night/' if path in ('/', '/login') else path)
            return
        if self.path in ('/', '/login'):
            self.send(303, location='/movie-night/'); return
        if handle_nuvio_catalog(self):
            return
        dispatch(self)

    def do_HEAD(self):
        if not self.boundary():
            return
        if not self.session():
            self.denied(); return
        if not MEDIA_PATH.fullmatch(self.path):
            self.send(404, 'Unavailable', 'text/plain'); return
        dispatch_media(self, {'X-AFZ-Review-Principal': PRINCIPAL, 'Host': 'localhost'})

    def do_POST(self):
        if not self.boundary(post=True):
            return
        if not self.session():
            self.denied(); return
        dispatch(self)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--owner-config', required=True)
    parser.add_argument('--origin', required=True)
    parser.add_argument('--backend-origin', required=True)
    parser.add_argument('--port', type=int, default=8767)
    parser.add_argument('--socket', default=DEFAULT_SOCKET)
    args = parser.parse_args()
    server = MovieNightServer(args.origin, args.backend_origin, load_owner(args.owner_config),
                             args.port, args.socket)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
