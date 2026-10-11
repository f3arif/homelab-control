from pathlib import Path
import os,subprocess,json,hashlib,re,shutil,xml.etree.ElementTree as ET,time
root=Path('/home/faiz/afz-nuvio-r33-addon-setup-20261011')
stage=Path('/mnt/c/AFZ/Nuvio-Setup-20260923/R33-addon-setup-candidate')
sdk=Path('/home/faiz/Android/Sdk')
java=Path('/home/faiz/.local/share/afz-build-tools/ubuntu-java21/usr/lib/jvm/java-21-openjdk-amd64')
source=json.loads((stage/'source.json').read_text())
build_root=Path('/home/faiz/.local/share/afz-build-output/r33-addon-setup-20261011')
assert subprocess.check_output(['git','-c','core.filemode=false','rev-parse','HEAD'],cwd=root,text=True).strip()==source['sourceCommit']
assert not subprocess.check_output(['git','-c','core.filemode=false','status','--porcelain'],cwd=root,text=True).strip()
assert Path.home()==Path('/home/faiz') and (Path.home()/'.android/debug.keystore').is_file()
state=stage/'build-status.json'
assert not state.exists(),'Build already attempted. Inspect its outcome before repeating.'
status=dict(source,status='running',phase='gradle',startedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),pid=os.getpid())
def save(**values):
    status.update(values);state.write_text(json.dumps(status,indent=2)+'\n')
env=dict(os.environ,JAVA_HOME=str(java),ANDROID_HOME=str(sdk),ANDROID_SDK_ROOT=str(sdk))
env['PATH']=str(java/'bin')+os.pathsep+env.get('PATH','')
print('R33 build started; durable status and log are in '+str(stage),flush=True)
try:
    with (stage/'build.log').open('w') as log:
        save(phase='gradle')
        args=['bash','./gradlew',':androidApp:assembleFullDebug',':composeApp:testAndroidHostTest',
            '--tests','com.nuvio.app.features.addons.*','--tests','com.nuvio.app.features.downloads.*','--tests','com.nuvio.app.features.streams.*',
            '--tests','com.nuvio.app.features.jellyfin.*','--tests','com.nuvio.app.features.player.PlayerScreenRuntimeStateTest',
            '--no-daemon','--max-workers=1','--no-configuration-cache',
            '--project-cache-dir',str(build_root/'project-cache'),'-I',str(stage/'native-output.init.gradle'),
            '-Dafz.nuvio.buildOutputRoot='+str(build_root),'-Pkotlin.compiler.execution.strategy=in-process',
            '-Dorg.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8','-Pnuvio.app.versionName=0.5.1-afz-r33']
        subprocess.run(args,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    save(phase='validation')
    totals=dict(tests=0,failures=0,errors=0,skipped=0)
    suites={}
    for f in (build_root/'composeApp/test-results/testAndroidHostTest').glob('TEST-*.xml'):
        node=ET.parse(f).getroot()
        row={k:int(node.attrib.get(k,0)) for k in totals}
        suites[node.attrib['name']]=row
        for k in totals: totals[k]+=row[k]
    assert totals['tests']>=253 and not any(totals[k] for k in ['failures','errors','skipped']),totals
    addon=suites['com.nuvio.app.features.addons.AddonInstallationTest']
    assert addon['tests']==13 and not any(addon[k] for k in ['failures','errors','skipped']),addon
    phone=suites['com.nuvio.app.features.streams.PhonePlaybackRecommendationTest']
    assert phone['tests']>=17 and not phone['failures'] and not phone['errors'],phone
    tools=max([x for x in (sdk/'build-tools').iterdir() if (x/'apksigner').exists()],key=lambda x:tuple(map(int,re.findall(r'\d+',x.name))))
    def run(args): return subprocess.check_output(args,cwd=root,env=env,text=True)
    def signer(path): return re.findall(r'certificate SHA-256 digest: ([0-9a-fA-F]+)',run([str(tools/'apksigner'),'verify','--print-certs',str(path)]))
    apks=list((build_root/'androidApp/outputs/apk/full/debug').glob('*.apk'));assert len(apks)==1,apks
    apk=apks[0]
    assert signer(apk)==signer(Path('/mnt/c/AFZ/Nuvio-Setup-20260923/R32-phone-first-candidate/AFZ-Movies-R32-phone-first.apk'))
    badging=run([str(tools/'aapt'),'dump','badging',str(apk)])
    assert "package: name='com.afz.nuvio.preview'" in badging and "versionCode='141'" in badging and "versionName='0.5.1-afz-r33'" in badging,badging[:300]
    out=stage/'AFZ-Movies-R33-addon-setup.apk';shutil.copy2(apk,out)
    summary=dict(source,status='build_verified_not_installed',tests=totals,addonTests=addon,phoneTests=phone,
        pickerTests=suites.get('com.nuvio.app.features.streams.DeviceDownloadPickerTest'),
        apk=str(out),apkBytes=out.stat().st_size,apkSha256=hashlib.file_digest(out.open('rb'),'sha256').hexdigest(),
        signerMatched=True,buildOutputRoot=str(build_root),deviceInstalled=False,devicePlaybackVerified=False,
        finishedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
    (stage/'verified-build.json').write_text(json.dumps(summary,indent=2)+'\n')
    (stage/'test-suites.json').write_text(json.dumps(suites,indent=2)+'\n')
    save(status='build_verified_not_installed',phase='complete',resultFile=str(stage/'verified-build.json'))
    print(json.dumps(summary,indent=2),flush=True)
except Exception as exc:
    save(status='failed',phase=status.get('phase'),error=str(exc),finishedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
    print('BUILD_FAILED '+str(exc),flush=True)
    print((stage/'build.log').read_text()[-18000:],flush=True)
    raise