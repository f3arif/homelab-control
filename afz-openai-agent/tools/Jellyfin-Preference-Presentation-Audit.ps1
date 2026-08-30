#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
Write-Output 'AFZ_JELLYFIN_PREFERENCE_PRESENTATION_AUDIT_V2'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'DB_WRITE=false'
Write-Output 'SERVICE_ACTION=false'
Write-Output 'SECRET_EXPOSED=false'
if(-not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'AUDIT_STATUS=SAFE_STOP|reason=DB_NOT_FOUND';exit 0}
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'AUDIT_STATUS=SAFE_STOP|reason=NO_PYTHON';exit 0}
$tmp=Join-Path $env:TEMP ('jf-pref-presentation-v2-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3,pathlib,json,re,sys,uuid,collections
p=sys.argv[1]
con=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=5)
con.row_factory=sqlite3.Row

def norm(v):
    if v is None:return ''
    if isinstance(v,(bytes,bytearray)):
        try:return str(uuid.UUID(bytes=bytes(v))).replace('-','').lower()
        except:return bytes(v).hex().lower()
    return re.sub(r'[^0-9A-Fa-f]','',str(v)).lower()

def sval(v):
    if v is None:return ''
    if isinstance(v,(bytes,bytearray)):
        try:return str(uuid.UUID(bytes=bytes(v)))
        except:return bytes(v).hex()
    return str(v)

def cols(t):return [r[1] for r in con.execute('pragma table_info("'+t.replace('"','""')+'")')]
try:
    tables={r[0] for r in con.execute("select name from sqlite_master where type='table'")}
    users={}
    if 'Users' in tables:
        uc=cols('Users'); nc='Username' if 'Username' in uc else ('Name' if 'Name' in uc else None)
        q='select Id'+((','+nc) if nc else '')+' from Users'
        for r in con.execute(q):users[norm(r['Id'])]=sval(r[nc]) if nc else norm(r['Id'])
    print('USER_COUNT='+str(len(users)))
    # Reconfirm the four presentation preferences using exact Jellyfin enum values.
    kinds={7:'LatestItemExcludes',8:'MyMediaExcludes',9:'GroupedFolders',11:'OrderedViews'}
    if 'Preferences' in tables:
        for r in con.execute('select UserId,Kind,Value from Preferences where Kind in (7,8,9,11) order by UserId,Kind'):
            uid=norm(r['UserId']); vals=[x.strip() for x in sval(r['Value']).split(',') if x.strip()]
            print('PREF|'+json.dumps({'user':users.get(uid,uid),'userId':sval(r['UserId']),'kind':kinds.get(int(r['Kind']),str(r['Kind'])),'kindInt':int(r['Kind']),'count':len(vals),'values':vals},separators=(',',':')))
    for t in ['DisplayPreferences','CustomItemDisplayPreferences','ItemDisplayPreferences']:
        if t in tables:print('SCHEMA|'+json.dumps({'table':t,'columns':cols(t)},separators=(',',':')))
    if 'CustomItemDisplayPreferences' in tables:
        c=cols('CustomItemDisplayPreferences')
        need=['Id','Client','ItemId','Key','UserId','Value']
        if all(x in c for x in need):
            rows=list(con.execute('select Id,Client,ItemId,Key,UserId,Value from CustomItemDisplayPreferences order by UserId,Client,ItemId,Key'))
            print('CUSTOM_DP_TOTAL='+str(len(rows)))
            selected=[]
            group=collections.defaultdict(dict)
            for r in rows:
                key=sval(r['Key']); client=sval(r['Client']); val=sval(r['Value']); uid=norm(r['UserId'])
                ishome=key.lower().startswith('homesection') or key.lower().startswith('landing-') or 'home' in key.lower()
                if ishome or client.lower()=='emby':
                    obj={'user':users.get(uid,uid),'userId':sval(r['UserId']),'client':client,'itemId':sval(r['ItemId']),'key':key,'value':val}
                    selected.append(obj)
                    if ishome:group[(uid,client,sval(r['ItemId']))][key]=val
            print('CUSTOM_DP_SELECTED='+str(len(selected)))
            for o in selected:print('CUSTOM_DP|'+json.dumps(o,separators=(',',':')))
            for (uid,client,item),home in group.items():
                print('HOME_SECTIONS|'+json.dumps({'user':users.get(uid,uid),'userId':uid,'client':client,'itemId':item,'home':home},separators=(',',':')))
    if 'DisplayPreferences' in tables:
        c=cols('DisplayPreferences'); fields=[x for x in ['Id','UserId','Client','ItemId','ShowSidebar','ShowBackdrop','TvHome','IndexBy'] if x in c]
        if fields:
            rows=list(con.execute('select '+','.join(fields)+' from DisplayPreferences order by UserId,Client,ItemId'))
            print('DISPLAY_DP_TOTAL='+str(len(rows)))
            for r in rows:
                client=sval(r['Client']) if 'Client' in fields else ''
                if client.lower()=='emby':
                    uid=norm(r['UserId']) if 'UserId' in fields else ''
                    obj={'user':users.get(uid,uid)}
                    for f in fields:obj[f]=sval(r[f])
                    print('DISPLAY_EMBY|'+json.dumps(obj,separators=(',',':')))
    if 'ItemDisplayPreferences' in tables:
        c=cols('ItemDisplayPreferences')
        common=[x for x in ['Id','UserId','Client','ItemId','ViewType','SortBy','SortOrder','RememberIndexing','IndexBy'] if x in c]
        if common:
            print('ITEM_DP_FIELDS='+json.dumps(common,separators=(',',':')))
            q='select '+','.join(common)+' from ItemDisplayPreferences limit 500'
            for r in con.execute(q):
                client=sval(r['Client']) if 'Client' in common else ''
                if not client or client.lower()=='emby':
                    uid=norm(r['UserId']) if 'UserId' in common else ''
                    obj={'user':users.get(uid,uid)}
                    for f in common:obj[f]=sval(r[f])
                    print('ITEM_DP|'+json.dumps(obj,separators=(',',':')))
    print('AUDIT_STATUS=PASS')
finally:con.close()
'@
[IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
try{
 $exe=$py.Path
 if([IO.Path]::GetFileName($exe) -match '^py(\.exe)?$'){& $exe -3 $tmp $db}else{& $exe $tmp $db}
 $ec=$LASTEXITCODE;Write-Output ('PYTHON_EXIT='+$ec);if($ec -ne 0){exit $ec}
}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
