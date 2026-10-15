"""Recover expired provider tokens using bounded, URL-free source history."""
import hashlib
import json
import re
import threading
import time
from pathlib import Path

_FIELDS = ('token', 'provider', 'source', 'resolution', 'size', 'sizeExact',
           'filename', 'resolverVideoId')
_VIDEO = re.compile(r'tt\d+(?::\d+:\d+)?\Z')
_TOKEN = re.compile(r'[a-f0-9]{20,64}\Z')

def same_file(original, candidates):
    """Return one unambiguous, exact release from already-filtered candidates."""
    filename = str(original.get('filename') or '').strip().casefold()
    provider = str(original.get('provider') or '').strip().casefold()
    source = str(original.get('source') or '').strip().casefold()
    if not filename or not provider or not source:
        return None
    matches = {}
    for row in candidates:
        if str(row.get('filename') or '').strip().casefold() != filename:
            continue
        if str(row.get('provider') or '').strip().casefold() != provider:
            continue
        if str(row.get('source') or '').strip().casefold() != source:
            continue
        if int(row.get('resolution') or 0) != int(original.get('resolution') or 0):
            continue
        if (row.get('sizeExact') and original.get('sizeExact')
                and int(row.get('size') or 0) != int(original.get('size') or 0)):
            continue
        if str(row.get('resolverVideoId') or '') != str(original.get('resolverVideoId') or ''):
            continue
        token = str(row.get('token') or '')
        if _TOKEN.fullmatch(token):
            matches[token] = row
    return next(iter(matches.values())) if len(matches) == 1 else None

class SourceHistory:
    def __init__(self, path, ttl=7*86400, limit=20000, clock=time.time):
        self.path, self.ttl, self.limit, self.clock = Path(path), ttl, limit, clock
        self.lock = threading.RLock()
        self.gates = [threading.Lock() for _ in range(64)]
        self.rows = {}
        try:
            saved = json.loads(self.path.read_text(encoding='utf-8'))
            for key, record in saved.items():
                vid, token = key.split('|', 1)
                if (_VIDEO.fullmatch(vid) and _TOKEN.fullmatch(token)
                        and isinstance(record, dict) and isinstance(record.get('row'), dict)):
                    self.rows[key] = {'ts': float(record['ts']), 'row': {
                        k: record['row'][k] for k in _FIELDS if k in record['row']}}
        except (OSError, ValueError, TypeError, KeyError):
            pass
        self._prune()

    def _prune(self):
        now = self.clock()
        self.rows = {k:v for k,v in self.rows.items()
                     if 0 <= now-v['ts'] <= self.ttl}
        if len(self.rows) > self.limit:
            self.rows = dict(sorted(self.rows.items(), key=lambda x:x[1]['ts'],
                                    reverse=True)[:self.limit])

    def remember(self, vid, rows):
        self.remember_many({vid: rows})

    def remember_many(self, rows_by_video):
        with self.lock:
            changed = False
            for vid, rows in rows_by_video.items():
                if not _VIDEO.fullmatch(str(vid)):
                    continue
                for row in rows:
                    token = str(row.get('token') or '')
                    if not _TOKEN.fullmatch(token):
                        continue
                    key = str(vid)+'|'+token
                    clean = {k: row[k] for k in _FIELDS if k in row}
                    prior = self.rows.get(key)
                    if prior is None or prior['row'] != clean:
                        self.rows[key] = {'ts': self.clock(), 'row': clean}
                        changed = True
            self._prune()
            if changed:
                self.path.parent.mkdir(parents=True, exist_ok=True)
                tmp = self.path.with_suffix('.tmp')
                tmp.write_text(json.dumps(self.rows, ensure_ascii=False,
                                          separators=(',', ':')), encoding='utf-8')
                tmp.replace(self.path)

    def get(self, vid, token):
        with self.lock:
            record = self.rows.get(str(vid)+'|'+str(token))
            if not record or not 0 <= self.clock()-record['ts'] <= self.ttl:
                return None
            return dict(record['row'])

    def gate(self, vid, token):
        digest = hashlib.sha256((str(vid)+'|'+str(token)).encode()).digest()
        return self.gates[int.from_bytes(digest[:2], 'big') % len(self.gates)]
