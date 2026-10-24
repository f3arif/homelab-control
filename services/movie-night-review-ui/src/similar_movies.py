"""Explicit reference-movie searches. Public metadata only; never acquire media."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import quote
from collections import Counter
import fcntl
import json
import math
import os
import re
import secrets
import tempfile
import threading
import time
import unicodedata

from discovery_policy import normalize, screened, clean_text
from genre_settings import genres_of
from metadata_discovery import CinemetaDiscovery, DiscoveryUnavailable
from movie_night import shortlist
from movie_presentation import ID, normalize_info


def query_text(value):
    if not isinstance(value, str) or not 2 <= len(value.strip()) <= 120 or any(unicodedata.category(c).startswith('C') for c in value):
        raise ValueError('Enter a movie title between 2 and 120 characters.')
    return ' '.join(value.split())


def reference(meta):
    if not isinstance(meta, dict) or not ID.fullmatch(str(meta.get('id', ''))) or meta.get('type') != 'movie' or meta.get('imdb_id', meta['id']) != meta['id'] or not clean_text(meta.get('name'), 160):
        return None
    year = str(meta.get('releaseInfo', meta.get('year', '')))
    return {'id': meta['id'], 'name': meta['name'], 'releaseInfo': year if re.fullmatch(r'\d{4}', year) else ''}


def title_key(value):
    value = ''.join(c for c in unicodedata.normalize('NFKD', value.casefold())
                    if not unicodedata.combining(c))
    return ' '.join(re.findall(r'[^\W_]+', value))


def rank_titles(items, query):
    # Rank the bounded provider pool before limiting it. Provider popularity alone
    # can bury a short title under many longer titles that share its prefix.
    year = ''
    dated = re.fullmatch(r'(.+?)\s+[\[(]?((?:18|19|20|21)\d{2})[\])]?', query)
    if dated:
        query, year = dated.groups()
    key = title_key(query)

    def score(item):
        name = title_key(item['name'])
        if key and name == key:
            match = 0
        elif key and name.startswith(key):
            match = 1
        elif key and (' ' + key) in name:
            match = 2
        else:
            match = 3
        # Preserve provider order for equally relevant titles, including aliases
        # whose displayed title does not contain the query.
        return (match, bool(year and item['releaseInfo'] != year),
                len(name) - len(key) if match == 1 else 0)

    return sorted(items, key=score)


# Generic synopsis words do not count as evidence of a similar story.
STOP = set('about after again against also another around away back becomes before being between both come comes could days does during each even ever every family finds first from gets goes have having help herself himself into just life lives living made make makes many more most much must mysterious needs never next only other over past people person place real same secret secrets several some someone something soon story take takes taking than that their them then there these they this those through time together tries trying turns under very wants were what when where which while whose will with within woman world would year years young team project task plan idea work tragic dangerous mission'.split())


def words(meta):
    text = meta.get('description', '')
    if not isinstance(text, str) or len(text) > 3000:
        return set()
    return {w[:-1] if len(w) > 5 and w.endswith('s') and not w.endswith(('ss', 'us', 'is')) else w
            for w in re.findall(r'[^\W\d_]{4,}', text.casefold()) if w not in STOP}


def people(meta, key):
    value = meta.get(key, [])
    return {n for n in value[:12] if clean_text(n, 100)} if isinstance(value, list) else set()


def related_score(seed, meta, frequency=None, total=1):
    common = genres_of(seed) & genres_of(meta)
    if not common:
        return 0, []
    shared = words(seed) & words(meta)
    frequency = frequency or {}
    distinctive = sorted(shared, key=lambda w: (frequency.get(w, 0), w))[:4]
    narrative = sum(math.log(1 + total / (1 + frequency.get(w, 0))) for w in distinctive)
    directors = sorted(people(seed, 'director') & people(meta, 'director'))
    cast = sorted(people(seed, 'cast') & people(meta, 'cast'))
    reasons = ['Shared genres: ' + ', '.join(sorted(common))]
    if distinctive:
        reasons.append('Shared synopsis words: ' + ', '.join(distinctive))
    if directors:
        reasons.append('Same director: ' + ', '.join(directors[:2]))
    if cast:
        reasons.append('Shared cast: ' + ', '.join(cast[:2]))
    if not distinctive and not directors and not cast:
        reasons.append('Genre match only; no closer story connection found.')
    genre_score = len(common) / len(genres_of(seed) | genres_of(meta))
    return 3 * genre_score + min(4, narrative) + 6 * bool(directors) + min(2, len(cast)), reasons


class CinemetaSimilar:
    def __init__(self, metadata=None):
        self.metadata = metadata or CinemetaDiscovery()

    def search(self, query):
        query = query_text(query)
        data = self.metadata.get('/catalog/movie/top/search=' + quote(query, safe='') + '.json', time.monotonic() + 20)
        metas = data.get('metas')
        if not isinstance(metas, list):
            raise DiscoveryUnavailable('Invalid title search')
        result = {}
        for meta in metas[:100]:
            item = reference(meta)
            if item:
                result.setdefault(item['id'], item)
        return rank_titles(result.values(), query)[:40]

    def find(self, imdb, settings):
        deadline = time.monotonic() + 55
        seed = self.metadata.get('/meta/movie/' + imdb + '.json', deadline).get('meta')
        chosen = reference(seed)
        if not chosen or chosen['id'] != imdb or not genres_of(seed):
            raise ValueError('Details for this reference movie are unavailable. Choose another title.')
        # A reference can predate 2016 or be watched/excluded. Only results must qualify.
        genres = sorted(genres_of(seed) - set(settings['excluded']))
        supported = [g for g in genres if g not in ('Music', 'Musical')]
        paths = ['/catalog/movie/top/genre=' + quote(g, safe='') + '.json' for g in supported[:3]]
        paths += ['/catalog/movie/top/genre=' + quote(g, safe='') + '&skip=100.json' for g in supported[:2]]
        if genres and not paths:
            paths = ['/catalog/movie/top.json']
        candidates = {}; failures = 0
        for path in paths:
            try:
                metas = self.metadata.get(path, deadline).get('metas')
                if not isinstance(metas, list):
                    raise DiscoveryUnavailable('Invalid catalog')
                for meta in metas[:100]:
                    row = normalize(meta, genre_settings=settings)
                    if row and row['id'] != imdb and genres_of(seed) & genres_of(row):
                        candidates.setdefault(row['id'], (meta, row))
            except DiscoveryUnavailable:
                failures += 1
        frequency = Counter(w for meta, _ in candidates.values() for w in words(meta))
        ordered = sorted(candidates.values(), key=lambda pair: (-related_score(seed, pair[0], frequency, len(candidates))[0], pair[1]['id']))
        verified = []
        for meta, catalog in ordered[:18]:
            if time.monotonic() >= deadline:
                break
            try:
                detail = self.metadata.get('/meta/movie/' + catalog['id'] + '.json', deadline).get('meta')
            except DiscoveryUnavailable:
                failures += 1
                continue
            row = normalize(detail, genre_settings=settings)
            if not row or row['id'] != catalog['id']:
                continue
            row['discoveryEvidence']['genres'] = list(dict.fromkeys(catalog['genres'] + row['genres']))
            row = normalize(row['discoveryEvidence'], genre_settings=settings)
            if not row:
                continue
            score, reasons = related_score(seed, detail, frequency, len(candidates))
            if score <= 0:
                continue
            row['presentation'] = normalize_info(detail, row['id'])
            verified.append((score, row, reasons))
            if len(verified) >= 12:
                break
        if not verified and failures:
            raise DiscoveryUnavailable('Metadata provider unavailable')
        verified.sort(key=lambda item: (-item[0], item[1]['id']))
        return {'reference': chosen, 'rows': [r for _, r, _ in verified],
                'reasons': {r['id']: reason for _, r, reason in verified},
                'partial': bool(failures or time.monotonic() >= deadline)}


class SuggestionStore:
    """Owner-added metadata, separate from editorial publication and saved choices."""
    def __init__(self, state):
        self.path = Path(state) / 'similar-suggestions.json'

    def read(self):
        if self.path.is_symlink():
            raise ValueError('Search suggestions could not be read.')
        if not self.path.exists():
            return []
        with self.path.open('rb') as stream:
            raw = stream.read(750001)
        if len(raw) > 750000:
            raise ValueError('Search suggestions could not be read.')
        data = json.loads(raw)
        rows = data.get('movies') if isinstance(data, dict) else None
        if not isinstance(rows, list) or len(rows) > 100 or any(not isinstance(r, dict) or not ID.fullmatch(str(r.get('id', ''))) for r in rows):
            raise ValueError('Search suggestions could not be read.')
        return rows

    def merge(self, payload):
        rows = self.read()
        unique = {r['id']: r for r in rows}
        for row in payload.get('movies', []):
            if isinstance(row, dict) and isinstance(row.get('id'), str):
                unique.setdefault(row['id'], row)
        return dict(payload, movies=list(unique.values()), requestedSuggestionIds=[r['id'] for r in rows])

    def add(self, row):
        # A second writer must not lose another device's newly added title.
        lock_path = self.path.with_suffix('.lock')
        with os.fdopen(os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            rows = self.read()
            if any(r == row for r in rows):
                return
            rows = [r for r in rows if r['id'] != row['id']]
            if len(rows) >= 100:
                raise ValueError('Your saved search suggestions are full. No existing choices were changed.')
            raw = json.dumps({'version': 1, 'movies': [row] + rows}, ensure_ascii=False).encode()
            if len(raw) > 750000:
                raise ValueError('Your saved search suggestions are full. No existing choices were changed.')
            fd, name = tempfile.mkstemp(prefix='.similar-', dir=self.path.parent)
            try:
                with os.fdopen(fd, 'wb') as stream:
                    stream.write(raw); stream.flush(); os.fsync(stream.fileno())
                os.replace(name, self.path)
                directory = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY)
                try: os.fsync(directory)
                finally: os.close(directory)
            finally:
                if os.path.exists(name): os.unlink(name)


class SimilarMovies:
    def __init__(self, controller, source=None):
        self.controller = controller
        self.source = source or CinemetaSimilar()
        self.store = SuggestionStore(controller.db.parent)
        self.pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix='movie-similar')
        self.jobs = {}; self.lock = threading.RLock()

    def close(self):
        self.pool.shutdown(wait=True, cancel_futures=True)

    def start(self, principal, kind, key, call, revision=None):
        with self.lock:
            now = time.monotonic()
            for job_id, job in list(self.jobs.items()):
                if now - job['created'] > 900 and job['future'].done():
                    del self.jobs[job_id]
            for job_id, job in self.jobs.items():
                if job['principal'] == principal and job['kind'] == kind and job['key'] == key and job['revision'] == revision:
                    return {'jobId': job_id, 'state': 'searching'}
            if sum(not j['future'].done() for j in self.jobs.values()) >= 2:
                raise ValueError('Two movie searches are already running. Try again shortly.')
            if len(self.jobs) >= 24:
                del self.jobs[next(k for k, v in self.jobs.items() if v['future'].done())]
            job_id = secrets.token_hex(16)
            self.jobs[job_id] = dict(principal=principal, kind=kind, key=key, revision=revision, created=now, future=self.pool.submit(call))
            return {'jobId': job_id, 'state': 'searching'}

    def entry(self, principal, job_id, kind=None):
        job = self.jobs.get(str(job_id))
        if not job or job['principal'] != principal or time.monotonic() - job['created'] > 900 or (kind and job['kind'] != kind):
            raise ValueError('This search has expired. Search for the movie again.')
        return job

    def result(self, principal, job_id, kind):
        job = self.entry(principal, job_id, kind)
        if not job['future'].done():
            raise ValueError('The movie search is still running.')
        try:
            return job, job['future'].result()
        except DiscoveryUnavailable:
            # Failed searches can be explicitly retried immediately.
            with self.lock: self.jobs.pop(str(job_id), None)
            raise ValueError('Movie information is temporarily unavailable. Please search again.') from None

    def eligible(self, rows, principal):
        c = self.controller
        ratings = c.feedback.ratings(principal)
        payload = {'generatedEpoch': int(c.clock()), 'movies': rows,
                   'knownSeenIds': c.shortlist_payload().get('knownSeenIds', [])}
        return [r for r in shortlist(payload, int(c.clock()), c.seen_policy, limit=None, genre_settings=c.genre_settings.read())
                if ratings.get(r['id'], {}).get('value') not in ('seen', 'dislike')]

    def status(self, principal, job_id):
        job = self.entry(principal, job_id)
        if not job['future'].done():
            return {'jobId': job_id, 'state': 'searching'}
        job, result = self.result(principal, job_id, job['kind'])
        if job['kind'] == 'titles':
            return {'jobId': job_id, 'state': 'ready', 'titles': result}
        if job['revision'] != self.controller.genre_settings.read()['revision']:
            raise ValueError('Your genres changed. Find similar movies again to use the latest settings.')
        existing = {r['id'] for r in self.controller.review_pool()}
        movies = [dict(r, similarReasons=result['reasons'][r['id']], inShortlist=r['id'] in existing)
                  for r in self.eligible(result['rows'], principal)]
        return {'jobId': job_id, 'state': 'ready', 'reference': result['reference'], 'movies': movies, 'partial': result.get('partial', False)}

    def action(self, principal, data):
        c = self.controller
        if not c.review_enabled:
            raise ValueError('Movie review is disabled pending activation.')
        c.feedback.principal(principal)
        action = data['action']
        if action == 'search-titles':
            query = query_text(data.get('query'))
            return self.start(principal, 'titles', query.casefold(), lambda: self.source.search(query))
        if action == 'similar-status':
            with c.lock: return self.status(principal, data.get('jobId'))
        if action == 'find-similar':
            _, titles = self.result(principal, data.get('jobId'), 'titles')
            imdb = data.get('imdb')
            if imdb not in [r['id'] for r in titles]:
                raise ValueError('Choose a movie from the title search results.')
            settings = c.genre_settings.read()
            return self.start(principal, 'similar', imdb, lambda: self.source.find(imdb, settings), settings['revision'])
        if action == 'add-similar':
            with c.lock:
                job_id = data.get('jobId'); imdb = data.get('imdb')
                view = self.status(principal, job_id)
                if imdb not in [r['id'] for r in view.get('movies', [])]:
                    raise ValueError('This suggestion is no longer eligible. Search again with your current settings.')
                _, result = self.result(principal, job_id, 'similar')
                row = next(r for r in result['rows'] if r['id'] == imdb)
                self.store.add(row)
                return c.review(principal)
        raise ValueError('Unknown movie search action.')
