"""Bounded read-only Pixel 10 DNS/route capture on the already verified USB ADB server."""
from pathlib import Path
import subprocess,json,re,time,datetime,xml.etree.ElementTree as E,urllib.parse,os
ROOT=Path(__file__).parent
ADB=r'C:\AFZ\Tools\platform-tools-current-20261006\adb.exe'
BASE=[ADB,'-P','5038','-s','58211FDCQ003VJ']
TS=r'C:\Program Files\Tailscale\tailscale.exe'
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def run(cmd):
 try:
  r=subprocess.run(cmd,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=10)
  return dict(code=r.returncode,out=r.stdout,err=r.stderr)
 except subprocess.TimeoutExpired:return dict(code=-2,out='',err='command timed out')
def adb(*args):return run(BASE+list(args))
def write(name,value):(ROOT/name).write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
assert not (ROOT/'route-capture-status.json').exists(),'Inspect existing capture before repeating'
state=dict(status='running',startedAt=now(),pid=os.getpid(),durationSeconds=1800,intervalSeconds=60,samples=0,failingSamples=0,coverageGaps=0,settingsChanged=False,adbServerPort=5038,device='Pixel 10 Pro XL',serial='58211FDCQ003VJ')
write('route-capture-status.json',state);started=time.monotonic()
try:
 assert adb('shell','getprop','ro.product.model')['out'].strip()=='Pixel 10 Pro XL'
 assert adb('shell','getprop','ro.serialno')['out'].strip()=='58211FDCQ003VJ'
 initial=run([TS,'status','--json']);assert initial['code']==0
 host=json.loads(initial['out']);self_ip=host['Self']['TailscaleIPs'][0]
 xml=adb('exec-out','run-as','com.afz.nuvio.preview','cat','shared_prefs/nuvio_addons.xml');assert xml['code']==0
 hosts=set()
 for node in E.fromstring(xml['out']):
  if node.get('name','').startswith('installed_manifest_urls_'):
   for url in (node.text or '').splitlines():
    u=urllib.parse.urlparse(url)
    if u.hostname and re.fullmatch(r'[A-Za-z0-9.-]+',u.hostname):hosts.add((u.hostname,u.port or (443 if u.scheme=='https' else 80)))
 assert hosts,'No installed addon hosts'
 write('route-capture-start.json',dict(startedAt=state['startedAt'],durationSeconds=1800,hostCount=len(hosts),adbServerPort=5038,settingsChanged=False))
 while time.monotonic()-started<1800:
  tick=time.monotonic();index=state['samples']
  model=adb('shell','getprop','ro.product.model')['out'].strip()
  verified=model=='Pixel 10 Pro XL' and adb('shell','getprop','ro.serialno')['out'].strip()=='58211FDCQ003VJ'
  row=dict(sample=index,capturedAt=now(),usbVerified=verified,failures=[])
  if verified:
   public=adb('shell','ping','-c','1','-W','3','example.com')
   private=adb('shell','ping','-c','1','-W','3',self_ip)
   row.update(publicDnsResolved=bool(re.search(r'PING example\.com \(',public['out'])),publicPingCode=public['code'],h3PrivatePingPassed=private['code']==0)
   if not row['publicDnsResolved']:row['failures'].append('public_dns')
   if not row['h3PrivatePingPassed']:row['failures'].append('h3_private_ping')
   checks=[]
   for label,(name,port) in enumerate(sorted(hosts),1):
    probe=adb('shell','nc','-z','-w','3',name,str(port));checks.append(dict(label='addonHost'+str(label),port=port,code=probe['code']))
    if probe['code']!=0:row['failures'].append('addon_host_'+str(label)+'_dns_or_tcp')
   row['addonHosts']=checks;row['tailscalePid']=adb('shell','pidof','com.tailscale.ipn')['out'].strip()
   if not row['tailscalePid']:row['failures'].append('tailscale_process_absent')
   if row['failures']:
    state['failingSamples']+=1
    folder=ROOT/('route-fault-%02d'%index);folder.mkdir()
    for name,args in [('connectivity',('shell','dumpsys','connectivity')),('dnsresolver',('shell','dumpsys','dnsresolver')),('deviceidle',('shell','dumpsys','deviceidle')),('services',('shell','dumpsys','activity','services','com.tailscale.ipn'))]:
     data=adb(*args);(folder/(name+'.txt')).write_text(data['out']+data['err'],encoding='utf-8')
    if re.fullmatch(r'\d+',row['tailscalePid']):
     log=adb('logcat','-d','-t','1200','--pid='+row['tailscalePid']);(folder/'tailscale-logcat.txt').write_text(log['out']+log['err'],encoding='utf-8')
  else:state['coverageGaps']+=1
  with (ROOT/'route-capture-timeline.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(row)+'\n')
  state['samples']+=1;state['lastSample']=row;write('route-capture-status.json',state)
  delay=min(60-(time.monotonic()-tick),1800-(time.monotonic()-started))
  if delay>0:time.sleep(delay)
 state['status']='completed_failures_captured' if state['failingSamples'] else 'completed_no_probe_failure_observed'
except Exception as exc:state.update(status='failed',errorType=type(exc).__name__,error=str(exc));raise
finally:state['finishedAt']=now();write('route-capture-status.json',state)
