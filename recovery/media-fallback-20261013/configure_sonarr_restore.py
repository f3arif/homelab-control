#!/usr/bin/env python3
"""Activate restored Sonarr only after the verified local media copy finishes."""
import os,pathlib,json,subprocess,time,requests,xml.etree.ElementTree as E,datetime
R=pathlib.Path(os.environ['AFZ_FALLBACK_ROOT']);REC=pathlib.Path(os.environ['AFZ_REQUESTS_RECOVERY_DIR'])
copy=json.loads((REC/'tv-copy-receipt.json').read_text())
key=E.parse(R/'sonarr/config.xml').findtext('ApiKey');headers={'X-Api-Key':key};base='http://127.0.0.1:18801/api/v3/'
def arr(method,path,**kw):
 r=requests.request(method,base+path,headers=headers,timeout=35,**kw);r.raise_for_status();return r.json() if r.content else None
for _ in range(100):
 try:
  data=arr('GET','series')
  if len(data)==3:break
 except requests.RequestException:pass
 time.sleep(2)
else:raise RuntimeError('Sonarr did not become ready')
credentials=json.loads((R/'qbit-credentials.json').read_text())
client=next(x for x in arr('GET','downloadclient/schema') if x['implementation']=='QBittorrent')
client.update(name='AFZ qBittorrent TV Fallback',enable=True,priority=1,removeCompletedDownloads=True,removeFailedDownloads=True,tags=[])
values={'host':'qbittorrent','port':18796,'useSsl':False,'urlBase':'','username':credentials['username'],'password':credentials['password'],'tvCategory':'afz-tv-fallback'}
for f in client['fields']:
 if f['name'] in values:f['value']=values[f['name']]
client.pop('id',None)
existing=[x for x in arr('GET','downloadclient') if x['name']==client['name']]
saved=existing[0] if existing else arr('POST','downloadclient',json=client)
print('SONARR_QBIT_CONNECTED',saved['id'],flush=True)
root=arr('GET','rootfolder');assert any(x['path']=='/tv' and x['accessible'] for x in root)
ph={'X-Api-Key':E.parse(R/'prowlarr/config.xml').findtext('ApiKey')};pb='http://127.0.0.1:18798/api/v1/'
def prowlarr(method,path,**kw):
 r=requests.request(method,pb+path,headers=ph,timeout=180,**kw);r.raise_for_status();return r.json() if r.content else None
app=next(x for x in prowlarr('GET','applications/schema') if x['implementation']=='Sonarr')
app.update(name='AFZ Sonarr Fallback',syncLevel='fullSync',enable=True,tags=[]);app.pop('id',None)
values={'prowlarrUrl':'http://prowlarr:9696','baseUrl':'http://sonarr:8989','apiKey':key}
for f in app['fields']:
 if f['name'] in values:f['value']=values[f['name']]
prowlarr('POST','applications/test',json=app)
existing=[x for x in prowlarr('GET','applications') if x.get('name')==app['name']]
app=existing[0] if existing else prowlarr('POST','applications',json=app)
print('PROWLARR_SONARR_CONNECTED',app['id'],flush=True)
prowlarr('POST','command',json={'name':'ApplicationIndexerSync','applicationId':app['id']})
settings=json.loads((R/'seerr/settings.json').read_text());sh={'X-Api-Key':settings['main']['apiKey']}
original=json.loads((REC/'original/jellyseerr/settings.json').read_text())['sonarr'][0]
original.update(name='AFZ Sonarr Fallback',hostname='127.0.0.1',port=18801,useSsl=False,apiKey=key,baseUrl='',activeProfileId=4,activeProfileName='HD-1080p',activeDirectory='/tv',activeAnimeProfileId=4,activeAnimeProfileName='HD-1080p',activeAnimeDirectory='/tv',isDefault=True,syncEnabled=True)
original.pop('id',None)
existing=requests.get('http://127.0.0.1:18799/api/v1/settings/sonarr',headers=sh,timeout=30);existing.raise_for_status()
matched=[x for x in existing.json() if x.get('hostname')=='127.0.0.1' and x.get('port')==18801]
if matched: a=existing; seerr_id=matched[0]['id']
else:
 a=requests.post('http://127.0.0.1:18799/api/v1/settings/sonarr',headers=sh,json=original,timeout=60);a.raise_for_status();seerr_id=a.json().get('id')
print('SEERR_SONARR_CONNECTED',seerr_id,flush=True)
receipt={'activated':datetime.datetime.now(datetime.timezone.utc).isoformat(),'version':arr('GET','system/status')['version'],'series':len(arr('GET','series')),'copyFiles':len(copy['files']),'copyBytes':copy['bytes'],'qbitClient':saved['id'],'prowlarrApp':app['id'],'seerrServer':seerr_id,'root':'/tv'}
(REC/'sonarr-activation-receipt.json').write_text(json.dumps(receipt,indent=2));print(json.dumps(receipt),flush=True)
