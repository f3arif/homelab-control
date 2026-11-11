"""Install or restore the pinned Movie Night owner gateway route allowlist."""
from pathlib import Path
import argparse
import fcntl
import hashlib
import http.client
import json
import os
import socket
import stat
import subprocess
import tempfile
import time

STAGE = Path('/home/coolyo/afz-stremio-secondhost-20260918/movie-night-delete-resident-20261111')
LIVE = STAGE.parent / 'movie-night-access-service/movie_gateway.py'
UNIT = 'afz-movie-night-access.service'
ENV = dict(os.environ, XDG_RUNTIME_DIR='/run/user/'+str(os.getuid()),
           DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/'+str(os.getuid())+'/bus')
CANDIDATE = STAGE / 'movie_gateway.py'
PREVIOUS = STAGE / 'movie_gateway.previous.py'
MANIFEST = json.loads((STAGE/'gateway-plan.json').read_text())

def digest(data):
    return hashlib.sha256(data).hexdigest()

def atomic(path,data,mode):
    with tempfile.NamedTemporaryFile(dir=path.parent,delete=False) as stream:
        temp = Path(stream.name)
        try:
            os.fchmod(stream.fileno(),mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(temp,path)
        finally:
            temp.unlink(missing_ok=True)

def service(action):
    subprocess.run(['systemctl','--user',action,UNIT],env=ENV,
                   timeout=40,check=True,capture_output=True)

def health():
    service('is-active')
    for _ in range(20):
        local = http.client.HTTPConnection('127.0.0.1',8767,timeout=2)
        try:
            local.request('GET','/movie-night/api/delete-server/tt35538033',
                          headers={'Host':'hpenvy.tailc9bb62.ts.net:8453'})
            response = local.getresponse()
            response.read()
            if response.status != 403:
                raise RuntimeError('Owner boundary check failed')
            break
        except OSError:
            time.sleep(.25)
        finally:
            local.close()
    else:
        raise RuntimeError('Owner gateway did not start')
    return dict(serviceActive=True,unauthenticatedPreviewStatus=403)

def apply(rollback):
    if LIVE.is_symlink() or str(LIVE) != MANIFEST['live']:
        raise RuntimeError('Unexpected live gateway path')
    before, after = PREVIOUS.read_bytes(), CANDIDATE.read_bytes()
    if digest(before) != MANIFEST['originalSha256'] or digest(after) != MANIFEST['candidateSha256']:
        raise RuntimeError('Staged gateway drift')
    original, desired = (after,before) if rollback else (before,after)
    if LIVE.read_bytes() != original:
        raise RuntimeError('Live gateway drift')
    mode = stat.S_IMODE(LIVE.stat().st_mode)
    atomic(LIVE,desired,mode)
    try:
        service('restart')
        report = health()
    except Exception:
        atomic(LIVE,original,mode)
        service('restart')
        raise
    report.update(action='rollback' if rollback else 'apply',
                  sourceCommit=MANIFEST['sourceCommit'],gatewaySha256=digest(desired),
                  checkedUtc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
    atomic(STAGE/'gateway-deployment-receipt.json',json.dumps(report,indent=2).encode(),0o600)
    print(json.dumps(report,sort_keys=True))

parser = argparse.ArgumentParser()
parser.add_argument('action',choices=['verify-baseline','apply','rollback'])
args = parser.parse_args()
if socket.gethostname().lower() != 'hpenvy':
    raise RuntimeError('Wrong release host')
if args.action == 'verify-baseline':
    print(json.dumps(health(),sort_keys=True))
else:
    with (STAGE/'.release.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        apply(args.action == 'rollback')
