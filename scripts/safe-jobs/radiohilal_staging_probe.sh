#!/bin/bash
# Observation only. No start, restart, migration, authentication or publication calls.
set -euo pipefail
python3 - <<'PY'
import datetime as dt, hashlib, json, os, subprocess, sys, urllib.request
from pathlib import Path
job = Path(os.environ['AFZ_JOB_DIR'])
container = 'radiohilal-azuracast-prod-stage'
def command(argv):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=8)
        return {'exit_code':p.returncode, 'output':p.stdout[-6000:], 'error':p.stderr[-1000:]}
    except (OSError, subprocess.TimeoutExpired) as e:
        return {'error_type':type(e).__name__, 'outcome':'unknown'}
def http(path):
    try:
        with urllib.request.urlopen('http://127.0.0.1:18088'+path, timeout=5) as r:
            return {'status':r.status, 'data':json.loads(r.read(262144))}
    except Exception as e:
        return {'error_type':type(e).__name__, 'outcome':'unknown'}
def record(name, value, next_step):
    value['observed_at'] = dt.datetime.now(dt.timezone.utc).isoformat()
    p = job / (name+'.json')
    with p.open('x') as f:
        json.dump(value,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
    subprocess.run([sys.executable,str(job/'runner.py'),'--root',os.environ['AFZ_JOB_ROOT'],
        'checkpoint',os.environ['AFZ_JOB_ID'],'--phase',name,'--next-step',next_step,
        '--evidence',str(p)],check=True,timeout=8)
    return value
container_state = record('01-container-observed', command(['docker','inspect','--format',
    '{{.Id}} {{.State.Running}} {{.State.StartedAt}} {{.RestartCount}} {{.HostConfig.RestartPolicy.Name}}',
    container]), 'Read the local staging API; do not restart the container.')
api = http('/api/status')
if isinstance(api.get('data'),dict):
    api['data']={k:api['data'][k] for k in ('online','version') if k in api['data']}
record('02-api-observed',api,'Read station status; API reachability alone is not playback verification.')
np = http('/api/nowplaying')
rows = np.pop('data',None)
np['stations'] = [{'id':r.get('station',{}).get('id'), 'name':r.get('station',{}).get('name'),
                   'is_online':r.get('is_online')} for r in rows if isinstance(r,dict)] if isinstance(rows,list) else []
record('03-stations-observed',np,'Compare supervisor status and retain any unknown outcomes.')
services = command(['docker','exec',container,'supervisorctl','status'])
record('04-services-observed',services,'Inspect saved evidence before any authorized station action.')
summary = {'observation_only':True,'api_http_status':api.get('status'),
    'stations':np['stations'], 'supervisor_exit_code':services.get('exit_code'),
    'mutations_performed':False,'playback_audio_verified':False,
    'next':'Revalidate live status and the authoritative RadioHilal checkpoint before any station mutation.'}
record('05-recovery-checkpoint',summary,summary['next'])
print(json.dumps(summary,indent=2))
PY
