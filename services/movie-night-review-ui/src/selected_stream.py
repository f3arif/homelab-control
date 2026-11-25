"""Bounded stream-card hints select an existing cached file, never a client URL."""
from pathlib import Path
import re
from download_provider import norm
from movie_night import OWNER_CAP


def basename(name):
    return str(name).replace(chr(92), '/').rsplit('/', 1)[-1]


def parse_hint(value):
    if not isinstance(value, dict) or not set(value) <= {'fileName', 'sizeBytes', 'infoHash'}:
        raise ValueError('Choose a specific cached movie file before downloading to the server.')
    name = value.get('fileName')
    size = value.get('sizeBytes')
    source_hash = value.get('infoHash')
    if (not isinstance(name, str) or not 1 <= len(name) <= 512
            or basename(name) != name or name in ('.', '..')
            or any(ord(c) < 32 for c in name)
            or Path(name).suffix.lower() not in ('.mkv', '.mp4')):
        raise ValueError('The selected stream needs an exact movie filename.')
    if size is not None and (type(size) is not int or not 1 <= size <= OWNER_CAP):
        raise ValueError('The selected file size is unknown or exceeds the server limit.')
    if source_hash is not None and (not isinstance(source_hash, str) or not re.fullmatch('[a-fA-F0-9]{40}', source_hash)):
        raise ValueError('The selected provider identity is invalid.')
    return dict(fileName=name, sizeBytes=size, infoHash=source_hash.lower() if source_hash else None)


def matches(hint, source_hash, name, size):
    return (basename(name) == hint['fileName']
            and (hint['infoHash'] is None or source_hash == hint['infoHash'])
            and (hint['sizeBytes'] is None or size == hint['sizeBytes']))


def matches_title(name, movie):
    label = ' ' + norm(basename(name)) + ' '
    return (' ' + norm(movie['name']) + ' ') in label and (' ' + str(movie['year']) + ' ') in label


def source_metadata(stream, name):
    hints = stream.get('behaviorHints') or {}
    # Source-level labels are usable only for this exact cached file.
    if not isinstance(hints.get('filename'), str) or basename(hints['filename']) != basename(name):
        return ''
    return ' '.join(s[:4096] for s in (stream.get('name'), stream.get('title'), stream.get('description')) if isinstance(s, str))
