from pathlib import Path
import json,hashlib,shutil,py_compile
stage=Path(__file__).parent;release=stage.parent/'private-direct-download-20261012'
report=json.loads((stage/'verified-build.json').read_text())
assert report['versionCode']==144 and report['signerMatched'] and report['tests']['failures']==0 and report['tests']['errors']==0
apk=stage/'AFZ-Movies-R34-seerr-integrated.apk'
assert hashlib.sha256(apk.read_bytes()).hexdigest()==report['apkSha256']
immutable=stage/'AFZ-Nuvio-R34-Seerr-build144.apk'
assert not immutable.exists()
shutil.copy2(apk,immutable)
apk=immutable
target=release/'download_app.py';backup=release/'download_app.before-r34.py'
assert not backup.exists()
source=target.read_text()
assert 'EXPECTED_SHA="1537f30e0a5d533ea8be10abd019dfeaca65627046f1ceb54fe0605ad7d0443e"' in source
assert 'R34' not in source
addition='\n\n# Versioned integrated preview; the prior build142 route remains available.\n'
addition+='R34_APK=Path('+repr(str(apk))+')\n'
addition+='R34_SHA='+repr(report['apkSha256'])+'\nR34_BYTES='+str(report['apkBytes'])+'\n'
addition+='R34_NAME="AFZ-Nuvio-R34-Seerr-build144.apk"\n'
addition+='if R34_APK.stat().st_size != R34_BYTES or hashlib.sha256(R34_APK.read_bytes()).hexdigest() != R34_SHA:\n    raise RuntimeError("R34 APK checksum mismatch")\n'
addition+='@app.api_route("/"+R34_NAME,methods=["GET","HEAD"])\ndef integrated_apk(request:Request):\n    return FileResponse(path=R34_APK,filename=R34_NAME,media_type="application/vnd.android.package-archive",headers={"Cache-Control":"private, no-store","X-Content-Type-Options":"nosniff","X-Frame-Options":"DENY"},content_disposition_type="attachment")\n'
addition+='@app.get("/r34/health")\ndef integrated_health():\n    return {"ok":True,"versionCode":144,"filename":R34_NAME,"bytes":R34_BYTES,"sha256":R34_SHA,"public":False}\n'
candidate=stage/'download_app144.py';candidate.write_text(source+addition);py_compile.compile(str(candidate),doraise=True)
shutil.copy2(target,backup);shutil.copy2(candidate,target)
metadata=dict(versionCode=144,url='https://desktop-h3r6cqn.tailc9bb62.ts.net:18887/AFZ-Nuvio-R34-Seerr-build144.apk',apkSha256=report['apkSha256'],bytes=report['apkBytes'],privateTailnetOnly=True,priorRoutePreserved=True,status='prepared_not_yet_verified')
(stage/'download144.json').write_text(json.dumps(metadata,indent=2));print(json.dumps(metadata))