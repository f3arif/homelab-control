"""Exact review routes over a private Unix socket; never forward owner credentials."""
import http.client
import logging
import os
import re
from pathlib import Path
import socket
import stat
import time

DEFAULT_SOCKET = '/home/coolyo/afz-stremio-secondhost-20260918/state/movie-night-review/run/review.sock'
GET_PATHS = frozenset(('/movie-night', '/movie-night/', '/movie-night/screen.js', '/movie-night/screen.css', '/movie-night/api/shortlist','/movie-night/api/downloads','/movie-night/catalog/movie/downloaded.json'))
POST_PATHS = frozenset(('/movie-night/api/feedback', '/movie-night/api/finalize','/movie-night/api/propose','/movie-night/api/approve','/movie-night/api/cancel'))
PRINCIPAL = 'billing-owner'
MAX_RESPONSE = 1024 * 1024
POSTER_PATH = re.compile(r'/movie-night/posters/tt[0-9]{5,12}\.img\Z')
DYNAMIC_PATH = re.compile(r'/movie-night/api/(?:lookup/[a-f0-9]{32}|status/[a-f0-9-]{36})\Z')
MEDIA_PATH = re.compile(r'/movie-night/media/tt[0-9]{5,12}\Z')
LOG = logging.getLogger(__name__)
_FAILURE_STAGES = frozenset(('request', 'socket_validation', 'socket_connect',
                             'request_send', 'response_headers', 'response_body',
                             'response_size', 'response_mime', 'client_response'))

def _log_failure(handler, connection, stage, error, started):
    """Log fixed diagnostic fields only; logging cannot replace the existing 503."""
    try:
        if stage == 'request':
            stage = getattr(connection, '_failure_stage', 'request')
        if not isinstance(stage, str) or stage not in _FAILURE_STAGES:
            stage = 'request'
        method = handler.command if handler.command in ('GET', 'POST') else 'other'
        route = handler.path if handler.path in GET_PATHS | POST_PATHS else 'other'
        error_type = type(error).__name__
        if type(error).__module__ not in ('builtins', 'http.client'):
            error_type = 'OSError' if isinstance(error, OSError) else 'HTTPException'
        number = getattr(error, 'errno', None)
        number = number if type(number) is int else None
        elapsed_ms = max(0, int((time.monotonic() - started) * 1000))
        LOG.warning('movie_review_unavailable method=%s route=%s stage=%s '
                    'error_type=%s errno=%s elapsed_ms=%d',
                    method, route, stage, error_type, number, elapsed_ms)
    except Exception:
        pass  # A failed diagnostic sink must not change gateway behavior.

class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('localhost', timeout=5)
        self.path = path
    def connect(self):
        self._failure_stage = 'socket_validation'
        path = Path(self.path)
        for item, kind in ((path.parent, stat.S_ISDIR), (path, stat.S_ISSOCK)):
            info = item.lstat()
            if not kind(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise OSError('Review endpoint is not private')
        self._failure_stage = 'socket_connect'
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)
        self._failure_stage = 'request_send'

def dispatch(handler):
    """Caller has checked Host/Origin; verify session again before any forwarding."""
    if not handler.session():
        handler.send(401, '{"error":"sign_in_required"}', 'application/json'); return
    paths = GET_PATHS if handler.command == 'GET' else POST_PATHS
    poster = handler.command == 'GET' and POSTER_PATH.fullmatch(handler.path) is not None
    dynamic = handler.command == 'GET' and DYNAMIC_PATH.fullmatch(handler.path) is not None
    media = handler.command == 'GET' and MEDIA_PATH.fullmatch(handler.path) is not None
    if (handler.path not in paths and not poster and not dynamic and not media) or not handler.server.movie_socket:
        handler.send(404, 'Unavailable', 'text/plain'); return
    body = None
    if handler.command == 'POST':
        try:
            lengths = handler.headers.get_all('Content-Length', [])
            if len(lengths) != 1 or handler.headers.get('Transfer-Encoding'):
                raise ValueError()
            length = int(lengths[0])
            if not 0 < length <= 8192 or handler.headers.get('Content-Type', '').split(';')[0] != 'application/json':
                raise ValueError()
            body = handler.rfile.read(length)
            if len(body) != length: raise ValueError()
        except (ValueError, OSError):
            handler.send(400, 'Invalid review request', 'text/plain'); return
    # Whitelist headers: caller identity, cookie, authorization and finance never pass.
    headers = {'X-AFZ-Review-Principal': PRINCIPAL, 'Host': 'localhost'}
    if handler.command == 'POST':
        headers.update({'Origin': handler.server.origin, 'Content-Type': 'application/json',
                        'X-Movie-Night-CSRF': handler.headers.get('X-Movie-Night-CSRF', '')})
    if media:
        dispatch_media(handler,headers);return
    connection = UnixConnection(handler.server.movie_socket)
    started = time.monotonic()
    stage = 'request'
    try:
        connection.request(handler.command, handler.path, body=body, headers=headers)
        stage = 'response_headers'
        response = connection.getresponse()
        stage = 'response_body'
        payload = response.read(MAX_RESPONSE + 1)
        stage = 'response_size'
        if len(payload) > MAX_RESPONSE: raise OSError('Response too large')
        stage = 'response_mime'
        mime = response.getheader('Content-Type', 'text/plain').split(';')[0]
        allowed = ('image/jpeg', 'image/webp') if poster and response.status == 200 else ('text/html', 'text/css', 'application/javascript', 'application/json', 'text/plain')
        if mime not in allowed:
            raise OSError('Unexpected content')
        stage = 'client_response'
        handler.send(response.status, payload, mime)
    except (OSError, http.client.HTTPException) as error:
        _log_failure(handler, connection, stage, error, started)
        handler.send(503, '{"error":"movie_review_unavailable"}', 'application/json')
    finally:
        connection.close()


def dispatch_media(handler,headers):
    # Stream an indexed local file through the same owner session without buffering it.
    # Only single byte ranges and the trusted content headers are forwarded.
    range_value=handler.headers.get('Range')
    if range_value:
        if not re.fullmatch(r'bytes=(?:[0-9]{1,12}-[0-9]{0,12}|-[0-9]{1,12})',range_value):
            handler.send(416,'Unsupported range','text/plain');return
        headers['Range']=range_value
    connection=UnixConnection(handler.server.movie_socket);sent=False
    try:
        connection.request(handler.command,handler.path,headers=headers)
        response=connection.getresponse()
        if response.status not in (200,206):
            handler.send(response.status,'File unavailable','text/plain');return
        mime=response.getheader('Content-Type','').split(';')[0]
        length=int(response.getheader('Content-Length','-1'))
        if mime not in ('video/mp4','video/x-matroska','video/matroska','application/octet-stream') or not 0<=length<=15_000_000_000:
            raise ValueError()
        handler.send_response(response.status)
        handler.send_header('Content-Type',mime);handler.send_header('Content-Length',str(length))
        handler.send_header('Cache-Control','private, no-store');handler.send_header('X-Content-Type-Options','nosniff')
        handler.send_header('Referrer-Policy','no-referrer');handler.send_header('Accept-Ranges','bytes')
        handler.send_header('Content-Security-Policy',"default-src 'none'; frame-ancestors 'none'")
        for name in ('Content-Range','Content-Disposition'):
            value=response.getheader(name)
            if value and '\r' not in value and '\n' not in value:handler.send_header(name,value)
        handler.end_headers();sent=True
        if handler.command == 'HEAD':
            return
        left=length
        while left:
            chunk=response.read(min(65536,left))
            if not chunk:raise OSError()
            handler.wfile.write(chunk);left-=len(chunk)
    except Exception:
        if sent:handler.close_connection=True
        else:handler.send(503,'File temporarily unavailable','text/plain')
    finally:connection.close()
