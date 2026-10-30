"""Optional private, file-matched text subtitles for Movie Night.

Preparation is an explicit operator/background action, never an HTTP request.
Movies are opened read-only; generated WebVTT stays in a separate private cache.
No external provider, user-supplied URL, shell, translation or media rewrite.
"""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import stat
import subprocess
import threading
import time

IMDB = re.compile(r'tt[0-9]{5,12}\Z')
TRACK = re.compile(r'([a-f0-9]{32})-s([0-9]{1,4})\Z')
TEXT_CODECS = frozenset(('subrip', 'webvtt', 'ass', 'ssa', 'mov_text', 'text'))
MAX_TEXT = 1_900_000  # below the existing private relay's 2 MB response cap
MAX_META = 131_072
MAX_TRACKS = 64
CACHE_BUDGET = 128 * 1024 * 1024
SAFE_HEADERS = {'Cache-Control': 'private, no-store', 'X-Content-Type-Options': 'nosniff',
                'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': "default-src 'none'"}


class SubtitleUnavailable(ValueError):
    """Intentionally generic: no file paths, dialogue or tool stderr leak."""


def _directory(path, private=False):
    path = Path(path)
    if not path.is_absolute():
        raise SubtitleUnavailable('Absolute directory required')
    for item in (path, *path.parents):
        if not stat.S_ISDIR(item.lstat().st_mode):
            raise SubtitleUnavailable('Unsafe directory')
    info = path.stat()
    if private and (info.st_uid != os.getuid() or info.st_mode & 0o077):
        raise SubtitleUnavailable('Private cache required')
    return path


def _fingerprint(info):
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise SubtitleUnavailable('Regular unlinked-alias file required')
    record = [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]
    return hashlib.sha256(json.dumps(record).encode()).hexdigest()[:32]


def _label(value):
    if not isinstance(value, str):
        return ''
    return ''.join(c for c in value if c.isprintable()).strip()[:96]


def _bounded_tool(args, fd, *, cap, timeout):
    """Bound output and elapsed time without buffering arbitrary tool output."""
    proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, pass_fds=(fd,), close_fds=True)
    deadline = time.monotonic() + timeout
    data = bytearray()
    try:
        with selectors.DefaultSelector() as watch:
            watch.register(proc.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise SubtitleUnavailable('Subtitle preparation timed out')
                events = watch.select(min(remaining, .25))
                if not events:
                    continue
                chunk = os.read(proc.stdout.fileno(), min(65536, cap + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
                if len(data) > cap:
                    raise SubtitleUnavailable('Subtitle exceeds size budget')
        if proc.wait(timeout=max(.01, deadline - time.monotonic())) != 0:
            raise SubtitleUnavailable('Subtitle tool could not prepare this track')
        return bytes(data)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SubtitleUnavailable('Subtitle preparation unavailable') from exc
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        proc.stdout.close()


def _vtt(data):
    if not data or len(data) > MAX_TEXT:
        raise SubtitleUnavailable('Invalid subtitle size')
    try:
        text = data.decode('utf-8-sig')
    except UnicodeError as exc:
        raise SubtitleUnavailable('Subtitles must be UTF-8') from exc
    if not text.startswith('WEBVTT\n') or '\x00' in text or not re.search(
            r'(?m)^\d{2,}:\d{2}(?::\d{2})?\.\d{3} --> \d{2,}:\d{2}(?::\d{2})?\.\d{3}', text):
        raise SubtitleUnavailable('No valid WebVTT cues')
    return text.encode('utf-8')


class SubtitleCache:
    def __init__(self, index, cache_dir, *, ffprobe, ffmpeg, tool=_bounded_tool):
        self.index = index
        self.directory = Path(cache_dir)
        _directory(self.directory.parent, private=True)
        self.directory.mkdir(mode=0o700, exist_ok=True)
        _directory(self.directory, private=True)
        self.ffprobe, self.ffmpeg = str(ffprobe), str(ffmpeg)
        if not all(Path(x).is_absolute() and Path(x).is_file() for x in (self.ffprobe, self.ffmpeg)):
            raise SubtitleUnavailable('Pinned local tool paths required')
        self.tool = tool
        self.prepare_lock = threading.Lock()

    @contextmanager
    def _movie(self, imdb):
        if not isinstance(imdb, str) or not IMDB.fullmatch(imdb):
            raise SubtitleUnavailable('Invalid movie ID')
        if hasattr(self.index, 'require_not_removed'):
            self.index.require_not_removed(imdb)
        path = self.index.resolve(imdb)
        if path is None:
            raise SubtitleUnavailable('Indexed movie is unavailable')
        path = Path(path)
        expected_parent = Path(self.index.root) / 'Movies'
        if path.parent != expected_parent or not re.fullmatch(re.escape(imdb) + r'\.[0-9]{4}\.(?:mkv|mp4)', path.name):
            raise SubtitleUnavailable('Indexed movie path is invalid')
        _directory(path.parent)
        parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
            try:
                info = os.fstat(fd)
                key = _fingerprint(info)
                if _fingerprint(os.stat(path.name, dir_fd=parent, follow_symlinks=False)) != key:
                    raise SubtitleUnavailable('Movie identity changed')
                yield fd, key
                if self.index.resolve(imdb) != path or _fingerprint(os.fstat(fd)) != key:
                    raise SubtitleUnavailable('Movie identity changed')
                if _fingerprint(os.stat(path.name, dir_fd=parent, follow_symlinks=False)) != key:
                    raise SubtitleUnavailable('Movie replaced during subtitle operation')
                if hasattr(self.index, 'require_not_removed'):
                    self.index.require_not_removed(imdb)
            finally:
                os.close(fd)
        finally:
            os.close(parent)

    def _read(self, name, cap):
        _directory(self.directory, private=True)
        if '/' in name or '\\' in name or name.startswith('.'):
            raise SubtitleUnavailable('Invalid cache key')
        fd = os.open(self.directory / name, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > cap:
                raise SubtitleUnavailable('Invalid cache file')
            with os.fdopen(fd, 'rb', closefd=False) as stream:
                data = stream.read(cap + 1)
            if len(data) > cap:
                raise SubtitleUnavailable('Cache payload too large')
            return data
        finally:
            os.close(fd)

    def _write(self, name, data):
        _directory(self.directory, private=True)
        if len(data) > MAX_TEXT or '/' in name or '\\' in name:
            raise SubtitleUnavailable('Invalid cache output')
        entries = list(self.directory.iterdir())
        if len(entries) > 10000 or sum(p.lstat().st_size for p in entries) + len(data) > CACHE_BUDGET:
            raise SubtitleUnavailable('Private subtitle cache is full')
        temporary = self.directory / ('.part-' + secrets.token_hex(12))
        fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.directory / name)
        finally:
            temporary.unlink(missing_ok=True)

    def _probe(self, fd):
        raw = self.tool([self.ffprobe, '-v', 'error', '-protocol_whitelist', 'file,pipe',
            '-select_streams', 's', '-show_entries',
            'stream=index,codec_name:stream_tags=language,title:stream_disposition=default,forced',
            '-of', 'json', '/proc/self/fd/' + str(fd)], fd, cap=MAX_META, timeout=15)
        try:
            streams = json.loads(raw)['streams']
        except (ValueError, KeyError, TypeError) as exc:
            raise SubtitleUnavailable('Invalid subtitle metadata') from exc
        if not isinstance(streams, list) or len(streams) > MAX_TRACKS:
            raise SubtitleUnavailable('Too many subtitle tracks')
        result = []
        for stream in streams:
            if not isinstance(stream, dict) or stream.get('codec_name') not in TEXT_CODECS:
                continue  # bitmap subtitles stay embedded; no fake text/OCR conversion
            index = stream.get('index')
            if type(index) is not int or not 0 <= index <= 4095:
                continue
            tags = stream.get('tags') or {}
            language = tags.get('language', 'und')
            language = language.lower() if isinstance(language, str) else 'und'
            if not re.fullmatch(r'[a-z]{3}', language):
                language = 'und'
            flags = stream.get('disposition') or {}
            title = _label(tags.get('title'))
            forced = flags.get('forced') == 1
            sdh = bool(re.search(r'\b(?:sdh|cc|hearing.impaired)\b', title, re.I))
            label = title or language
            if forced and 'forced' not in label.lower(): label += ' [Forced]'
            if sdh and not re.search(r'\b(?:sdh|cc)\b', label, re.I): label += ' [SDH]'
            result.append({'index': index, 'lang': language, 'label': label,
                           'forced': forced, 'hearingImpaired': sdh})
        return result

    def prepare(self, imdb, *, languages=None, max_tracks=8):
        """Explicit local prewarming. HTTP reads NEVER invoke this method.

        languages=None retains every available language up to max_tracks;
        an operator may pass {'eng','hin'} without changing app preferences.
        """
        if type(max_tracks) is not int or not 1 <= max_tracks <= MAX_TRACKS:
            raise SubtitleUnavailable('Invalid extraction budget')
        if languages is not None and (not isinstance(languages, (set, frozenset)) or
                any(not isinstance(x, str) or not re.fullmatch(r'[a-z]{3}', x) for x in languages)):
            raise SubtitleUnavailable('Invalid language set')
        if not self.prepare_lock.acquire(blocking=False):
            raise SubtitleUnavailable('Subtitle preparation already active')
        try:
            with self._movie(imdb) as (fd, key):
                tracks = self._probe(fd)
                if languages is not None:
                    tracks = [x for x in tracks if x['lang'] in languages]
                output = []
                for track in tracks[:max_tracks]:
                    tid = key + '-s' + str(track['index'])
                    existing = None
                    try: existing = _vtt(self._read(tid + '.vtt', MAX_TEXT))
                    except (OSError, ValueError): pass
                    if existing is None:
                        raw = self.tool([self.ffmpeg, '-nostdin', '-v', 'error', '-copyts',
                            '-protocol_whitelist', 'file,pipe', '-i', '/proc/self/fd/' + str(fd),
                            '-map', '0:' + str(track['index']), '-vn', '-an', '-dn',
                            '-c:s', 'webvtt', '-f', 'webvtt', 'pipe:1'], fd, cap=MAX_TEXT, timeout=90)
                        existing = _vtt(raw)
                        self._write(tid + '.vtt', existing)
                    output.append(dict(track, id=tid, sha256=hashlib.sha256(existing).hexdigest()))
            # Commit listing only after the source still matches; interrupted work is invisible.
            self._write(key + '.json', json.dumps({'version': 1, 'movie': imdb,
                'fingerprint': key, 'tracks': output}, ensure_ascii=False).encode())
            return self.tracks(imdb)
        finally:
            self.prepare_lock.release()

    def _manifest(self, imdb, key):
        try: doc = json.loads(self._read(key + '.json', MAX_META))
        except FileNotFoundError: return []
        if not isinstance(doc, dict) or doc.get('movie') != imdb or doc.get('fingerprint') != key or doc.get('version') != 1:
            raise SubtitleUnavailable('Invalid subtitle cache metadata')
        tracks = doc.get('tracks')
        if not isinstance(tracks, list) or len(tracks) > MAX_TRACKS:
            raise SubtitleUnavailable('Invalid subtitle list')
        seen = set()
        for t in tracks:
            if not isinstance(t, dict) or not isinstance(t.get('id'), str) or not TRACK.fullmatch(t['id']) or not t['id'].startswith(key + '-s') or t['id'] in seen:
                raise SubtitleUnavailable('Invalid subtitle track ID')
            if not isinstance(t.get('lang'), str) or not re.fullmatch(r'[a-z]{3}', t['lang']) or not isinstance(t.get('sha256'), str) or not re.fullmatch(r'[a-f0-9]{64}', t['sha256']):
                raise SubtitleUnavailable('Invalid subtitle descriptor')
            if not isinstance(t.get('label'), str) or t['label'] != _label(t['label']):
                raise SubtitleUnavailable('Invalid subtitle label')
            seen.add(t['id'])
        return tracks

    def tracks(self, imdb):
        with self._movie(imdb) as (_, key):
            result = []
            for t in self._manifest(imdb, key):
                try: content = self._read(t['id'] + '.vtt', MAX_TEXT)
                except FileNotFoundError: continue
                if hashlib.sha256(content).hexdigest() != t['sha256']:
                    raise SubtitleUnavailable('Subtitle cache integrity failed')
                result.append({k: t[k] for k in ('id', 'lang', 'label', 'forced', 'hearingImpaired')})
        return result

    def content(self, imdb, tid):
        if not isinstance(tid, str) or not TRACK.fullmatch(tid):
            raise SubtitleUnavailable('Invalid track ID')
        with self._movie(imdb) as (_, key):
            track = next((t for t in self._manifest(imdb, key) if t['id'] == tid), None)
            if track is None:
                raise SubtitleUnavailable('Subtitle is stale or unavailable')
            content = _vtt(self._read(tid + '.vtt', MAX_TEXT))
            if hashlib.sha256(content).hexdigest() != track['sha256']:
                raise SubtitleUnavailable('Subtitle cache integrity failed')
        return content


def attach_subtitle_routes(app, cache, *, authorize):
    """Call explicitly after the existing factory's route filter; default is absent.

    The unchanged outer RelayAuth is still required. authorize must be the
    existing trusted principal validator, never a new public-header shortcut.
    """
    from fastapi import HTTPException, Request
    from fastapi.responses import JSONResponse, Response
    if not callable(authorize):
        raise ValueError('Existing authorization callback required')

    def guard(request):
        if not authorize(request):
            raise HTTPException(403, 'Existing owner session required')
        raw = request.scope.get('raw_path', b'')
        if b'%' in raw or b'..' in raw or request.url.query:
            raise HTTPException(404, 'Subtitle unavailable')

    @app.get('/movie-night/api/subtitles/{imdb}')
    def list_subtitles(imdb: str, request: Request):
        guard(request)
        try:
            result = cache.tracks(imdb)
            return JSONResponse({'tracks': result}, headers=SAFE_HEADERS)
        except (ValueError, OSError, KeyError):
            raise HTTPException(404, 'Subtitle unavailable')

    @app.api_route('/movie-night/subtitle-files/{imdb}/{tid}.vtt', methods=['GET', 'HEAD'])
    def subtitle_file(imdb: str, tid: str, request: Request):
        guard(request)
        try: content = cache.content(imdb, tid)
        except (ValueError, OSError, KeyError):
            raise HTTPException(404, 'Subtitle unavailable')
        headers = dict(SAFE_HEADERS, **{'Content-Length': str(len(content))})
        return Response(b'' if request.method == 'HEAD' else content,
                        media_type='text/vtt', headers=headers)
