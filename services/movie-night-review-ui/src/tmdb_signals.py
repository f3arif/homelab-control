"""Optional TMDB signals for "Find movies like": candidates and shared themes.

Used only when TMDB_API_KEY is set (never logged or stored). Any failure
returns nothing, so Cinemeta-only behaviour remains the fallback.
"""
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlencode
import json
import os
import re
import time
import urllib.request

API = 'https://api.themoviedb.org/3'
IMDB = re.compile(r'tt\d{7,10}')
# Production facts, not story themes.
GENERIC = {'based on novel or book', 'woman director', 'remake', 'sequel', 'duringcreditsstinger',
           'aftercreditsstinger', 'based on true story', 'independent film', 'anime', 'live action',
           'based on comic', 'biography', 'murder', 'friendship', 'love', 'revenge', 'death', 'violence', 'control',
           'survival', 'suspense', 'thriller', 'horror', 'drama', 'action'}


class TmdbSignals:
    def __init__(self, key, opener=None, timeout=8):
        self.key, self.timeout = key, timeout
        self.opener = opener or (lambda url: urllib.request.urlopen(
            urllib.request.Request(url, headers={'accept': 'application/json'}), timeout=self.timeout).read())

    @classmethod
    def from_env(cls):
        key = os.environ.get('TMDB_API_KEY', '').strip()
        return cls(key) if re.fullmatch(r'[0-9a-f]{32}', key) else None

    def get(self, path, **query):
        query['api_key'] = self.key
        try:
            data = json.loads(self.opener(API + path + '?' + urlencode(query)))
        except Exception:
            return {}
        return data if isinstance(data, dict) else {}

    @staticmethod
    def themes(data):
        rows = (data.get('keywords') or {}).get('keywords', [])
        return {r['name'].casefold() for r in rows[:40] if isinstance(r, dict) and isinstance(r.get('name'), str)
                and len(r['name']) <= 60} - GENERIC

    def related(self, imdb, deadline, limit=120):
        """Return (seed themes, {imdb_id: themes}) for TMDB-suggested movies."""
        found = self.get('/find/' + imdb, external_source='imdb_id').get('movie_results') or []
        if not found or not isinstance(found[0].get('id'), int):
            return set(), {}
        tid = found[0]['id']
        seed = self.get('/movie/%d' % tid, append_to_response='keywords')
        themes = self.themes(seed)
        ids = [r['id'] for r in (seed.get('keywords') or {}).get('keywords', [])
               if isinstance(r, dict) and isinstance(r.get('id'), int) and r.get('name', '').casefold() in themes][:5]
        pages = []
        if ids:
            # Most-voted movies sharing a theme ("shark"): The Meg, The Shallows...
            pages += [self.get('/discover/movie', with_keywords='|'.join(map(str, ids)), page=n,
                               sort_by='vote_count.desc', include_adult='false') for n in (1, 2, 3)]
        pages += [self.get('/movie/%d/%s' % (tid, kind), page=n) for n in (1, 2) for kind in ('recommendations', 'similar')]
        order = []
        for page in pages:
            for r in (page.get('results') or [])[:20]:
                if isinstance(r, dict) and isinstance(r.get('id'), int) and r['id'] != tid and r['id'] not in order:
                    order.append(r['id'])

        def detail(mid):
            if time.monotonic() >= deadline:
                return None
            d = self.get('/movie/%d' % mid, append_to_response='keywords')
            return (d.get('imdb_id'), self.themes(d)) if IMDB.fullmatch(str(d.get('imdb_id'))) else None
        with ThreadPoolExecutor(10) as pool:
            rows = [r for r in pool.map(detail, order[:limit]) if r]
        return themes, dict(rows)
