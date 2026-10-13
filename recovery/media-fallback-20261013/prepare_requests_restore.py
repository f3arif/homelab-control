import copy, datetime, json, os, pathlib, shutil, sqlite3, xml.etree.ElementTree as ET, requests
ROOT=pathlib.Path(os.environ['AFZ_FALLBACK_ROOT'])
REC=pathlib.Path(os.environ['AFZ_REQUESTS_RECOVERY_DIR'])
src=REC/'original/jellyseerr'; dst=REC/'seerr-restored-candidate'
shutil.copytree(src,dst)
cfg=json.loads((dst/'settings.json').read_text(encoding='utf-8-sig'))
hdr={'Authorization':'MediaBrowser Client="AFZ Recovery", Device="HP Envy", DeviceId="afz-requests-recovery", Version="1.0", Token="'+cfg['jellyfin']['apiKey']+'"'}
base='http://127.0.0.1:8096'
users=requests.get(base+'/Users',headers=hdr,timeout=15); users.raise_for_status()
users=users.json()
with sqlite3.connect(src/'db/db.sqlite3') as original_db:
    expected_owner=original_db.execute('select jellyfinUserId,jellyfinUsername from user where id=1').fetchone()
owner=next(u for u in users if u['Id']==expected_owner[0])
assert owner['Policy']['IsAdministrator'] and not owner['Policy']['IsDisabled']
db=sqlite3.connect(dst/'db/db.sqlite3')
old_owner=db.execute('select jellyfinUserId,jellyfinUsername from user where id=1').fetchone()
assert old_owner[0]==owner['Id'] and old_owner[1].lower()==owner['Name'].lower()
assert db.execute('pragma quick_check').fetchone()[0]=='ok'
counts={t:db.execute('select count(*) from "'+t+'"').fetchone()[0] for t in ['user','media_request','media']}
db.close()
system=requests.get(base+'/System/Info',headers=hdr,timeout=15);system.raise_for_status();system=system.json()
cfg['jellyfin'].update(ip='127.0.0.1',port=8096,useSsl=False,urlBase='',externalHostname=os.environ['AFZ_JELLYFIN_PUBLIC_URL'],serverId=system['Id'])
cfg['main']['applicationUrl']=os.environ['AFZ_REQUESTS_PUBLIC_URL']
radarr_key=ET.parse(ROOT/'radarr/config.xml').findtext('ApiKey')
profiles=requests.get('http://127.0.0.1:18797/api/v3/qualityprofile',headers={'X-Api-Key':radarr_key},timeout=15);profiles.raise_for_status()
profile=next(x for x in profiles.json() if x['name']=='HD-1080p')
for r in cfg['radarr']:
    r.update(hostname='127.0.0.1',port=18797,apiKey=radarr_key,useSsl=False,baseUrl='',activeDirectory='/movies',activeProfileId=profile['id'],activeProfileName=profile['name'],externalUrl=os.environ['AFZ_RADARR_PUBLIC_URL'],syncEnabled=False)
# The original TV connector is retained in the private source backup.
# No Sonarr service is currently running on this replacement host.
old_sonarr_count=len(cfg.get('sonarr',[]))
cfg['sonarr']=[]
disabled_notifications=[]
for name,agent in cfg.get('notifications',{}).get('agents',{}).items():
    if isinstance(agent,dict) and agent.get('enabled'):
        agent['enabled']=False;disabled_notifications.append(name)
(dst/'settings.json').write_text(json.dumps(cfg,indent=2),encoding='utf-8')
for p in dst.rglob('*'):
    if p.is_file():p.chmod(0o600)
report={'prepared_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'candidate':str(dst),'counts':counts,'owner_verified_by_jellyfin_id':True,'jellyfin_modern_auth_http':200,'radarr_profile':profile['name'],'radarr_root':'/movies','old_sonarr_connectors_archived':old_sonarr_count,'notification_agents_held':disabled_notifications,'passwords_changed':False}
(REC/'restore-preflight.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
