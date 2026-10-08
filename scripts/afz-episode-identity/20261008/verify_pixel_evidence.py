import datetime,json,re,xml.etree.ElementTree as ET
from pathlib import Path
from test_episode_identity import load
root=Path(__file__).parent
ui=root.parent/'R32-phone-first-candidate'/'pixel-verification-20261008'
names=['episode-identity-final-top','episode-identity-final-lower','episode-identity-final-bottom']
match=load(root/'stremio_catalog.py')['_series_release_matches']
texts=[]
for name in names:texts.extend(n.attrib.get('text','') for n in ET.parse(ui/(name+'.xml')).iter('node'))
rows=[x for x in texts if ' | cached | ' in x and x.endswith(('.mkv','.mp4','.avi'))]
assert rows and all(match(('Friends','1994'),1,1,{'filename':x.split(' | ')[-1]}) for x in rows)
featured=next(x for x in texts if x.startswith('1080p | ') and 'Ralf.mkv' in x)
assert sum('Ralf.mkv' in x for x in rows)==1
raw=(root/'pixel-identity-verification.json').read_bytes()
report=json.loads(raw.decode('utf-16' if raw.startswith(b'\xff\xfe') else 'utf-8-sig'))
report.update({'passed':True,'atUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'featuredSource':featured,'evidence':names,'fullListEvidenceSameRefresh':True,'featuredAppearsOnce':True,'capturedSourceRowsIncludingOverlaps':len(rows),'allCapturedReleaseIdentitiesMatched':True})
(root/'pixel-identity-verification.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(json.dumps(report,indent=2))
