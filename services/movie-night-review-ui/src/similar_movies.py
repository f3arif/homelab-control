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
from movie_night import shortlist, present_movie
from movie_presentation import ID, normalize_info, display_fields
from tmdb_signals import TmdbSignals


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
STOP = set('about after again against also another around attempt attempts away back becomes before being between both come comes could days does down during each even ever every family finds first from gets goes have having help herself himself into just life lives living made make makes many more most much must mysterious needs never next only other over past people person place real same secret secrets several some someone something soon story take takes taking than that their them then there these they this those through time together tries trying turns under very wants were what when where which while whose will with within woman world would year years young team project task plan idea work tragic dangerous mission'.split())
# Common plot verbs and connectors: real in many synopses, never a story theme.
STOP |= set('forced force drawn draw group groups hope hopes overcome route international must face faces begin begins find discover discovers follow follows keep leave leaves left look order return returns start starts final last local strange unexpected friend friends home town city night nights everything nothing themselves along among across without enough little long new old big great high better best end ends way ways still'.split())


def proper_nouns(text):
    # Capitalized words that are not sentence starts are names and places
    # ("Los Angeles", "Shanghai"); they describe setting, not the kind of movie.
    found = set()
    for m in re.finditer(r'[^\W\d_]{4,}', text):
        before = text[:m.start()].rstrip()
        if m.group()[0].isupper() and before and before[-1] not in '.!?:;"\'(\u201c':
            found.add(m.group().casefold())
    return found


def stem(w):
    return w[:-1] if len(w) > 5 and w.endswith('s') and not w.endswith(('ss', 'us', 'is')) else w


def words(meta):
    text = meta.get('description', '')
    if not isinstance(text, str) or len(text) > 3000:
        return set()
    proper = proper_nouns(text)
    return {stem(w) for w in re.findall(r'[^\W\d_]{4,}', text.casefold()) if w not in STOP and w not in proper}


def title_words(meta):
    name = meta.get('name', '')
    return {stem(w) for w in re.findall(r'[^\W\d_]{4,}', name.casefold())} if isinstance(name, str) else set()


def people(meta, key):
    value = meta.get(key, [])
    return {n for n in value[:12] if clean_text(n, 100)} if isinstance(value, list) else set()


def countries(meta):
    value = meta.get('country', '')
    return {n.strip() for n in value.split(',')[:5] if clean_text(n.strip(), 80)} if isinstance(value, str) and len(value) <= 400 else set()


def rare_limit(total):
    # A word counts as story evidence only when few movies in the pool use it.
    return max(2, 0.04 * total) if total > 1 else float('inf')


def related_score(seed, meta, frequency=None, total=1):
    common = genres_of(seed) & genres_of(meta)
    frequency = frequency or {}
    limit = rare_limit(total)
    seed_words = words(seed)
    shared = {w for w in seed_words & words(meta) if frequency.get(w, 0) <= limit}
    # Shared TMDB keywords ("shark", "deep sea") are curated story themes.
    themes = sorted(set(seed.get('themes', ())) & set(meta.get('themes', ())))[:4]
    distinctive = sorted(shared - set(themes), key=lambda w: (frequency.get(w, 0), w))[:4]
    # A seed story word in the candidate's own title ("Shark Night") is strong evidence.
    titled = sorted(seed_words & title_words(meta) - STOP - set(distinctive) - set(themes))[:2]
    weight = lambda w: math.log(1 + total / (1 + frequency.get(w, 0)))
    narrative = sum(weight(w) for w in distinctive + titled) + 3 * len(themes)
    story = len(distinctive) + len(titled) + len(themes)
    directors = sorted(people(seed, 'director') & people(meta, 'director'))
    cast = sorted(people(seed, 'cast') & people(meta, 'cast'))
    genre_score = len(common) / max(1, len(genres_of(seed) | genres_of(meta)))
    people_link = bool(directors or cast)
    # One shared genre, one stray synopsis word, a place name or a country can
    # never carry a match. Story evidence needs a genre plus two rare story words
    # (one may be in the title); a genre-only fallback needs most genres and ranks last.
    genre_only = not people_link and not themes and story < 2 and len(common) >= 2 and genre_score >= 2 / 3
    # One TMDB theme alone ("sociopath") is weak: it needs two shared genres, or the
    # theme must be central enough to appear in the candidate's own synopsis or title.
    own = words(meta) | title_words(meta)
    weak_theme = (themes and not people_link and not distinctive and not titled and len(themes) == 1
                  and len(common) < 2 and not all(stem(w) in own for w in re.findall(r'[^\W\d_]{4,}', themes[0])))
    # A lone shared actor with no genre, theme, story or director link is not a match.
    lone_cast = len(cast) == 1 and not directors and not themes and not story and len(common) < 2
    if weak_theme or lone_cast:
        return 0, []
    if not people_link and not genre_only and not (story >= 2 and (distinctive or themes) and common) and not (themes and common) and len(distinctive) < 3:
        return 0, []
    reasons = ['Shared genres: ' + ', '.join(sorted(common))] if common else []
    if titled and not genre_only:
        reasons.append('Story element in title: ' + ', '.join(titled))
    if themes:
        reasons.append('Shared themes: ' + ', '.join(themes))
    if distinctive and not genre_only:
        reasons.append('Shared story words: ' + ', '.join(distinctive))
    if directors:
        reasons.append('Same director: ' + ', '.join(directors[:2]))
    if cast:
        reasons.append('Shared cast: ' + ', '.join(cast[:2]))
    country = sorted(countries(seed) & countries(meta))
    if country:
        reasons.append('Same country: ' + ', '.join(country[:2]))
    if genre_only:
        reasons.append('Genre match only; no closer story connection found.')
        return genre_score + 0.25 * bool(country), reasons
    return (3 * genre_score + min(6, narrative) + 6 * bool(directors)
            + 1.5 * min(2, len(cast)) + 0.5 * bool(country)), reasons


RESULT_LIMIT = 50   # up to 50 verified matches; never padded with weak picks
DETAIL_LIMIT = 120  # Cinemeta detail checks per search


class CinemetaSimilar:
    def __init__(self, metadata=None, tmdb=None):
        # TMDB is optional: only the production service (no injected metadata)
        # reads TMDB_API_KEY from its environment.
        self.tmdb = tmdb if tmdb is not None or metadata is not None else TmdbSignals.from_env()
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

    def admission(self, imdb):
        """Resolve a directly chosen movie; client-supplied metadata is never trusted."""
        if not isinstance(imdb, str) or not ID.fullmatch(imdb):
            raise ValueError('Choose a valid movie from the search results.')
        meta = self.metadata.get('/meta/movie/' + imdb + '.json', time.monotonic() + 20).get('meta')
        chosen = reference(meta)
        row = normalize(meta, unrestricted=True)
        if not chosen or chosen['id'] != imdb or not row or row['id'] != imdb:
            raise ValueError('This movie does not have verified, released movie metadata yet.')
        row['presentation'] = normalize_info(meta, imdb)
        return row

    def preview(self, imdb):
        if not isinstance(imdb, str) or not ID.fullmatch(imdb):
            raise ValueError('Choose a movie from the title search results.')
        meta = self.metadata.get('/meta/movie/' + imdb + '.json', time.monotonic() + 15).get('meta')
        chosen = reference(meta)
        if not chosen or chosen['id'] != imdb:
            raise DiscoveryUnavailable('Movie details unavailable')
        # Reference details are descriptive, not recommendation eligibility.
        # Existing display normalization bounds names, runtime, rating and text.
        info = display_fields(imdb, normalize_info(meta, imdb))['movieInfo']
        return dict(chosen, movieInfo=info, genres=sorted(genres_of(meta)))

    def find(self, imdb, settings=None):
        deadline = time.monotonic() + 55
        seed = self.metadata.get('/meta/movie/' + imdb + '.json', deadline).get('meta')
        chosen = reference(seed)
        if not chosen or chosen['id'] != imdb:
            raise ValueError('Details for this reference movie are unavailable. Choose another title.')
        # Explicit reference discovery is independent of saved shortlist filters.
        # Cinemeta's person searches return real filmography candidates alongside
        # literal name matches. Verify each connection from metadata before use.
        names = []
        for key, limit in (('director', 2), ('cast', 3)):
            value = seed.get(key, [])
            if isinstance(value, list):
                names += [n for n in value[:limit] if clean_text(n, 100)]
        names = list(dict.fromkeys(names))[:5]
        genres = sorted(genres_of(seed))
        supported = [g for g in genres if g not in ('Music', 'Musical')]
        failures = 0
        side = ThreadPoolExecutor(1)
        tmdb = side.submit(self.tmdb.related, imdb, deadline - 20) if self.tmdb else None

        def fetch(paths):
            nonlocal failures
            def one(path):
                try:
                    metas = self.metadata.get(path, deadline).get('metas')
                    if not isinstance(metas, list):
                        raise DiscoveryUnavailable('Invalid catalog')
                    return metas[:100]
                except DiscoveryUnavailable:
                    return None
            with ThreadPoolExecutor(6) as pool:
                results = list(pool.map(one, paths))
            failures += sum(r is None for r in results)
            return [m for r in results if r for m in r if reference(m) and reference(m)['id'] != imdb]

        # Several pages per genre form the background pool. Word rarity is measured
        # against it, so plot words common to the genre ("group") carry no weight.
        genre_paths = ['/catalog/movie/top/genre=' + quote(g, safe='') + ('&skip=%d' % skip if skip else '') + '.json'
                       for g in supported[:3] for skip in range(0, 500, 50)]
        background = {m['id']: m for m in fetch(genre_paths or ['/catalog/movie/top.json'])}
        frequency = Counter(w for meta in background.values() for w in words(meta))
        total = len(background)
        # The seed's rarest story words ("shark", "wreckage") find titles the
        # popular genre pages miss. Words seen in the genre pool come first.
        limit = rare_limit(total)
        concepts = sorted((w for w in words(seed) if frequency.get(w, 0) <= limit),
                          key=lambda w: (frequency.get(w, 0) == 0, frequency.get(w, 0), -len(w), w))[:6]
        searched = fetch(['/catalog/movie/top/search=' + quote(n, safe='') + '.json' for n in names + concepts])
        if not background:
            frequency = Counter(w for meta in {m['id']: m for m in searched}.values() for w in words(meta))
            total = len({m['id'] for m in searched})
        candidates = {}
        for meta in list(background.values()) + searched:
            # Discard literal title-only person-name search hits and weak matches.
            # Search hits carry no genres or synopsis, so a story word in the
            # title earns a detail lookup; the full details are scored below.
            score = related_score(seed, meta, frequency, total)[0]
            if not score and not meta.get('description') and set(concepts) & title_words(meta):
                score = 3
            if score > 0 and meta['id'] not in candidates:
                candidates[meta['id']] = (score, meta, reference(meta))
        ordered = [(meta, item) for _, meta, item in sorted(candidates.values(), key=lambda c: (-c[0], c[2]['id']))]
        try:
            themes, suggested = tmdb.result() if tmdb else (set(), {})
        except Exception:
            themes, suggested = set(), {}
        side.shutdown(wait=False)
        seed = dict(seed, themes=themes)
        if themes:
            # TMDB suggestions sharing a theme get a detail check ahead of the rest.
            picked = [(dict(id=i, type='movie', name=i), dict(id=i)) for i, t in suggested.items()
                      if t & themes and i != imdb][:80]
            ordered = picked + [o for o in ordered if o[1]['id'] not in suggested]
        verified = []
        def detail_of(pair):
            try:
                return self.metadata.get('/meta/movie/' + pair[1]['id'] + '.json', deadline).get('meta')
            except DiscoveryUnavailable:
                return None
        top = ordered[:DETAIL_LIMIT]
        with ThreadPoolExecutor(12) as pool:
            details = list(pool.map(detail_of, top))
        for (meta, catalog), detail in zip(top, details):
            if detail is None:
                failures += 1
                continue
            row = normalize(detail, unrestricted=True)
            if not row or row['id'] != catalog['id']:
                continue
            row['discoveryEvidence']['genres'] = list(dict.fromkeys(sorted(genres_of(meta)) + row['genres']))
            row = normalize(row['discoveryEvidence'], unrestricted=True)
            if not row:
                continue
            if catalog['id'] in suggested:
                detail = dict(detail, themes=suggested[catalog['id']])
            score, reasons = related_score(seed, detail, frequency, total)
            if score <= 0:
                continue
            row['presentation'] = normalize_info(detail, row['id'])
            verified.append((score, row, reasons))
        if not verified and failures:
            raise DiscoveryUnavailable('Metadata provider unavailable')
        verified.sort(key=lambda item: (-item[0], item[1]['id']))
        verified = verified[:RESULT_LIMIT]
        return {'reference': chosen, 'rows': [r for _, r, _ in verified],
                'reasons': {r['id']: reason for _, r, reason in verified},
                'searchScope': 'all-genres-and-years',
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

    def start(self, principal, kind, key, call, revision=None, keep_job=None):
        with self.lock:
            now = time.monotonic()
            for job_id, job in list(self.jobs.items()):
                if now - job['created'] > 900 and job['future'].done():
                    del self.jobs[job_id]
            for job_id, job in self.jobs.items():
                if job['principal'] == principal and job['kind'] == kind and job['key'] == key and job['revision'] == revision and (kind not in ('add','selection') or not job['future'].done()):
                    return {'jobId': job_id, 'state': 'searching'}
            if kind == 'preview' and any(j['kind'] == 'preview' and not j['future'].done() for j in self.jobs.values()):
                raise ValueError('Movie details are loading. Try again shortly.')
            if sum(not j['future'].done() for j in self.jobs.values()) >= 2:
                raise ValueError('Two movie searches are already running. Try again shortly.')
            if len(self.jobs) >= 24:
                # Scrolling must retain the parent title job for selection.
                del self.jobs[next(k for k, v in self.jobs.items() if k != keep_job and v['future'].done())]
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
                   'requestedSuggestionIds': [r['id'] for r in rows],
                   'knownSeenIds': c.shortlist_payload().get('knownSeenIds', [])}
        return [r for r in shortlist(payload, int(c.clock()), c.seen_policy, limit=None, genre_settings=c.genre_settings.read())
                if ratings.get(r['id'], {}).get('value') not in ('seen', 'dislike')]

    def status(self, principal, job_id):
        job = self.entry(principal, job_id)
        if not job['future'].done():
            return {'jobId': job_id, 'state': 'searching'}
        job, result = self.result(principal, job_id, job['kind'])
        if job['kind'] == 'titles':
            return {'jobId': job_id, 'state': 'ready', 'titles': result, 'previewsEnabled': True}
        if job['kind'] == 'preview':
            return {'jobId': job_id, 'state': 'ready', 'title': result}
        if job['kind'] in ('add','selection'):
            return dict(result, jobId=job_id, state='ready')
        existing = {r['id'] for r in self.controller.review_pool()}
        eligible = {r['id'] for r in self.eligible(result['rows'], principal)}
        ratings = self.controller.feedback.ratings(principal)
        now = int(self.controller.clock())
        movies = []
        for row in result['rows']:
            if not screened(row, now, unrestricted=True):
                continue
            value = ratings.get(row['id'], {}).get('value')
            block = None if row['id'] in eligible else value if value in ('seen', 'dislike') else 'known-seen'
            movies.append(dict(present_movie(row, now, 'Related movie search; all genres and years.'),
                               similarReasons=result['reasons'][row['id']], inShortlist=row['id'] in existing,
                               canAdd=not block, selectionBlock=block))
        return {'jobId': job_id, 'state': 'ready', 'reference': result['reference'], 'movies': movies,
                'searchScope': 'all-genres-and-years', 'partial': result.get('partial', False)}

    def add_title(self, principal, imdb):
        c = self.controller
        with c.lock:
            saved = next((r for r in self.store.read() if r['id'] == imdb), None)
        row = saved if saved and screened(saved, int(c.clock()), unrestricted=True) else self.source.admission(imdb)
        with c.lock:
            if not self.eligible([row], principal):
                raise ValueError('Watched and Not for me movies cannot be added. Undo that feedback first.')
            # Recheck after metadata lookup: another request may already have saved it.
            existing = next((r for r in self.store.read() if r['id'] == imdb), None)
            if existing and screened(existing, int(c.clock()), unrestricted=True):
                row = existing
            try:
                self.store.add(row)
            except (OSError, ValueError):
                raise ValueError('Movie Night could not be saved. Reload before trying again.') from None
            return {'added': True, 'alreadyAdded': existing is not None,
                    'movie': present_movie(row, int(c.clock()), 'Added to your Movie Night shortlist.')}

    def action(self, principal, data):
        c = self.controller
        if not c.review_enabled:
            raise ValueError('Movie review is disabled pending activation.')
        c.feedback.principal(principal)
        action = data['action']
        if action == 'select-download':
            from mobile_selection import MobileSelections
            imdb = data.get('imdb'); request_id = data.get('requestId'); retry = data.get('retryDownload')
            if not isinstance(imdb, str) or not ID.fullmatch(imdb):
                raise ValueError('Choose a valid movie from the search results.')
            MobileSelections.intent(request_id, retry)
            c.require_enabled()
            if not c.auto_downloads or not c.mobile_selections:
                raise ValueError('Movie Night server downloads are unavailable. Try again later.')
            def select_download():
                added = self.add_title(principal, imdb)
                selected = c.mobile_selections.select(principal, imdb, request_id, retry)
                return dict(added, **selected)
            return self.start(principal, 'selection', (imdb,request_id,retry), select_download)
        if action == 'add-title':
            imdb = data.get('imdb')
            if not isinstance(imdb, str) or not ID.fullmatch(imdb):
                raise ValueError('Choose a valid movie from the search results.')
            return self.start(principal, 'add', imdb, lambda: self.add_title(principal, imdb))
        if action == 'search-titles':
            query = query_text(data.get('query'))
            return self.start(principal, 'titles', query.casefold(), lambda: self.source.search(query))
        if action == 'similar-status':
            with c.lock: return self.status(principal, data.get('jobId'))
        if action == 'title-preview':
            with self.lock:
                parent = data.get('jobId')
                _, titles = self.result(principal, parent, 'titles')
                imdb = data.get('imdb')
                if imdb not in [r['id'] for r in titles]:
                    raise ValueError('Choose a movie from the title search results.')
                return self.start(principal, 'preview', imdb, lambda: self.source.preview(imdb), keep_job=parent)
        if action == 'find-similar':
            _, titles = self.result(principal, data.get('jobId'), 'titles')
            imdb = data.get('imdb')
            if imdb not in [r['id'] for r in titles]:
                raise ValueError('Choose a movie from the title search results.')
            return self.start(principal, 'similar', imdb, lambda: self.source.find(imdb))
        if action == 'add-similar':
            with c.lock:
                job_id = data.get('jobId'); imdb = data.get('imdb')
                view = self.status(principal, job_id)
                if imdb not in [r['id'] for r in view.get('movies', []) if r.get('canAdd')]:
                    raise ValueError('This suggestion is no longer eligible. Watched and Not for me movies cannot be added.')
                _, result = self.result(principal, job_id, 'similar')
                row = next(r for r in result['rows'] if r['id'] == imdb)
                self.store.add(row)
                return c.review(principal)
        raise ValueError('Unknown movie search action.')
