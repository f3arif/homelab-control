"""Owner-editable genre preferences; atomic durable saves, no media side effects."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import tempfile

GENRES = ('Action', 'Adventure', 'Animation', 'Biography', 'Comedy', 'Crime',
          'Documentary', 'Drama', 'Family', 'Fantasy', 'History', 'Horror',
          'Music', 'Musical', 'Mystery', 'Romance', 'Sci-Fi', 'Sport',
          'Thriller', 'War', 'Western')
DEFAULT_INCLUDED = ('Action', 'Adventure', 'Crime', 'Horror', 'Mystery', 'Sci-Fi', 'Thriller')
DEFAULT_EXCLUDED = ('Animation', 'Drama', 'Comedy')
PATTERNS = {g: re.compile(r'\b' + re.escape(g) + r'\b', re.I) for g in GENRES}
PATTERNS.update({
    'Animation': re.compile(r'\b(?:animat(?:ion|ions|ed)|anime|cartoons?)\b', re.I),
    'Drama': re.compile(r'\b(?:dramas?|dramatic|dramed(?:y|ies))\b', re.I),
    'Comedy': re.compile(r'\b(?:comed(?:y|ies)|dramed(?:y|ies))\b', re.I),
    'Sci-Fi': re.compile(r'\b(?:sci[ -]?fi|science fiction)\b', re.I),
    'Sport': re.compile(r'\bsports?\b', re.I),
})


def defaults():
    return {'included': list(DEFAULT_INCLUDED), 'excluded': list(DEFAULT_EXCLUDED), 'revision': 0}


def validate_settings(data):
    if not isinstance(data, dict) or set(data) != {'included', 'excluded', 'revision'}:
        raise ValueError('Choose included and excluded genres from the list.')
    if type(data['revision']) is not int or not 0 <= data['revision'] < 2**53 - 1:
        raise ValueError('Reload genre settings before saving.')
    result = {'revision': data['revision']}
    for key in ('included', 'excluded'):
        values = data[key]
        if (not isinstance(values, list) or len(values) > len(GENRES)
                or any(not isinstance(v, str) or v not in GENRES for v in values)
                or len(set(values)) != len(values)):
            raise ValueError('Choose included and excluded genres from the list.')
        result[key] = list(values)
    if set(result['included']) & set(result['excluded']):
        raise ValueError('A genre cannot be both included and excluded.')
    if set(result['excluded']) == set(GENRES):
        raise ValueError('Leave at least one genre available.')
    return result


def labels(row):
    """Read all supplied genre evidence, never title or plot words."""
    if not isinstance(row, dict):
        return []
    result = []
    for data in (row, row.get('discoveryEvidence')):
        if not isinstance(data, dict):
            continue
        for key in ('genres', 'genre'):
            values = data.get(key, [])
            if isinstance(values, str):
                result.append(values)
            elif isinstance(values, list):
                result.extend(v for v in values if isinstance(v, str))
        links = data.get('links', [])
        if isinstance(links, list):
            result.extend(link.get('name', '') for link in links if isinstance(link, dict)
                          and str(link.get('category', '')).casefold() == 'genres'
                          and isinstance(link.get('name'), str))
    return result


def genres_of(row):
    values = labels(row)
    return {genre for genre, pattern in PATTERNS.items() if any(pattern.search(v) for v in values)}


def excluded_genres(row, settings=None):
    return bool(genres_of(row) & set((settings or defaults())['excluded']))


def genre_match(row, settings=None):
    settings = settings or defaults()
    genres = genres_of(row)
    if genres & set(settings['excluded']):
        return False
    if not settings['included']:
        return bool(genres)
    if genres & set(settings['included']):
        return True
    # Preserve legacy theme-only editorial rows only under the original defaults.
    return (not labels(row) and settings['included'] == list(DEFAULT_INCLUDED)
            and bool(set(row.get('fitTags', [])) & {'obsession', 'relationship tension', 'twists', 'suspense'}))


class SettingsConflict(ValueError):
    pass


class GenreSettingsStore:
    """Shared settings for this single-owner Movie Night instance, across devices."""
    def __init__(self, state):
        self.path = Path(state) / 'genre-settings.json'

    def read(self):
        if self.path.is_symlink():
            raise ValueError('Genre settings need repair; no changes were made.')
        try:
            raw = self.path.read_bytes()
        except FileNotFoundError:
            return defaults()
        try:
            if len(raw) > 8192:
                raise ValueError()
            return validate_settings(json.loads(raw))
        except (ValueError, TypeError):
            raise ValueError('Genre settings need repair; no changes were made.') from None

    @contextmanager
    def guard(self):
        path = self.path.with_suffix('.lock')
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)

    def save(self, data):
        wanted = validate_settings(data)
        with self.guard():
            current = self.read()
            if wanted['revision'] != current['revision']:
                raise SettingsConflict('Genre settings changed on another device. Reload settings and try again.')
            if all(set(wanted[k]) == set(current[k]) for k in ('included', 'excluded')):
                return current
            wanted['revision'] += 1
            fd, temp = tempfile.mkstemp(prefix='.genre-settings-', dir=self.path.parent)
            try:
                with os.fdopen(fd, 'w', encoding='utf-8') as stream:
                    json.dump(wanted, stream, ensure_ascii=False)
                    stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
                os.replace(temp, self.path)
                directory = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            finally:
                if os.path.exists(temp):
                    os.unlink(temp)
            return wanted
