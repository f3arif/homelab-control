"""Guarded H3 rollout with backups and automatic source rollback."""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,time,urllib.request
HERE=Path(__file__).resolve().parent
ROOT=Path(r'C:\AFZ\Stremio-Failover-H3')
E=HERE.parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
receipt=json.loads((HERE/'candidate-receipt.json').read_text(encoding='utf-8'))
items=[receipt['catalog']]+receipt['bridges']
for x in items:
 assert sha(Path(x['path']))==x['before'],'SOURCE_CHANGED_ABORT'
assert not (ROOT/'external_stream_recovery.py').exists(),'MODULE_ALREADY_EXISTS_ABORT'
def powershell(s):
 p=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',s],
                  capture_output=True,text=True,timeout=30)
 if p.returncode:raise RuntimeError('POWERSHELL_OPERATION_FAILED')
 return p.stdout.strip()
procs=json.loads(powershell("$ids=@(Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 18768,18774 -State Listen | Select-Object -ExpandProperty OwningProcess -Unique); Get-CimInstance Win32_Process | Where-Object {$ids -contains $_.ProcessId} | Select-Object ProcessId,ExecutablePath,CommandLine | ConvertTo-Json -Compress"))
assert len(procs)==2
bridge=next(p for p in procs if 'AFZ-Stremio-Mobile-Order\\bridge.mjs' in p['CommandLine'])
core=next(p for p in procs if '-m uvicorn stremio_catalog:app' in p['CommandLine'])
backup=E/('private-before-deploy-'+time.strftime('%Y%m%dT%H%M%S',time.gmtime()))
backup.mkdir(exist_ok=False)
for i,x in enumerate(items):shutil.copy2(x['path'],backup/f'source-{i}.bak')
for name in ['uvicorn-243.log','uvicorn-243.err.log']:
 shutil.copy2(ROOT/name,backup/name)
shutil.copy2(ROOT/'state'/'external-source-cache.json',backup/'external-source-cache.json')
from external_stream_recovery import SourceHistory
history=SourceHistory(ROOT/'state'/'external-source-history.json')
cache=json.loads((ROOT/'state'/'external-source-cache.json').read_text(encoding='utf-8'))
history.remember_many(cache.get('rows') or {})
selected_file=E/'selected-expired-row-private.json'
if selected_file.exists():
 selected=json.loads(selected_file.read_text(encoding='utf-8'))
 history.remember('tt0098904:3:11',[selected])
(backup/'processes-private.json').write_text(json.dumps(procs),encoding='utf-8')
def stop_verified(proc):
 pid=int(proc['ProcessId'])
 # Recheck command identity immediately before stopping only this listener.
 current=powershell(f"(Get-CimInstance Win32_Process -Filter 'ProcessId={pid}').CommandLine")
 assert current.strip()==proc['CommandLine'].strip(),'PROCESS_IDENTITY_CHANGED_ABORT'
 powershell(f"Stop-Process -Id {pid} -Force")
def ready(port,path,timeout=40):
 end=time.time()+timeout
 while time.time()<end:
  try:
   with urllib.request.urlopen(f'http://127.0.0.1:{port}{path}',timeout=3) as r:
    d=json.load(r)
    if d.get('ok') or d.get('id')=='com.afzengineering.releasecatalog':return
  except Exception:pass
  time.sleep(.5)
 raise RuntimeError('SERVICE_NOT_READY')
def start_bridge():
 log=(E/'bridge-after-deploy-private.log').open('ab')
 p=subprocess.Popen([bridge['ExecutablePath'],receipt['bridges'][0]['path']],
       cwd=str(Path(receipt['bridges'][0]['path']).parent),stdout=log,stderr=subprocess.STDOUT,
       creationflags=subprocess.CREATE_NO_WINDOW)
 ready(18768,'/health',15)
 return p
def start_core():
 log=(E/'core-rollout-private.log').open('ab')
 p=subprocess.Popen(['powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
    '-File',str(ROOT/'Start-AFZ-Stremio-H3-Core243.ps1')],
    stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
 code=p.wait(timeout=80)
 assert code==0,'CORE_LAUNCHER_FAILED'
 ready(18774,'/manifest.json',20)
new_bridge=None
try:
 for x in items:shutil.copy2(HERE/x['candidate'],x['path'])
 shutil.copy2(HERE/'external_stream_recovery.py',ROOT/'external_stream_recovery.py')
 stop_verified(bridge)
 new_bridge=start_bridge()
 stop_verified(core)
 start_core()
 result={'ok':True,'deployedAt':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
         'catalogSha256':sha(ROOT/'stremio_catalog.py'),
         'bridgePid':new_bridge.pid,'originalExpiredLinkHistorySeeded':True,
         'browserIndependentSourceConfig':True}
 (E/'rollout-summary.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
 print(json.dumps(result),flush=True)
except Exception as exc:
 # Roll back only files this rollout owns; never alter provider configuration.
 if new_bridge and new_bridge.poll() is None:new_bridge.terminate();new_bridge.wait(timeout=10)
 for i,x in enumerate(items):shutil.copy2(backup/f'source-{i}.bak',x['path'])
 (ROOT/'external_stream_recovery.py').unlink(missing_ok=True)
 try:
  start_bridge()
  # A failed new core may already be listening: stop only its verified command.
  powershell("$l=Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 18774 -State Listen -ErrorAction SilentlyContinue; foreach($x in $l){$p=Get-CimInstance Win32_Process -Filter ('ProcessId='+$x.OwningProcess); if($p.CommandLine -match 'uvicorn stremio_catalog:app'){Stop-Process -Id $p.ProcessId -Force}}")
  start_core()
  print(json.dumps({'ok':False,'rolledBack':True,'error':str(exc)}),flush=True)
 except Exception:
  print(json.dumps({'ok':False,'rolledBackSources':True,'recoveryRequired':True}),flush=True)
 raise
