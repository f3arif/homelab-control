"""Optional public movie details. Never change screening, choices or acquisition."""
import json
import math
import re
import time

ID = re.compile(r'tt\d{5,12}\Z')
BASE = 'https://v3-cinemeta.strem.io/meta/movie/'
POSTERS = '/movie-night/posters/'


def _text(value, limit):
    return value.strip() if isinstance(value, str) and len(value) <= limit and not any(ord(c) < 32 for c in value) else ''


def _names(value, count):
    if isinstance(value, str):
        value = [value]
    return [clean for name in value[:count] if (clean := _text(name, 100))] if isinstance(value, list) else []


def normalize_info(meta, imdb, now=None):
    if not isinstance(imdb, str) or not ID.fullmatch(imdb) or not isinstance(meta, dict):
        return None
    if meta.get('id') != imdb or meta.get('imdb_id', imdb) != imdb or meta.get('type') != 'movie':
        return None
    info = {'provider': 'Cinemeta', 'id': imdb, 'fetchedEpoch': int(time.time()) if now is None else int(now),
            'director': _names(meta.get('director'), 2), 'cast': _names(meta.get('cast'), 3)}
    summary = meta.get('description')
    if isinstance(summary, str) and 0 < len(summary) <= 3000:
        info['summary'] = ' '.join(summary.split())
    for trailer in meta.get('trailers', []) if isinstance(meta.get('trailers'), list) else []:
        if isinstance(trailer, dict) and trailer.get('type') == 'Trailer' and re.fullmatch(r'[A-Za-z0-9_-]{11}', str(trailer.get('source', ''))):
            info['trailerId'] = trailer['source']
            break
    rating = meta.get('imdbRating')
    if isinstance(rating, (int, float, str)) and not isinstance(rating, bool):
        try:
            number = float(rating)
            if math.isfinite(number) and 0 <= number <= 10:
                info['imdbRating'] = round(number, 1)
        except (ValueError, OverflowError):
            pass
    runtime = meta.get('runtime')
    match = re.fullmatch(r'(\d{1,4})\s*min', runtime) if isinstance(runtime, str) else None
    minutes = int(match.group(1)) if match else runtime if type(runtime) is int else None
    if minutes is not None and 1 <= minutes <= 1500:
        info['runtimeMinutes'] = minutes
    year = str(meta.get('releaseInfo', ''))
    if re.fullmatch(r'\d{4}', year):
        info['sourceYear'] = year
    return info


def display_fields(imdb, info=None, now=None):
    if not isinstance(imdb, str) or not ID.fullmatch(imdb):
        return {}
    result = {'poster': POSTERS + imdb + '.img', 'imdbUrl': 'https://www.imdb.com/title/' + imdb + '/', 'movieInfo': {}}
    now = int(time.time()) if now is None else int(now)
    if not isinstance(info, dict) or info.get('provider') != 'Cinemeta' or info.get('id') != imdb:
        return result
    fetched = info.get('fetchedEpoch')
    if type(fetched) is not int or not 0 <= now - fetched <= 30 * 86400:
        return result
    clean = {'provider': 'Cinemeta', 'fetchedEpoch': fetched, 'sourceUrl': BASE + imdb + '.json',
             'director': _names(info.get('director'), 2), 'cast': _names(info.get('cast'), 3)}
    summary = _text(info.get('summary'), 3000)
    if summary:
        clean['summary'] = summary
    trailer_id = info.get('trailerId')
    if isinstance(trailer_id, str) and re.fullmatch(r'[A-Za-z0-9_-]{11}', trailer_id):
        clean['metadataTrailer'] = {'url': 'https://www.youtube.com/watch?v=' + trailer_id, 'provider': 'Cinemeta'}
    rating = info.get('imdbRating')
    if type(rating) in (int, float) and math.isfinite(rating) and 0 <= rating <= 10:
        clean['imdbRating'] = round(rating, 1)
    minutes = info.get('runtimeMinutes')
    if type(minutes) is int and 1 <= minutes <= 1500:
        clean['runtimeMinutes'] = minutes
    if re.fullmatch(r'\d{4}', str(info.get('sourceYear', ''))):
        clean['sourceYear'] = info['sourceYear']
    result['movieInfo'] = clean
    return result


def with_cached_info(payload, path):
    """Only bounded local reads on the request path; the cache is optional."""
    try:
        with path.open('rb') as stream:
            raw = stream.read(262145)
        if len(raw) > 262144:
            return payload
        cache = json.loads(raw).get('movies', {})
        if not isinstance(cache, dict) or len(cache) > 200:
            return payload
    except (OSError, ValueError, TypeError, AttributeError):
        return payload
    result = dict(payload)
    for key in ('movies', 'retainedIneligibleSelections'):
        if not isinstance(payload.get(key), list):
            continue
        rows = []
        for row in payload[key]:
            if isinstance(row, dict):
                row = dict(row)
                new, old = cache.get(row.get('id')), row.get('presentation')
                if isinstance(new, dict) and (not isinstance(old, dict) or
                        (type(new.get('fetchedEpoch')) is int and type(old.get('fetchedEpoch')) is int and new['fetchedEpoch'] > old['fetchedEpoch'])):
                    row['presentation'] = new
            rows.append(row)
        result[key] = rows
    return result
