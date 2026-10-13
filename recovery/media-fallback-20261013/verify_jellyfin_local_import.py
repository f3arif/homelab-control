#!/usr/bin/env python3
"""Bounded local Jellyfin import and byte-range playback check."""
import os,pathlib,requests,json,subprocess,os,time,shutil
R=pathlib.Path(os.environ['AFZ_FALLBACK_ROOT']);J=pathlib.Path(os.environ['AFZ_JELLYFIN_ROOT']);REC=pathlib.Path(os.environ['AFZ_REQUESTS_RECOVERY_DIR'])
S=json.loads((R/'seerr/settings.json').read_text());h={'Authorization':'MediaBrowser Token="'+S['jellyfin']['apiKey']+'"'}
test_name='AFZ Local Import Check '+str(int(time.time()))
folder=R/'library-landing'/test_name; assert not folder.exists();folder.mkdir()
video=folder/(test_name+'.mp4'); env=os.environ.copy();env['LD_LIBRARY_PATH']=str(J/'tools/jellyfin-ffmpeg/lib')+':'+str(J/'tools/runtime-libs')
(folder/'movie.nfo').write_text('<movie><title>'+test_name+'</title><year>2026</year><plot>Temporary generated diagnostic clip.</plot><lockdata>true</lockdata></movie>')
subprocess.run([str(J/'tools/jellyfin-ffmpeg/ffmpeg'),'-hide_banner','-loglevel','error','-f','lavfi','-i','color=c=blue:s=320x180:r=24','-t','2','-an','-c:v','libx264','-threads','1','-preset','ultrafast','-pix_fmt','yuv420p','-movflags','+faststart',str(video)],env=env,check=True,capture_output=True,timeout=30)
print('GENERATED_LOCAL_TEST',video.stat().st_size,flush=True)
result={'generatedLocally':True,'uniqueNewPath':True,'testName':test_name,'bytes':video.stat().st_size,'realtimeDetected':False,'playback':False}
try:
 start=time.monotonic()
 while time.monotonic()-start<180:
  a=requests.get('http://127.0.0.1:8096/Items',headers=h,params={'Recursive':'true','IncludeItemTypes':'Movie','SearchTerm':test_name,'Fields':'Path'},timeout=15);a.raise_for_status()
  item=next((x for x in a.json().get('Items',[]) if x.get('Path')==str(video)),None)
  if item:
   result.update(realtimeDetected=True,seconds=round(time.monotonic()-start),itemId=item['Id'])
   b=requests.get('http://127.0.0.1:8096/Videos/'+item['Id']+'/stream',params={'static':'true'},headers={**h,'Range':'bytes=0-1023'},timeout=20)
   result.update(playback=b.status_code==206 and b.content==video.read_bytes()[:1024],httpStatus=b.status_code,receivedBytes=len(b.content))
   break
  time.sleep(5)
 print(json.dumps(result),flush=True)
finally:
 shutil.rmtree(folder)
 result['testFilesRemoved']=not folder.exists()
 (REC/'jellyfin-local-import-playback-test.json').write_text(json.dumps(result,indent=2))
