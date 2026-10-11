from pathlib import Path
import subprocess,json,hashlib,re,sys,time
ROOT=Path(__file__).parent
ADB=Path(r'C:\AFZ\Tools\platform-tools-current-20261006\adb.exe')
endpoint=sys.argv[1]
server_port=sys.argv[2] if len(sys.argv)>2 else '5037'
assert server_port in ('5037','5038'),'Use a reviewed ADB server port'
assert re.fullmatch(r'192\.168\.50\.71:\d{2,5}',endpoint),'Use the current Pixel 8 endpoint'
def adb(*args):
    r=subprocess.run([str(ADB),'-P',server_port,'-s',endpoint,*args],capture_output=True,timeout=120)
    if r.returncode:raise RuntimeError('ADB command failed: '+args[0])
    return r.stdout.decode('utf-8',errors='replace')
assert adb('shell','getprop','ro.product.model').strip()=='Pixel 8'
assert adb('shell','getprop','ro.serialno').strip()=='3B170DLJH000HA'
report=json.loads((ROOT/'verified-build.json').read_text())
assert report['status']=='build_verified_not_installed' and report['signerMatched']
assert report['addonTests']['tests']==13 and not any(report['tests'][k] for k in ('failures','errors','skipped'))
apk=ROOT/'AFZ-Movies-R33-addon-setup.apk'
assert apk.stat().st_size==report['apkBytes']
assert hashlib.file_digest(apk.open('rb'),'sha256').hexdigest()==report['apkSha256']
before=adb('shell','dumpsys','package','com.afz.nuvio.preview')
assert re.search(r'versionCode=140\s',before) and 'versionName=0.5.1-afz-r32' in before,'Reinspect changed installed version'
evidence=ROOT/'pixel8-r33';evidence.mkdir(exist_ok=True)
assert not (evidence/'installation.json').exists(),'Inspect prior installation before repeating'
status=dict(adbServerPort=int(server_port),status='installing',device='Pixel 8',serial='3B170DLJH000HA',fromVersionCode=140,toVersionCode=141,apkSha256=report['apkSha256'],startedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
def save(): (evidence/'installation.json').write_text(json.dumps(status,indent=2)+'\n')
save()
try:
    result=adb('install','-r',str(apk));assert 'Success' in result,result
    after=adb('shell','dumpsys','package','com.afz.nuvio.preview')
    assert re.search(r'versionCode=141\s',after) and 'versionName=0.5.1-afz-r33' in after
    paths=adb('shell','pm','path','com.afz.nuvio.preview').splitlines()
    base=[p.removeprefix('package:') for p in paths if p.endswith('/base.apk')];assert len(base)==1
    installed=adb('shell','sha256sum',base[0]).split()[0];assert installed==report['apkSha256']
    status.update(status='installed_identity_verified',installedVersionName='0.5.1-afz-r33',installedApkSha256=installed)
except Exception as exc:
    status.update(status='failed',error=str(exc));raise
finally:
    status['finishedAt']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime());save()
print(json.dumps(status,indent=2))