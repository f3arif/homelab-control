#!/bin/bash
# Observation only. No start, restart, migration, authentication or publication calls.
set -euo pipefail
python3 - <<'PY'
import datetime as dt, json, os, subprocess, sys, urllib.request
from pathlib import Path

job = Path(os.environ['AFZ_JOB_DIR'])
base_container = 'radiohilal-azuracast-prod-stage'

def command(argv, timeout=10):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return {'exit_code': p.returncode, 'output': p.stdout[-12000:], 'error': p.stderr[-2000:]}
    except (OSError, subprocess.TimeoutExpired) as e:
        return {'error_type': type(e).__name__, 'outcome': 'unknown'}

def record(name, value, next_step):
    value['observed_at'] = dt.datetime.now(dt.timezone.utc).isoformat()
    p = job / (name + '.json')
    with p.open('x') as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
    subprocess.run(
        [sys.executable, str(job / 'runner.py'), '--root', os.environ['AFZ_JOB_ROOT'],
         'checkpoint', os.environ['AFZ_JOB_ID'], '--phase', name,
         '--next-step', next_step, '--evidence', str(p)],
        check=True, timeout=8
    )
    return value

def http_json(path):
    try:
        with urllib.request.urlopen('http://127.0.0.1:18088' + path, timeout=6) as r:
            return {'status': r.status, 'data': json.loads(r.read(524288))}
    except Exception as e:
        return {'error_type': type(e).__name__, 'outcome': 'unknown'}

def discover_container():
    result = command(['docker', 'ps', '--format', '{{.Names}}\t{{.Image}}'], timeout=8)
    if result.get('exit_code') != 0:
        return None, {'candidates': [], 'docker_ps': result}
    candidates = []
    for line in result.get('output', '').splitlines():
        parts = line.split('\t', 1)
        name = parts[0].strip()
        image = parts[1].strip() if len(parts) > 1 else ''
        if name == base_container or name.endswith('_' + base_container):
            candidates.append({'name': name, 'image': image})
    return (candidates[0]['name'] if len(candidates) == 1 else None), {
        'candidates': candidates,
        'candidate_count': len(candidates)
    }

def parse_ffprobe(url):
    r = command([
        'ffprobe', '-v', 'error', '-show_entries',
        'stream=codec_name,sample_rate,channels', '-of', 'json', url
    ], timeout=12)
    if r.get('exit_code') == 0:
        try:
            obj = json.loads(r.get('output') or '{}')
            r['streams'] = obj.get('streams') or []
            r.pop('output', None)
        except json.JSONDecodeError:
            r['parse_error'] = True
    return r

container, discovery = discover_container()
record(
    '01-container-discovery',
    discovery,
    'Require exactly one running staging container before any deeper inspection.'
)
if not container:
    summary = {
        'observation_only': True,
        'healthy': False,
        'container': None,
        'mutations_performed': False,
        'next': 'Resolve ambiguous or missing staging container identity before any station action.'
    }
    record('06-recovery-checkpoint', summary, summary['next'])
    print(json.dumps(summary, indent=2, sort_keys=True))
    raise SystemExit(0)

container_state = command([
    'docker', 'inspect', '--format',
    '{{.Id}} {{.State.Running}} {{.State.StartedAt}} {{.RestartCount}} {{.HostConfig.RestartPolicy.Name}}',
    container
])
container_state['container'] = container
record(
    '02-container-observed',
    container_state,
    'Read the local staging API; do not restart the container.'
)

api = http_json('/api/status')
if isinstance(api.get('data'), dict):
    api['data'] = {k: api['data'][k] for k in ('online', 'version') if k in api['data']}
record(
    '03-api-observed',
    api,
    'Read station now-playing status; API reachability alone is not playback verification.'
)

np = http_json('/api/nowplaying/1')
np_data = np.pop('data', None)
station = {}
if isinstance(np_data, dict):
    station = {
        'id': (np_data.get('station') or {}).get('id'),
        'name': (np_data.get('station') or {}).get('name'),
        'is_online': np_data.get('is_online'),
        'listeners_current': (np_data.get('listeners') or {}).get('current'),
        'song': ((np_data.get('now_playing') or {}).get('song') or {}).get('text'),
        'played_at': (np_data.get('now_playing') or {}).get('played_at'),
    }
np['station'] = station
record(
    '04-station-observed',
    np,
    'Compare station state with Supervisor and stream-level evidence.'
)

services = command(['docker', 'exec', container, 'supervisorctl', 'status'])
output = services.get('output') or ''
services['station_backend_running'] = 'station_1:station_1_backend' in output and 'RUNNING' in next(
    (line for line in output.splitlines() if 'station_1:station_1_backend' in line), ''
)
services['station_frontend_running'] = 'station_1:station_1_frontend' in output and 'RUNNING' in next(
    (line for line in output.splitlines() if 'station_1:station_1_frontend' in line), ''
)
record(
    '05-services-observed',
    services,
    'Verify both public mounts before deciding whether station repair is needed.'
)

radio = parse_ffprobe('http://127.0.0.1:18088/listen/radiohilal/radio.mp3')
mobile = parse_ffprobe('http://127.0.0.1:18088/listen/radiohilal/mobile.mp3')
streams = {'radio_mp3': radio, 'mobile_mp3': mobile}
record(
    '06-streams-observed',
    streams,
    'Treat successful codec parsing as stream evidence, then preserve the recovery checkpoint.'
)

def mp3_ok(result):
    return (
        result.get('exit_code') == 0
        and any(s.get('codec_name') == 'mp3' for s in result.get('streams', []))
    )

healthy = bool(
    container_state.get('exit_code') == 0
    and api.get('status') == 200
    and station.get('is_online') is True
    and services.get('station_backend_running') is True
    and services.get('station_frontend_running') is True
    and mp3_ok(radio)
    and mp3_ok(mobile)
)

summary = {
    'observation_only': True,
    'healthy': healthy,
    'container': container,
    'api_http_status': api.get('status'),
    'station': station,
    'station_backend_running': services.get('station_backend_running'),
    'station_frontend_running': services.get('station_frontend_running'),
    'playback_audio_verified': mp3_ok(radio) and mp3_ok(mobile),
    'mutations_performed': False,
    'next': (
        'Staging station is healthy; return to the RadioHilal content/publish gate. '
        'Do not publish without explicit user confirmation.'
        if healthy else
        'Revalidate saved evidence and isolate the failing layer before any station mutation.'
    ),
}
record('07-recovery-checkpoint', summary, summary['next'])
print(json.dumps(summary, indent=2, sort_keys=True))
PY
