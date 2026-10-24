"""Movie Night source policy and durable bound approvals. This module performs no network I/O."""
from dataclasses import asdict, dataclass
from hashlib import sha256
import json
import math
from pathlib import PurePosixPath
import re
import sqlite3
from uuid import uuid4
from trailer_policy import reviewed_trailer
from discovery_policy import screened
from movie_presentation import display_fields

CAP = 9_000_000_000
RESERVE = 50 * 1024**3
QUOTA = 100_000_000_000
ROOT = '/home/coolyo/afz-curated-media/Movies'
PREFERRED_TAGS = {'obsession', 'relationship tension', 'twists', 'suspense'}
SEEN_TITLES = {'heretic', 'companion'}

def excluded_genres(row):
    return any(re.search(r'\b(?:comed(?:y|ies)|dramed(?:y|ies))\b',str(g),re.I) for g in row.get('genres',[]) or [])



def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


@dataclass(frozen=True)
class Choice:
    imdb: str
    title: str
    year: int
    edition: str
    provider: str
    torrent_id: int
    file_id: int
    provider_name: str
    quality: str
    codec: str
    size: int
    destination: str

    def validate(self):
        if not re.fullmatch(r'tt\d+', self.imdb):
            raise ValueError('canonical title required')
        if type(self.year) is not int or not 1888 <= self.year <= 2100:
            raise ValueError('release year required')
        if self.provider != 'torbox' or any(type(n) is not int or n < 0 for n in (self.torrent_id, self.file_id)):
            raise ValueError('exact provider file required')
        if type(self.size) is not int or not 0 < self.size <= CAP:
            raise ValueError('known size of at most 9,000,000,000 bytes required')
        if self.quality != '1080p':
            raise ValueError('phone movie prototype requires 1080p')
        for value in (self.title, self.edition, self.provider_name, self.codec):
            if not isinstance(value, str) or not value.strip() or any(ord(c) < 32 for c in value):
                raise ValueError('complete printable confirmation metadata required')
        dest = PurePosixPath(self.destination)
        if dest.parent != PurePosixPath(ROOT) or '..' in dest.parts or dest.suffix.lower() not in {'.mp4', '.mkv'}:
            raise ValueError('approved destination required')
        return self


def select_compact(choices):
    eligible = []
    for c in choices:
        try:
            c.validate()
        except (ValueError, TypeError):
            continue
        # Every known-size <=5GB option outranks >5GB. 3–5GB is preferred.
        eligible.append(c)
    return min(eligible, key=lambda c: (0 if 3_000_000_000 <= c.size <= 5_000_000_000 else 1 if c.size <= 5_000_000_000 else 2, c.size, c.torrent_id, c.file_id)) if eligible else None


def stream_status(choice, proof, now, device_id):
    """Interpret a trusted validator's bounded probe; never issue a request here."""
    try:
        choice.validate()
        checked = proof['checkedEpoch']
        throughput = proof['throughputMbps']
        required = proof['requiredMbps']
        identity = (proof.get('provider'), proof.get('torrentId'), proof.get('fileId'), proof.get('sizeBytes'))
        if identity != (choice.provider, choice.torrent_id, choice.file_id, choice.size):
            raise ValueError('source mismatch')
        if type(checked) is not int or not 0 <= now - checked <= 300:
            raise ValueError('stale probe')
        if not device_id or proof.get('deviceId') != device_id:
            raise ValueError('device mismatch')
        if any(type(x) not in (int,float) or not math.isfinite(x) or x <= 0 for x in (throughput,required)):
            raise ValueError('unknown bandwidth')
        if proof.get('httpStatus') != 206 or proof.get('codecCompatible') is not True or throughput < required * 1.5:
            raise ValueError('source unsuitable')
        return {'status':'source-validated','playbackTested':False,'revalidateBeforePlay':True}
    except (KeyError, ValueError, TypeError):
        return {'status':'validation-required','playbackTested':False,'revalidateBeforePlay':True}


def shortlist(payload, now, seen_policy=None, limit=12):
    """Consume a reviewed weekly artifact; do not invent likes or stream checks."""
    generated = payload.get('generatedEpoch')
    if type(generated) is not int or not 0 <= now - generated <= 30 * 86400:
        return []
    result, ids = [], set()
    from seen_policy import SeenPolicy
    for row in (seen_policy or SeenPolicy()).filter(payload.get('movies', [])):
        if not isinstance(row, dict):
            continue
        imdb, name = row.get('id', ''), row.get('name', '')
        if imdb in payload.get('knownSeenIds', []) or excluded_genres(row):continue
        if not isinstance(imdb, str) or not re.fullmatch(r'tt\d+', imdb) or imdb in ids:
            continue
        if str(name).strip().casefold() in SEEN_TITLES or row.get('seen') is True:
            continue
        if type(row.get('year')) is not int or not 2016 <= row['year'] <= 2100:
            continue
        # Broad "Horror" or similarity is insufficient evidence about intensity.
        if not screened(row,now) and (row.get('scareLevel') not in {'low', 'moderate'} or row.get('intensityReviewed') is not True):
            continue
        tags = set(row.get('fitTags') or []) & PREFERRED_TAGS
        if not tags or (row.get('intenseSupernatural') is not False and not screened(row,now)):
            continue
        reason = 'Fits your stated preference: ' + ', '.join(sorted(tags))
        result.append({'id': imdb, 'type': 'movie', 'name': str(name),
                       'releaseInfo': str(row.get('year', '')),
                       'description': reason + '\nFinalize your picks to request their server downloads. Source availability and playback are not yet verified.',
                       'posterShape': 'poster', 'fitTags': sorted(tags),
                       'trailer': reviewed_trailer(row.get('trailer'), imdb),
                       'synopsis': str(row.get('synopsis',''))[:450],
                       'genres': [str(g)[:40] for g in row.get('genres',[])[:10]] if isinstance(row.get('genres'),list) else [],
                       'screening': 'automatic metadata' if row.get('discoveryEvidence') else 'editorial',
                       'sources': row.get('sources',[]),
                       'intensityGuide': str(row.get('intensityGuide',''))[:240],
                       **display_fields(imdb, row.get('presentation'), now)})
        ids.add(imdb)
        if limit is not None and len(result) >= limit:
            break
    return result


class ApprovalStore:
    """Durable authorization state shared by the confirmed-download controller.

    The store itself never dispatches a downloader or reads provider credentials.
    Transport must bind the principal and confirmation ID before calling approve.
    """
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.execute('CREATE TABLE IF NOT EXISTS plans (id TEXT PRIMARY KEY, principal TEXT, payload TEXT, expires INTEGER)')
        self.db.execute('CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, title TEXT UNIQUE, destination TEXT UNIQUE, payload TEXT, state TEXT, bytes INTEGER, evidence TEXT)')
        self.db.execute('CREATE TABLE IF NOT EXISTS cancellations (id TEXT PRIMARY KEY)')
        self.db.commit()

    def propose(self, choice, principal, now, free, quota=QUOTA):
        choice.validate()
        if not principal or free - choice.size < RESERVE or quota < choice.size:
            raise ValueError('identity, storage or quota unavailable')
        payload = {'choice': asdict(choice), 'freeBytes': free, 'quotaRemainingBytes': quota,
                   'reserveBytes': RESERVE, 'expiresEpoch': now + 900,
                   'downloaded': False, 'indexed': False, 'playbackTested': False}
        pid = str(uuid4())
        with self.db:
            self.db.execute('INSERT INTO plans VALUES (?,?,?,?)', (pid, principal, canonical(payload), now + 900))
        return {'confirmationId': pid, 'binding': sha256(canonical(payload).encode()).hexdigest(), **payload}

    def close(self): self.db.close()

    def approve_finalized(self, choice, principal, request_id, now, free, provider_checked_at):
        """Bind a concrete file to the owner's durable Finalize & download request.

        Queue linkage, plan and job commit together. This is an explicit alternate
        authorization path; it never manufactures a reply to a manual confirmation.
        """
        choice.validate()
        self.db.execute('BEGIN IMMEDIATE')
        try:
            request=self.db.execute('SELECT imdb,state FROM movie_download_queue WHERE id=? AND principal=?',(request_id,principal)).fetchone()
            if not request or request!=(choice.imdb,'checking'):
                raise ValueError('download request no longer active')
            if not 0<=now-provider_checked_at<=300:raise ValueError('provider verification expired')
            reserved=sum(json.loads(x[0])['choice']['size']-x[1] for x in self.db.execute("SELECT payload,bytes FROM jobs WHERE state IN ('approved','downloading')"))
            committed=sum(json.loads(x[0])['choice']['size']+1 for x in self.db.execute('SELECT payload FROM jobs'))
            if free-reserved-choice.size<RESERVE or QUOTA-committed<choice.size+1:
                raise ValueError('insufficient storage or quota')
            pid=str(uuid4())
            payload=canonical({'choice':asdict(choice),'authorization':'finalize-and-download',
                               'requestId':request_id,'authorizedBy':principal,'authorizedEpoch':now,
                               'freeBytes':free,'quotaRemainingBytes':QUOTA-committed,'reserveBytes':RESERVE})
            self.db.execute('INSERT INTO plans VALUES(?,?,?,?)',(pid,principal,payload,now+900))
            self.db.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?,?)',(pid,choice.imdb,choice.destination,payload,'approved',0,'{}'))
            self.db.execute("UPDATE movie_download_queue SET state='linked',job_id=?,message='',updated=? WHERE id=?",(pid,now,request_id))
            self.db.commit()
            return pid
        except Exception:
            self.db.rollback();raise

    def approve(self, pid, binding, principal, reply, current_choice, provider_checked_at, now,
                free, quota=QUOTA, existing=False, completed_present=False):
        if reply.strip().casefold() != 'yes':
            raise ValueError('explicit yes to this confirmation required')
        self.db.execute('BEGIN IMMEDIATE')
        try:
            p = self.db.execute('SELECT principal,payload,expires FROM plans WHERE id=?', (pid,)).fetchone()
            if not p or p[0] != principal or sha256(p[1].encode()).hexdigest() != binding:
                raise ValueError('approval binding mismatch')
            prior = self.db.execute('SELECT state FROM jobs WHERE id=?', (pid,)).fetchone()
            if prior:
                self.db.commit()
                return {'id': pid, 'state': prior[0], 'newJob': False}
            current_choice.validate()
            if now >= p[2] or not 0 <= now - provider_checked_at <= 300:
                raise ValueError('stale choice; new confirmation required')
            if asdict(current_choice) != json.loads(p[1])['choice']:
                raise ValueError('choice changed; new confirmation required')
            if existing or completed_present is not True:
                raise ValueError('existing file or provider completion not verified')
            reserved = sum(json.loads(x[0])['choice']['size'] - x[1] for x in self.db.execute("SELECT payload,bytes FROM jobs WHERE state IN ('approved','downloading')"))
            committed = sum(json.loads(x[0])['choice']['size'] + 1 for x in self.db.execute('SELECT payload FROM jobs'))
            if free - reserved - current_choice.size < RESERVE or quota - committed < current_choice.size + 1:
                raise ValueError('insufficient storage or quota')
            self.db.execute('INSERT INTO jobs VALUES (?,?,?,?,?,?,?)', (pid, current_choice.imdb, current_choice.destination, p[1], 'approved', 0, '{}'))
            self.db.commit()
            return {'id': pid, 'state': 'approved', 'newJob': True}
        except Exception:
            self.db.rollback()
            raise

    def transition(self, pid, state, *, bytes_received=None, evidence=None):
        """Record verified worker events. This method performs no network, indexing or playback."""
        allowed = {'approved': {'downloading', 'cancelled', 'failed'},
                   'downloading': {'downloading', 'cancelled', 'failed', 'downloaded'},
                   'downloaded': {'indexed'}, 'indexed': {'playback-tested'}}
        with self.db:
            row = self.db.execute('SELECT payload,state,bytes,evidence FROM jobs WHERE id=?', (pid,)).fetchone()
            if not row or state not in allowed.get(row[1], set()):
                raise ValueError('invalid transition')
            choice = json.loads(row[0])['choice']
            count = row[2] if bytes_received is None else bytes_received
            if type(count) is not int or not row[2] <= count <= choice['size']:
                raise ValueError('invalid byte count')
            proof = json.loads(row[3]); event = evidence or {}
            if state == 'downloaded':
                if count != choice['size'] or event.get('actualSize') != count or event.get('mediaProbePassed') is not True or not re.fullmatch('[a-f0-9]{64}', str(event.get('sha256', ''))) or event.get('destination') != choice['destination']:
                    raise ValueError('complete-file validation required')
                proof['file'] = {k:event[k] for k in ('actualSize','mediaProbePassed','sha256','destination')}
            if state == 'indexed':
                if event.get('catalogId') != choice['imdb'] or event.get('existingRouteVerified') is not True:
                    raise ValueError('index visibility verification required')
                proof['index'] = {k:event[k] for k in ('catalogId','existingRouteVerified')}
            if state == 'playback-tested':
                if event.get('userObservedPlayback') is not True:
                    raise ValueError('actual playback acceptance required')
                proof['playback'] = {'userObservedPlayback':True}
            self.db.execute('UPDATE jobs SET state=?,bytes=?,evidence=? WHERE id=?', (state, count, canonical(proof), pid))
        return self.status(pid)

    def status(self, pid):
        row = self.db.execute('SELECT state,bytes,evidence FROM jobs WHERE id=?', (pid,)).fetchone()
        if not row:
            return None
        proof = json.loads(row[2])
        return {'state': row[0], 'bytesReceived': row[1], 'downloaded': 'file' in proof,
                'indexed': 'index' in proof, 'playbackTested': 'playback' in proof}

