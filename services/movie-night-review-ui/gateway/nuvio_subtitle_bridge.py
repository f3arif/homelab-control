"""Optional additive subtitle adapter for the existing owner-private gateway.

Install explicitly with enable_subtitles(server) BEFORE serve_forever, after
attaching the backend routes. No new port, identity rule, external provider,
lookup on catalog requests, or change to the ranking/deletion implementation.
"""
import copy
import http.client
import json
import re
from urllib.parse import urlsplit, unquote

from movie_gateway import PRINCIPAL, UnixConnection
from standalone_server import Handler
from nuvio_ready_catalog import payload as ready_payload

PREFIX = '/movie-night'
IMDB = re.compile(r'tt[0-9]{5,12}\Z')
TRACK = re.compile(r'[a-f0-9]{32}-s[0-9]{1,4}\Z')
LIST = re.compile(r'/movie-night/subtitles/movie/(tt[0-9]{5,12})\.json\Z')
FILE = re.compile(r'/movie-night/subtitle-files/(tt[0-9]{5,12})/([a-f0-9]{32}-s[0-9]{1,4})\.vtt\Z')
STREAM = re.compile(r'/movie-night/stream/movie/(tt[0-9]{5,12})\.json\Z')
MAX_TEXT = 1_900_000
MAX_META = 131_072


LIST_EXTRAS = re.compile(r'/movie-night/subtitles/movie/(tt[0-9]{5,12})/([^/?#]{1,1024})\.json\Z')


def subtitle_request_id(path):
    """Accept the real TV client's bounded hints, never use them as a target."""
    if not isinstance(path, str):
        return None
    plain = LIST.fullmatch(path)
    if plain:
        return plain[1]
    match = LIST_EXTRAS.fullmatch(path)
    if not match:
        return None
    seen = set()
    for pair in match[2].split('&'):
        key, separator, raw = pair.partition('=')
        if not separator or key in seen or key not in ('videoHash', 'videoSize', 'filename'):
            return None
        seen.add(key)
        if key == 'videoHash' and not re.fullmatch(r'[a-fA-F0-9]{16}', raw):
            return None
        if key == 'videoSize' and (not re.fullmatch(r'[0-9]{1,12}', raw) or not 0 < int(raw) <= 15_000_000_000):
            return None
        if key == 'filename':
            if re.search(r'%(?![a-fA-F0-9]{2})', raw):
                return None
            try:
                filename = unquote(raw, encoding='utf-8', errors='strict')
            except UnicodeError:
                return None
            if (not 1 <= len(filename) <= 255 or any(not c.isprintable() for c in filename)
                    or any(c in filename for c in ('/', chr(92), '%')) or '..' in filename):
                return None
    return match[1]


def _read_private(handler, path, mime, cap):
    connection = UnixConnection(handler.server.movie_socket)
    try:
        connection.request('GET', path, headers={'Host': 'localhost', 'X-AFZ-Review-Principal': PRINCIPAL})
        response = connection.getresponse()
        if response.status != 200 or response.getheader('Content-Type', '').split(';')[0].strip() != mime:
            raise ValueError('Private subtitle unavailable')
        data = response.read(cap + 1)
        if len(data) > cap:
            raise ValueError('Subtitle response exceeds budget')
        return data
    finally:
        connection.close()


def descriptors(origin, imdb, data):
    """Never accept any URL from a backend descriptor; construct a fixed origin."""
    u = urlsplit(origin)
    if u.scheme != 'https' or not u.netloc or u.username or u.password or u.path or u.query or u.fragment:
        raise ValueError('Exact private HTTPS origin required')
    if not isinstance(imdb, str) or not IMDB.fullmatch(imdb):
        raise ValueError('Invalid movie ID')
    tracks = data.get('tracks') if isinstance(data, dict) else None
    if not isinstance(tracks, list) or len(tracks) > 64:
        raise ValueError('Invalid subtitle list')
    out, seen = [], set()
    for t in tracks:
        if not isinstance(t, dict) or not isinstance(t.get('id'), str) or not TRACK.fullmatch(t['id']):
            raise ValueError('Invalid subtitle ID')
        if t['id'] in seen:
            continue
        if not isinstance(t.get('lang'), str) or not re.fullmatch(r'[a-z]{3}', t['lang']):
            raise ValueError('Invalid language')
        label = t.get('label', '')
        if not isinstance(label, str) or len(label) > 96 or any(not c.isprintable() for c in label):
            raise ValueError('Invalid subtitle label')
        seen.add(t['id'])
        out.append({'id': 'afz-' + t['id'], 'lang': t['lang'],
                    'label': (label or t['lang']) + ' · Server',
                    'name': (label or t['lang']) + ' · Server', 'language': t['lang'],
                    'url': origin + PREFIX + '/subtitle-files/' + imdb + '/' + t['id'] + '.vtt'})
    return out


def read_descriptors(handler, imdb):
    raw = _read_private(handler, PREFIX + '/api/subtitles/' + imdb, 'application/json', MAX_META)
    return descriptors(handler.server.public_origin, imdb, json.loads(raw))


def with_subtitle_resource(manifest):
    out = copy.deepcopy(manifest)
    resources = out.setdefault('resources', [])
    if not any((x if isinstance(x, str) else x.get('name')) == 'subtitles' for x in resources):
        resources.append({'name': 'subtitles', 'types': ['movie'], 'idPrefixes': ['tt']})
    return out


def with_stream_subtitles(payload, origin, imdb, subtitles):
    """Only this exact indexed Movie Night file gets the matching sidecars."""
    out = copy.deepcopy(payload)
    expected = origin + PREFIX + '/media/' + imdb
    for stream in out.get('streams', []):
        if isinstance(stream, dict) and stream.get('url') == expected and subtitles:
            original = stream.get('subtitles')
            if original is not None and not isinstance(original, list):
                continue
            values = list(original or [])
            urls = {x.get('url') for x in values if isinstance(x, dict)}
            values.extend(x for x in subtitles if x['url'] not in urls)
            stream['subtitles'] = values
    return out


class SubtitleHandler(Handler):
    """Every new resource keeps exact Host/Origin and Tailscale-owner checks."""
    def _authorize_subtitle(self):
        if not self.boundary():
            return False
        if not self.session():
            self.denied()
            return False
        return True

    def _subtitle_file(self, imdb, tid):
        try:
            data = _read_private(self, PREFIX + '/subtitle-files/' + imdb + '/' + tid + '.vtt',
                                 'text/vtt', MAX_TEXT)
            if not data.decode('utf-8-sig').startswith('WEBVTT\n'):
                raise ValueError('Invalid WebVTT')
            if self.command == 'HEAD':
                self.send_response(200)
                self.send_header('Content-Type', 'text/vtt; charset=utf-8')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'private, no-store')
                self.send_header('X-Content-Type-Options', 'nosniff')
                self.send_header('Referrer-Policy', 'no-referrer')
                self.end_headers()
            else:
                self.send(200, data, 'text/vtt; charset=utf-8')
        except (OSError, ValueError, http.client.HTTPException):
            if self.command == 'HEAD':
                self.send_response(404)
                self.send_header('Content-Length', '0')
                self.end_headers()
            else:
                self.send(404, 'Subtitle unavailable', 'text/plain')

    def do_HEAD(self):
        found = FILE.fullmatch(self.path)
        if not found:
            return super().do_HEAD()
        if self._authorize_subtitle():
            self._subtitle_file(*found.groups())

    def do_GET(self):
        file_match, stream_match = (p.fullmatch(self.path) for p in (FILE, STREAM))
        list_id = subtitle_request_id(self.path)
        is_manifest = self.path == PREFIX + '/manifest.json'
        if not any((file_match, list_id, stream_match, is_manifest)):
            return super().do_GET()
        if not self._authorize_subtitle():
            return
        if file_match:
            self._subtitle_file(*file_match.groups())
            return
        try:
            if is_manifest:
                value = with_subtitle_resource(ready_payload(self, 'manifest', None))
            elif list_id:
                value = {'subtitles': read_descriptors(self, list_id),
                         'cacheMaxAge': 0, 'staleRevalidate': 0, 'staleError': 0}
            else:
                imdb = stream_match[1]
                value = ready_payload(self, 'stream', imdb)
                if value.get('streams'):
                    try:
                        tracks = read_descriptors(self, imdb)
                        value = with_stream_subtitles(value, self.server.public_origin, imdb, tracks)
                    except (OSError, ValueError, http.client.HTTPException):
                        pass  # A subtitle/cache outage must not block the existing video.
            self.send(200, json.dumps(value, ensure_ascii=False), 'application/json')
        except (OSError, ValueError, http.client.HTTPException):
            self.send(503, '{"error":"private_subtitles_unavailable"}', 'application/json')


def enable_subtitles(server):
    """Explicit opt-in only; never changes existing server files or starts a listener."""
    if server.RequestHandlerClass is not Handler:
        raise ValueError('Unexpected gateway handler; reconcile existing changes first')
    server.RequestHandlerClass = SubtitleHandler
