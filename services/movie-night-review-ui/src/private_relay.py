"""Private Envy Unix socket -> authenticated ZBook backend over the tailnet.

No public listener, user credentials, arbitrary targets or arbitrary routes.
The backend independently checks both the Envy tailnet address and a secret.
"""
import argparse
import hmac
import http.client
from http.server import BaseHTTPRequestHandler
import os
from pathlib import Path
import socket
import socketserver
import stat

HEADER = 'x-movie-night-relay'


def read_secret(path):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Private relay secret required')
    value = path.read_text().strip()
    if len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
        raise ValueError('Invalid relay secret')
    return value


class RelayAuth:
    """Unix socket is owner-only. TCP requires a fixed peer and secret."""
    def __init__(self, app, secret, peer='100.71.26.69', unix_path=None):
        self.app, self.secret, self.peer = app, secret, peer
        self.unix_path = str(unix_path) if unix_path is not None else None

    async def __call__(self, scope, receive, send):
        local_unix = (self.unix_path is not None and scope.get('server') == (self.unix_path, None)
                      and scope.get('client') is None)
        if scope['type'] == 'http' and not local_unix:
            client = scope.get('client') or ('', 0)
            values = [v for k, v in scope.get('headers', []) if k.lower() == HEADER.encode()]
            allowed = (client[0] == self.peer and len(values) == 1 and
                       hmac.compare_digest(values[0], self.secret.encode()))
            if not allowed:
                await send({'type': 'http.response.start', 'status': 403,
                            'headers': [(b'content-type', b'text/plain'), (b'content-length', b'9')]})
                await send({'type': 'http.response.body', 'body': b'Forbidden'})
                return
            scope = dict(scope, headers=[(k, v) for k, v in scope['headers'] if k.lower() != HEADER.encode()])
        await self.app(scope, receive, send)


class RelayHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_GET(self): self.forward()
    def do_HEAD(self): self.forward()
    def do_POST(self): self.forward()

    def forward(self):
        self.close_connection = True
        connection = None
        sent = False
        try:
            if not self.path.startswith('/movie-night') or '?' in self.path or '#' in self.path:
                self.send_error(404); return
            if self.headers.get('Transfer-Encoding'):
                self.send_error(400); return
            body = None
            if self.command == 'POST':
                lengths = self.headers.get_all('Content-Length', [])
                if len(lengths) != 1 or not 0 < int(lengths[0]) <= 8192:
                    self.send_error(400); return
                body = self.rfile.read(int(lengths[0]))
                if len(body) != int(lengths[0]): raise ValueError()
            # Identity is assigned only by the existing owner gateway.
            allowed = {'x-afz-review-principal', 'origin', 'content-type', 'x-movie-night-csrf', 'range'}
            headers = {k: v for k, v in self.headers.items() if k.lower() in allowed}
            headers[HEADER] = self.server.secret
            connection = http.client.HTTPConnection(self.server.host, self.server.port, timeout=15)
            connection.request(self.command, self.path, body=body, headers=headers)
            response = connection.getresponse()
            length = int(response.getheader('Content-Length', '-1'))
            cap = 15_000_000_000 if self.path.startswith('/movie-night/media/') else 2_000_000
            if not 0 <= length <= cap: raise ValueError()
            self.send_response(response.status)
            for name in ('Content-Type', 'Content-Length', 'Content-Range', 'Accept-Ranges',
                         'Content-Disposition', 'Cache-Control', 'Content-Security-Policy',
                         'Referrer-Policy', 'X-Content-Type-Options'):
                value = response.getheader(name)
                if value is not None: self.send_header(name, value)
            self.send_header('Connection', 'close')
            self.end_headers(); sent = True
            left = 0 if self.command == 'HEAD' else length
            while left:
                data = response.read(min(left, 65536))
                if not data: raise OSError()
                self.wfile.write(data); left -= len(data)
        except Exception:
            if not sent: self.send_error(503, 'Movie Night backend unavailable')
        finally:
            if connection: connection.close()


class RelayServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--socket', required=True)
    p.add_argument('--secret', required=True)
    p.add_argument('--host', default='100.77.196.70', choices=['100.77.196.70'])
    p.add_argument('--port', default=8797, type=int, choices=[8797])
    args = p.parse_args()
    os.umask(0o077)
    path = Path(args.socket)
    parent = path.parent.lstat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o077:
        raise ValueError('Private socket directory required')
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid(): raise ValueError('Unexpected socket')
        probe = socket.socket(socket.AF_UNIX)
        try: probe.connect(str(path))
        except ConnectionRefusedError: path.unlink()
        else: raise ValueError('Socket already active')
        finally: probe.close()
    with RelayServer(str(path), RelayHandler) as server:
        os.chmod(path, 0o600)
        server.host, server.port, server.secret = args.host, args.port, read_secret(args.secret)
        server.serve_forever()


if __name__ == '__main__': main()
