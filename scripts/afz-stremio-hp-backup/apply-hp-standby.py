#!/usr/bin/env python3
from pathlib import Path
import sys

src=Path(sys.argv[1])
dst=Path(sys.argv[2])
s=src.read_text(encoding='utf-8')

marker="FAILOVER_MODE=str(os.getenv('AFZ_STREMIO_FAILOVER_MODE','')).strip().lower() in ('1','true','yes','on')\n"
insert="""FAILOVER_MODE=str(os.getenv('AFZ_STREMIO_FAILOVER_MODE','')).strip().lower() in ('1','true','yes','on')
BACKUP_STANDBY_MODE=str(os.getenv('AFZ_BACKUP_STANDBY_MODE','')).strip().lower() in ('1','true','yes','on')
PRIMARY_HEALTH_URL=os.getenv('AFZ_PRIMARY_HEALTH_URL','https://desktop-h3r6cqn.tailc9bb62.ts.net:8445/manifest.json').strip()
_primary_health_cache={'ts':0.0,'ok':False}
def _primary_is_healthy():
    if not BACKUP_STANDBY_MODE: return False
    now=time.time()
    if now-float(_primary_health_cache.get('ts') or 0)<5: return bool(_primary_health_cache.get('ok'))
    ok=False
    try:
        r=requests.get(PRIMARY_HEALTH_URL,timeout=2)
        d=r.json() if r.ok else {}
        ok=bool(r.ok and d.get('id')=='com.afzengineering.releasecatalog' and d.get('version')==APP_VERSION)
    except Exception: ok=False
    _primary_health_cache.update({'ts':now,'ok':ok})
    return ok
"""
if 'BACKUP_STANDBY_MODE=' not in s:
    if marker not in s: raise SystemExit('FAILOVER_MARKER_MISSING')
    s=s.replace(marker,insert,1)

manifest_marker="    return {'id':'com.afzengineering.releasecatalog','version':APP_VERSION,'name':'AFZ Movies & TV'"
if "com.afzengineering.releasecatalog.hpbackup" not in s:
    idx=s.find(manifest_marker)
    if idx<0: raise SystemExit('MANIFEST_MARKER_MISSING')
    backup="""    if BACKUP_STANDBY_MODE:
        return {'id':'com.afzengineering.releasecatalog.hpbackup','version':APP_VERSION,'name':'AFZ Movies & TV - HP Backup','description':'Hot standby stream provider. Silent while H3 primary is healthy.','resources':[{'name':'stream','types':['movie','series','tv','sport'],'idPrefixes':['tt','afzlib','afzhindilive','afzcanada','afzbollywood','afzfast','afzplutotv','afzsport','afzplutosport']}],'types':['movie','series','tv','sport'],'catalogs':[]}
"""
    s=s[:idx]+backup+s[idx:]

gate="    if BACKUP_STANDBY_MODE and _primary_is_healthy():\n        response.headers['Cache-Control']='no-store, max-age=0'\n        return {'streams':[]}\n"
for sig in (
    "def hindi_live_stream(vid:str,response:Response):\n",
    "def free_sports_stream(vid:str,response:Response):\n",
    "def stream(vid:str,request:Request,response:Response):\n",
    "def series_stream(vid:str,request:Request,response:Response):\n",
):
    if sig not in s: raise SystemExit('STREAM_MARKER_MISSING:'+sig.strip())
    pos=s.find(sig)+len(sig)
    if s[pos:pos+len(gate)]!=gate:
        s=s[:pos]+gate+s[pos:]

dst.write_text(s,encoding='utf-8')
print('HP_STANDBY_PATCH_OK')
