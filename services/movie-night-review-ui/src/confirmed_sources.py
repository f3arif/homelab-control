"""Explicit, short-lived source offers. Reading offers never selects or downloads."""
from contextlib import closing
from dataclasses import asdict
from pathlib import Path
import json
import re
import secrets
import time
from movie_night import Choice, ROOT, QUOTA, RESERVE, canonical, present_movie
from download_provider import norm
from cached_sources import configured_comet
import worker_candidate as worker

ID = re.compile(r"tt[0-9]{5,12}\Z")
OPTION = re.compile(r"[a-f0-9]{32}\Z")
LIFETIME = 900


class ConfirmedSources:
    def __init__(self, controller):
        self.c = controller
        with closing(controller.feedback.connect()) as db, db:
            db.execute("""CREATE TABLE IF NOT EXISTS movie_source_offers(
                id TEXT PRIMARY KEY, principal TEXT NOT NULL, imdb TEXT NOT NULL,
                payload TEXT NOT NULL, expires INTEGER NOT NULL,
                state TEXT NOT NULL DEFAULT 'offered', job_id TEXT)""")

    def action(self, principal, data):
        c = self.c
        c.feedback.principal(principal)
        c.require_enabled()
        imdb = data.get('imdb')
        if not isinstance(imdb, str) or not ID.fullmatch(imdb):
            raise ValueError('Choose a valid movie from the title search.')
        if data['action'] == 'source-options':
            return c.similar.start(principal, 'source-options', (imdb, int(c.clock()) // 60),
                                  lambda: self.options(principal, imdb))
        option = data.get('optionId')
        if not isinstance(option, str) or not OPTION.fullmatch(option) or data.get('confirmed') is not True:
            raise ValueError('Show the source sizes and qualities, then ask the owner to choose one before adding.')
        return c.similar.start(principal, 'source-confirmation', (imdb, option),
                              lambda: self.confirm(principal, imdb, option))

    def choices(self, imdb, movie):
        provider = self.c.worker.provider
        with worker.https_get(configured_comet() + '/stream/movie/' + imdb + '.json') as response:
            raw = response.read(2_000_001)
        if len(raw) > 2_000_000:
            raise ValueError('Source response is too large. Try again later.')
        streams = json.loads(raw).get('streams', [])
        hashes = []
        for stream in streams[:500]:
            if not isinstance(stream, dict):
                continue
            hints = stream.get('behaviorHints') or {}
            match = re.fullmatch(r'comet\|torbox\|([a-fA-F0-9]{40})', str(hints.get('bingeGroup', '')))
            value = match[1] if match else stream.get('infoHash', '')
            if isinstance(value, str) and re.fullmatch('[a-fA-F0-9]{40}', value) and value.lower() not in hashes:
                hashes.append(value.lower())
        cache = {}
        for offset in range(0, min(len(hashes), 200), 100):
            page = provider._api('checkcached', {'hash': ','.join(hashes[offset:offset + 100]),
                                  'format': 'object', 'list_files': 'true'}, True)
            if isinstance(page, dict):
                cache.update(page)
        found = {}
        title = norm(movie['name']) + ' ' + str(movie['year'])
        for source_hash in hashes[:200]:
            row = cache.get(source_hash)
            if not isinstance(row, dict) or row.get('hash') != source_hash:
                continue
            for file in row.get('files', []):
                name = file.get('name', '')
                label = norm(Path(name).name)
                if not isinstance(name, str) or not label.startswith(title + ' '):
                    continue
                text = name + ' ' + str(row.get('name', ''))
                if re.search(r'(?i)\b(sample|trailer|bonus|featurettes?|commentary|rifftrax)\b', norm(text)):
                    continue
                quality = re.search(r'(?i)(?<!\d)(1080p|2160p)(?!\d)', text)
                codec = next((c for c, pattern in (
                    ('HEVC', r'(?i)(?:hevc|[xh][ .]?265)'),
                    ('AVC', r'(?i)(?:avc|[xh][ .]?264)'),
                    ('AV1', r'(?i)\bav0?1\b')) if re.search(pattern, text)), None)
                if not quality or not codec:
                    continue
                try:
                    choice = Choice(imdb, movie['name'], movie['year'], 'Exact owner-selected release',
                                    'torbox', 0, 0, name, quality[1].lower(), codec, file.get('size'),
                                    ROOT + '/' + imdb + '.' + str(movie['year']) + Path(name).suffix.lower()).validate()
                except (ValueError, TypeError):
                    continue
                found.setdefault((name, choice.size), {'hash': source_hash, 'choice': asdict(choice), 'movie': movie})
        return sorted(found.values(), key=lambda item: item['choice']['size'])

    def options(self, principal, imdb):
        c = self.c
        movie = c.similar.source.admission(imdb)
        if not c.similar.eligible([movie], principal):
            raise ValueError('This movie is no longer eligible for Movie Night.')
        candidates = self.choices(imdb, movie)
        now = int(c.clock())
        output = []
        with closing(c.feedback.connect()) as db, db:
            committed = self.committed(db)
            db.execute("DELETE FROM movie_source_offers WHERE expires<? AND state='offered'", (now,))
            # A bounded spread preserves small, medium and large files at both resolutions.
            selected = []
            for quality in ('1080p', '2160p'):
                group = [x for x in candidates if x['choice']['quality'] == quality]
                indices = sorted(set([0, 1, 2, len(group)//2, len(group)-2, len(group)-1]))
                selected.extend(group[i] for i in indices if 0 <= i < len(group))
            for candidate in selected:
                option = secrets.token_hex(16)
                choice = candidate['choice']
                db.execute('INSERT INTO movie_source_offers(id,principal,imdb,payload,expires) VALUES(?,?,?,?,?)',
                           (option, principal, imdb, canonical(candidate), now + LIFETIME))
                output.append(dict(option_id=option, quality=choice['quality'], codec=choice['codec'],
                    size_bytes=choice['size'], size_gb=round(choice['size']/1e9, 2),
                    release=Path(choice['provider_name']).name[:200],
                    additional_budget_bytes=max(0, committed + choice['size'] + 1 - QUOTA)))
        return dict(movie={'id': imdb, 'name': movie['name'], 'releaseInfo': str(movie['year'])},
                    source_options=output, confirmation_required=True, expires_epoch=now + LIFETIME,
                    remaining_budget_bytes=max(0, QUOTA - committed),
                    instruction='Show sizes, quality and release details. Ask which one to send. A choice authorizes that exact file and its displayed additional transfer budget.')

    @staticmethod
    def committed(db):
        return sum(json.loads(row[0])['choice']['size'] + 1 for row in
                   db.execute('SELECT payload FROM jobs UNION ALL SELECT payload FROM archived_jobs'))

    def snapshot(self, principal, imdb, job_id):
        state = self.c.downloads(principal)
        request = next(r for r in state['requests'] if r['imdb'] == imdb)
        job = next(j for j in state['jobs'] if j['id'] == job_id)
        return dict(selected=True, downloadRequested=True, alreadyAdded=True,
                    movie=request['movie'], download=dict(request, state=job['state'],
                    size=job['size'], bytesReceived=job['bytesReceived']))

    def confirm(self, principal, imdb, option):
        c = self.c
        now = int(c.clock())
        with c.lock, closing(c.feedback.connect()) as db, db:
            db.execute('BEGIN IMMEDIATE')
            offer = db.execute('SELECT payload,expires,state,job_id FROM movie_source_offers WHERE id=? AND principal=? AND imdb=?',
                               (option, principal, imdb)).fetchone()
            if not offer:
                raise ValueError('Source choice is unavailable. List sources again.')
            if offer[3]:
                job_id = offer[3]
            else:
                if offer[1] < now or offer[2] != 'offered':
                    raise ValueError('Source choice expired or needs review. List sources again.')
                if db.execute("SELECT 1 FROM jobs WHERE title=? AND state NOT IN ('failed','cancelled')", (imdb,)).fetchone():
                    raise ValueError('This movie already has a server file or an active transfer. Check its status.')
                db.execute("UPDATE movie_source_offers SET state='confirming' WHERE id=?", (option,))
                job_id = None
        if job_id:
            return self.snapshot(principal, imdb, job_id)
        candidate = json.loads(offer[0])
        expected = Choice(**candidate['choice']).validate()
        try:
            c.index.require_not_removed(imdb)
            c.free()
            provider = c.worker.provider
            torrent_id = provider.add_cached(candidate['hash'])
            choice = None
            for attempt in range(8):
                raw = provider._api('mylist', {'id': torrent_id, 'bypass_cache': 'true'}, True)
                rows = raw if isinstance(raw, list) else [raw]
                for torrent in rows:
                    if not isinstance(torrent, dict) or torrent.get('id') != torrent_id or torrent.get('hash') != candidate['hash']:
                        continue
                    if torrent.get('download_finished') is not True or torrent.get('download_present') is not True:
                        continue
                    for file in torrent.get('files', []):
                        if (file.get('name'), file.get('size'), file.get('infected'), file.get('zipped')) == (
                                expected.provider_name, expected.size, False, False):
                            choice = Choice(**dict(candidate['choice'], torrent_id=torrent_id, file_id=file['id'])).validate()
                if choice:
                    break
                if attempt < 7:
                    time.sleep(1)
            if not choice:
                raise ValueError('Exact cached file changed. List sources again.')
            c.similar.add_title(principal, imdb)
            with c.lock, closing(c.feedback.connect()) as db, db:
                db.execute('BEGIN IMMEDIATE')
                row = c.mobile_selections.require_eligible(principal, imdb)
                free = c.free()
                reserved = sum(json.loads(x[0])['choice']['size'] - x[1] for x in
                               db.execute("SELECT payload,bytes FROM jobs WHERE state IN ('approved','downloading')"))
                if free - reserved - choice.size < RESERVE:
                    raise ValueError('Not enough free storage for this file.')
                if db.execute("SELECT 1 FROM jobs WHERE title=? AND state NOT IN ('failed','cancelled')", (imdb,)).fetchone():
                    raise ValueError('This movie already has a server file or an active transfer. Check its status.')
                request_id = 'confirmed-source-' + option
                c.auto_downloads.enqueue(db, principal, [imdb], {imdb: row}, request_id, [imdb])
                metadata = present_movie(row, now, 'Owner chose this exact server file.')
                db.execute('INSERT INTO movie_mobile_selections VALUES(?,?,?,?) ON CONFLICT(principal,imdb) DO UPDATE SET metadata=excluded.metadata,updated=excluded.updated',
                           (principal, imdb, json.dumps(metadata), now))
                destination = c.worker.root/'Movies'/Path(choice.destination).name
                if any(p.exists() or p.is_symlink() for p in (destination, Path(str(destination) + '.part'))):
                    raise ValueError('An existing file needs review before this download.')
                from uuid import uuid4
                job_id = str(uuid4())
                committed = self.committed(db)
                payload = canonical(dict(choice=asdict(choice), authorization='owner-selected-source',
                    sourceOfferId=option, authorizedBy=principal, authorizedEpoch=now, requestId=request_id,
                    freeBytes=free, reserveBytes=RESERVE, quotaRemainingBytes=choice.size+1,
                    additionalTransferAuthorizationBytes=max(0, committed+choice.size+1-QUOTA)))
                db.execute('INSERT INTO plans VALUES(?,?,?,?)', (job_id, principal, payload, now+LIFETIME))
                db.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?,?)',
                           (job_id, imdb, choice.destination, payload, 'approved', 0, '{}'))
                db.execute("UPDATE movie_download_queue SET state='linked',job_id=?,message='',updated=? WHERE principal=? AND imdb=?",
                           (job_id, now, principal, imdb))
                db.execute("UPDATE movie_source_offers SET state='confirmed',job_id=? WHERE id=?", (job_id, option))
            # Finish the response's read transaction before the worker claims its
            # write transaction. SQLite lock upgrades otherwise leave it approved.
            snapshot = self.snapshot(principal, imdb, job_id)
            with c.lock:
                c.futures[job_id] = c.pool.submit(c.worker.run, job_id)
            return snapshot
        except Exception:
            with closing(c.feedback.connect()) as db, db:
                db.execute("UPDATE movie_source_offers SET state='needs-review' WHERE id=? AND job_id IS NULL", (option,))
            raise
