"""Bounded Pixel 10 connectivity capture; no phone/network settings are changed."""
from pathlib import Path
import subprocess,json,re,time,datetime,os
ROOT=Path(__file__).parent
ADB=r'C:\AFZ\Tools\platform-tools-current-20261006\adb.exe'
TS=r'C:\Program Files\Tailscale\tailscale.exe'
BASE=[ADB,'-P','5037','-s','58211FDCQ003VJ']
DURATION_SECONDS=600
INTERVAL_SECONDS=30
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def run(cmd,timeout=12):
 try:
  r=subprocess.run(cmd,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=timeout)
  return dict(returnCode=r.returncode,stdout=r.stdout,stderr=r.stderr)
 except subprocess.TimeoutExpired:return dict(returnCode=-2,stdout='',stderr='timeout')
def adb(*args):return run(BASE+list(args))
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
OUT=ROOT/'capture-20261011';OUT.mkdir(exist_ok=False)
started=time.monotonic();started_utc=now()
state=dict(status='running',startedAt=started_utc,durationSeconds=DURATION_SECONDS,intervalSeconds=INTERVAL_SECONDS,pid=os.getpid(),samples=0,failuresDetected=0,phoneSettingsChanged=False,requiresUsbConnection=True)
def save_state():write(ROOT/'capture-status.json',state)
save_state()
try:
 assert adb('shell','getprop','ro.product.model')['stdout'].strip()=='Pixel 10 Pro XL'
 assert adb('shell','getprop','ro.serialno')['stdout'].strip()=='58211FDCQ003VJ'
 initial_status=run([TS,'status','--json']);initial=json.loads(initial_status['stdout'])
 conn=adb('shell','dumpsys','connectivity')['stdout']
 current_vpn=[line for line in conn.splitlines() if line.lstrip().startswith('NetworkAgentInfo{') and 'ni{VPN CONNECTED' in line and 'com.tailscale.ipn' in line]
 assert len(current_vpn)==1,'Exact current Tailscale VPN not identified'
 match=re.search(r'LinkAddresses: \[ (100\.\d+\.\d+\.\d+)/',current_vpn[0]);assert match
 target_ip=match.group(1)
 peers=[p for p in initial.get('Peer',{}).values() if target_ip in p.get('TailscaleIPs',[])]
 assert len(peers)==1 and peers[0].get('HostName')=='Pixel 10 Pro XL'
 target_id=peers[0]['ID'];state.update(targetIp=target_ip,targetPeerId=target_id);save_state()
 (OUT/'initial-connectivity.txt').write_text(conn,encoding='utf-8')
 while time.monotonic()-started<DURATION_SECONDS:
  sample_started=time.monotonic();i=state['samples'];folder=OUT/('%02d'%i);folder.mkdir()
  result=run([TS,'status','--json']);(folder/'h3-status.json').write_text(result['stdout'],encoding='utf-8')
  host=json.loads(result['stdout']) if result['returnCode']==0 else {}
  peer=next((p for p in host.get('Peer',{}).values() if p.get('ID')==target_id),{})
  model=adb('shell','getprop','ro.product.model')['stdout'].strip()
  phone_ok=model=='Pixel 10 Pro XL' and adb('shell','getprop','ro.serialno')['stdout'].strip()=='58211FDCQ003VJ'
  pid=adb('shell','pidof','com.tailscale.ipn')['stdout'].strip() if phone_ok else ''
  logs=adb('logcat','-d','-t','300','--pid='+pid) if phone_ok and re.fullmatch(r'\d+',pid) else dict(returnCode=-1,stdout='',stderr='')
  (folder/'tailscale-logcat.txt').write_text(logs['stdout'],encoding='utf-8')
  connection=adb('shell','dumpsys','connectivity')['stdout'] if phone_ok else ''
  (folder/'connectivity.txt').write_text(connection,encoding='utf-8')
  active_vpns=[line for line in connection.splitlines() if line.lstrip().startswith('NetworkAgentInfo{') and 'ni{VPN CONNECTED' in line and 'com.tailscale.ipn' in line]
  row=dict(sample=i,capturedAt=now(),usbVerified=phone_ok,tailscalePid=pid,peerOnline=peer.get('Online'),h3BackendState=host.get('BackendState'),h3Health=host.get('Health'),currentTailscaleVpnCount=len(active_vpns),defaultNetwork=re.findall(r'Active default network:\s*(\S+)',connection),logCaptureReturnCode=logs['returnCode'])
  row['faultDetected']=bool(phone_ok and (not pid or peer.get('Online') is False or not active_vpns))
  if row['faultDetected']:
   state['failuresDetected']+=1
   for name,args in [('dnsresolver',('shell','dumpsys','dnsresolver')),('deviceidle',('shell','dumpsys','deviceidle')),('services',('shell','dumpsys','activity','services','com.tailscale.ipn'))]:
    data=adb(*args);(folder/(name+'.txt')).write_text(data['stdout'],encoding='utf-8')
  write(folder/'summary.json',row)
  with (ROOT/'capture-timeline.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(row)+'\n')
  state['samples']+=1;state['lastSample']=row;save_state()
  delay=min(INTERVAL_SECONDS-(time.monotonic()-sample_started),DURATION_SECONDS-(time.monotonic()-started))
  if delay>0:time.sleep(delay)
 state['status']='completed_fault_captured' if state['failuresDetected'] else 'completed_no_fault_observed'
except Exception as exc:
 state.update(status='failed',errorType=type(exc).__name__,error=str(exc))
 raise
finally:
 state['finishedAt']=now();save_state()
