#!/usr/bin/env python3
"""Observe one already completed download; never add or alter a download."""
import os,pathlib,json,time,datetime,requests,xml.etree.ElementTree as E
R=pathlib.Path(os.environ['AFZ_FALLBACK_ROOT']);REC=pathlib.Path(os.environ['AFZ_REQUESTS_RECOVERY_DIR'])
MID=int(os.environ['AFZ_VERIFY_MOVIE_ID'])
settings=json.loads((R/'seerr/settings.json').read_text())
rh={'X-Api-Key':E.parse(R/'radarr/config.xml').findtext('ApiKey')}
jh={'Authorization':'MediaBrowser Token="'+settings['jellyfin']['apiKey']+'"'}
end=time.monotonic()+7200
receipt={'started':datetime.datetime.now(datetime.timezone.utc).isoformat(),'movieId':MID,'readOnlyObserver':True,'importComplete':False,'playbackVerified':False}
def get(url,headers,params=None):
 r=requests.get(url,headers=headers,params=params,timeout=45);r.raise_for_status();return r.json()
while time.monotonic()<end:
 try:
  m=get('http://127.0.0.1:18797/api/v3/movie/'+str(MID),rh)
  folder=R/'library-landing'/pathlib.PurePosixPath(m['path']).name
  files=[p for p in folder.rglob('*') if p.suffix.lower() in ['.mkv','.mp4','.avi','.m4v'] and p.is_file()]
  receipt.update(checked=datetime.datetime.now(datetime.timezone.utc).isoformat(),hasFile=m.get('hasFile',False),landingBytes=sum(p.stat().st_size for p in files))
  if m.get('hasFile') and m.get('movieFile',{}).get('size',0)>0:
   size=m['movieFile']['size'];receipt['importComplete']=True;receipt['movieFileBytes']=size
   items=get('http://127.0.0.1:8096/Items',jh,{'ParentId':'0f5cc10cb4a519457e7212f69c697fb7','Recursive':'true','IncludeItemTypes':'Movie','Fields':'Path','Limit':100})['Items']
   found=next((x for x in items if x.get('Path') and pathlib.Path(x['Path']).parent==folder and pathlib.Path(x['Path']).stat().st_size==size),None)
   if found:
    media=pathlib.Path(found['Path']);start=max(0,size-1024)
    with media.open('rb') as f:f.seek(start);expected=f.read()
    h=dict(jh,Range='bytes='+str(start)+'-'+str(size-1))
    r=requests.get('http://127.0.0.1:8096/Videos/'+found['Id']+'/stream',headers=h,params={'static':'true'},timeout=45)
    receipt.update(jellyfinItemId=found['Id'],httpStatus=r.status_code,receivedBytes=len(r.content),playbackVerified=r.status_code==206 and r.content==expected)
    if receipt['playbackVerified']:
     receipt['completed']=datetime.datetime.now(datetime.timezone.utc).isoformat()
     (REC/'restored-movie-import-observation.json').write_text(json.dumps(receipt,indent=2))
     print('IMPORT_AND_FINAL_BYTE_RANGE_VERIFIED',flush=True);break
  receipt.pop('lastError',None)
 except Exception as e:receipt['lastError']=str(e)
 (REC/'restored-movie-import-observation.json').write_text(json.dumps(receipt,indent=2))
 print(json.dumps({k:receipt.get(k) for k in ['checked','landingBytes','hasFile','lastError']}),flush=True)
 time.sleep(30)
else:
 receipt['observationTimedOut']=True
 (REC/'restored-movie-import-observation.json').write_text(json.dumps(receipt,indent=2))
