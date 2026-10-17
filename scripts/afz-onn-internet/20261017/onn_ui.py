"""Operate only the identity-verified ONN's existing Stremio install UI."""
import argparse,json,os,re,subprocess,time,urllib.request,xml.etree.ElementTree as ET
from pathlib import Path

EVIDENCE=Path(r'C:\AFZ\Evidence\ONN-Internet-20261017')
PRIVATE=Path(os.environ['LOCALAPPDATA'])/'AFZ'/'ONN-Internet-20261017'
ADB=r'C:\AFZ\Tools\platform-tools-current-20261006\adb.exe'
TARGET='192.168.50.31:5555'
def adb(*args,timeout=20):
    return subprocess.run([ADB,'-P','5037','-s',TARGET,*args],capture_output=True,timeout=timeout)
def shell(*args,timeout=20):
    p=adb('shell',*args,timeout=timeout)
    return p.stdout.decode('utf-8','replace').strip()
expected=json.loads((EVIDENCE/'inventory.json').read_text(encoding='utf-8'))
assert shell('getprop','ro.serialno')==expected['serial']
assert shell('getprop','ro.product.model')==expected['model']=='onn. 4K Streaming Box'
parser=argparse.ArgumentParser()
parser.add_argument('action',choices=['snapshot','launch','tap','key'])
parser.add_argument('values',nargs='*')
args=parser.parse_args()
links=json.loads((PRIVATE/'installation-links-private.json').read_text(encoding='utf-8'))
report={'action':args.action,'identityVerified':True}
if args.action=='launch':
    assert links['manifest'].startswith('https://desktop-h3r6cqn.tailc9bb62.ts.net/')
    with urllib.request.urlopen(links['manifest'],timeout=15) as r:manifest=json.load(r)
    assert manifest['id']=='com.afzengineering.releasecatalog.internet'
    before=shell('dumpsys','power');(PRIVATE/'power-before-install-private.txt').write_text(before,encoding='utf-8')
    shell('input','keyevent','KEYCODE_WAKEUP')
    uri=links['manifest'].replace('https://','stremio://',1)
    p=adb('shell','am','start','-W','-a','android.intent.action.VIEW','-d',uri,'-p','com.stremio.one',timeout=25)
    (PRIVATE/'launch-private.txt').write_bytes(p.stdout+p.stderr)
    report['launchExit']=p.returncode
    time.sleep(1)
elif args.action=='tap':
    assert len(args.values)==2
    x,y=[int(v) for v in args.values]
    assert 0<=x<4000 and 0<=y<4000
    shell('input','tap',str(x),str(y));time.sleep(1)
elif args.action=='key':
    assert len(args.values)==1 and args.values[0] in ('KEYCODE_DPAD_CENTER','KEYCODE_DPAD_UP','KEYCODE_DPAD_DOWN','KEYCODE_DPAD_LEFT','KEYCODE_DPAD_RIGHT','KEYCODE_BACK','KEYCODE_HOME')
    shell('input','keyevent',args.values[0]);time.sleep(.6)
stamp=str(int(time.time()))
result=shell('uiautomator','dump','/sdcard/afz-onn-internet-ui.xml',timeout=20)
p=adb('exec-out','cat','/sdcard/afz-onn-internet-ui.xml')
path=PRIVATE/('ui-'+stamp+'-private.xml');path.write_bytes(p.stdout)
rows=[]
if p.returncode==0 and p.stdout.startswith(b'<?xml'):
    for n in ET.fromstring(p.stdout).iter('node'):
        text=n.attrib.get('text','');desc=n.attrib.get('content-desc','')
        if not text and not desc:continue
        def clean(s):
            return re.sub(r'https?://\S+','[private link]',s)[:160]
        rows.append({'text':clean(text),'description':clean(desc),'bounds':n.attrib.get('bounds'),
                     'clickable':n.attrib.get('clickable'),'focused':n.attrib.get('focused')})
report['ui']=rows[:65]
report['vpnTransportPresent']='Transports: VPN' in shell('dumpsys','connectivity')
(EVIDENCE/'latest-ui-summary.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(json.dumps(report))
