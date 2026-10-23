"""Add/remove only the dedicated Movie Night gateway. Existing services stay live.

Run from a tested checkout on HP Envy. Private identity/receipts stay on the server.
Rollback refuses drift and never changes preferences, plans, jobs or media.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess

ROOT=Path('/home/coolyo/afz-stremio-secondhost-20260918')
SOURCE=Path(__file__).resolve().parent
STAGE=ROOT/'movie-night-access-20261023'
TARGET=ROOT/'movie-night-access-service'
PRIVATE=ROOT/'state/movie-night-access'
UNIT=Path('/home/coolyo/.config/systemd/user/afz-movie-night-access.service')
UNIT_NAME=UNIT.name
HOST='hpenvy.tailc9bb62.ts.net:8453'
ORIGIN='https://'+HOST
PROXY='http://127.0.0.1:8767'
FILES=['standalone_server.py','movie_gateway.py']
ENV=dict(os.environ,XDG_RUNTIME_DIR='/run/user/1000')


def run(args):
    return subprocess.check_output(args,env=ENV,stderr=subprocess.STDOUT,text=True,timeout=30)


def serve(): return json.loads(run(['tailscale','serve','status','--json']))
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def without_new(config):
    value=json.loads(json.dumps(config))
    value.get('TCP',{}).pop('8453',None)
    value.get('Web',{}).pop(HOST,None)
    value.get('AllowFunnel',{}).pop(HOST,None)
    # The CLI may omit an empty map.
    return {k:v for k,v in value.items() if v not in ({},None)}


def apply():
    for p in (STAGE,TARGET,PRIVATE,UNIT):
        if p.exists(): raise RuntimeError('Access deployment already exists; inspect before updating')
    current=serve()
    if '8453' in current.get('TCP',{}) or HOST in current.get('Web',{}):
        raise RuntimeError('HTTPS port is already configured')
    with socket.socket() as listener: listener.bind(('127.0.0.1',8767))
    tested=json.loads((SOURCE/'qa/access/tested-source.json').read_text())
    for name in FILES:
        if digest(SOURCE/'gateway'/name)!=tested['gateway/'+name]:
            raise RuntimeError('Gateway differs from the browser-tested source')
    status=json.loads(run(['tailscale','status','--json']))
    uid=status['Self']['UserID']
    if not uid or status['Self'].get('Tags'): raise RuntimeError('An owner identity is required')
    owner=status['User'][str(uid)]['LoginName']
    if not any(p.get('HostName')=='DESKTOP-H3R6CQN' and p.get('UserID')==uid for p in status.get('Peer',{}).values()):
        raise RuntimeError('Owner identity does not match the verified management device')
    STAGE.mkdir(mode=0o700); TARGET.mkdir(mode=0o700); PRIVATE.mkdir(mode=0o700)
    owner_file=PRIVATE/'owner.json'
    owner_file.write_text(json.dumps({'version':1,'owner_login':owner})); owner_file.chmod(0o600)
    for name in FILES:
        shutil.copyfile(SOURCE/'gateway'/name,TARGET/name); (TARGET/name).chmod(0o600)
    unit=f'''[Unit]
Description=AFZ Movie Night independent private access
After=network.target afz-movie-night-review.service

[Service]
Type=simple
WorkingDirectory={TARGET}
ExecStart={ROOT}/.venv/bin/python {TARGET}/standalone_server.py --owner-config {owner_file} --origin {ORIGIN} --backend-origin https://hpenvy.tailc9bb62.ts.net:8447 --port 8767
Environment=PYTHONDONTWRITEBYTECODE=1
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true

[Install]
WantedBy=default.target
'''
    UNIT.write_text(unit)
    manifest={'version':1,'sourceCommit':run(['git','-C',str(SOURCE),'rev-parse','HEAD']).strip(),
              'files':{str(p):digest(p) for p in [UNIT,owner_file]+[TARGET/n for n in FILES]},
              'otherServeHash':hashlib.sha256(json.dumps(without_new(current),sort_keys=True).encode()).hexdigest()}
    (STAGE/'manifest.json').write_text(json.dumps(manifest,indent=2))
    shutil.copyfile(__file__,STAGE/'deploy_access.py')
    run(['systemctl','--user','daemon-reload'])
    run(['systemctl','--user','enable','--now',UNIT_NAME])
    if run(['systemctl','--user','is-active',UNIT_NAME]).strip()!='active': raise RuntimeError('Gateway not active')
    run(['tailscale','serve','--bg','--https=8453',PROXY])
    after=serve()
    if after.get('Web',{}).get(HOST)!={'Handlers':{'/':{'Proxy':PROXY}}} or after.get('AllowFunnel',{}).get(HOST):
        raise RuntimeError('New Serve route is not exactly private')
    if without_new(after)!=without_new(current): raise RuntimeError('Unrelated Serve configuration changed; inspect')
    print('APPLIED',ORIGIN+'/movie-night/')


def rollback():
    manifest=json.loads((STAGE/'manifest.json').read_text())
    for name,expected in manifest['files'].items():
        p=Path(name)
        if not p.exists() or digest(p)!=expected: raise RuntimeError('Live file drift; rollback refused')
    current=serve(); route=current.get('Web',{}).get(HOST)
    if route not in (None,{'Handlers':{'/':{'Proxy':PROXY}}}): raise RuntimeError('Serve drift; rollback refused')
    if route: run(['tailscale','serve','--https=8453','off'])
    if without_new(serve())!=without_new(current): raise RuntimeError('Unrelated Serve change; inspect')
    run(['systemctl','--user','disable','--now',UNIT_NAME])
    UNIT.rename(STAGE/'disabled.service')
    run(['systemctl','--user','daemon-reload'])
    print('ROLLED_BACK: original billing entry and Movie Night backend remain unchanged')


if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('action',choices=['apply','rollback']);args=parser.parse_args()
    (apply if args.action=='apply' else rollback)()
