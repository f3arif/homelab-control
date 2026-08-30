#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
Write-Output 'AFZ_JELLYFIN_PREFERENCE_PRESENTATION_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'DB_WRITE=false'
Write-Output 'SERVICE_ACTION=false'
Write-Output 'SECRET_EXPOSED=false'
if(-not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'AUDIT_STATUS=SAFE_STOP|reason=DB_NOT_FOUND';exit 0}
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'AUDIT_STATUS=SAFE_STOP|reason=NO_PYTHON';exit 0}
$tmp=Join-Path $env:TEMP ('jf-pref-presentation-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3, pathlib, json, re, sys, uuid
p=sys.argv[1]
con=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro', uri=True, timeout=5)
con.row_factory=sqlite3.Row

def norm(v):
    if v is None: return ''
    if isinstance(v,(bytes,bytearray)):
        try: return str(uuid.UUID(bytes=bytes(v))).replace('-','').lower()
        except Exception: return bytes(v).hex().lower()
    return re.sub(r'[^0-9A-Fa-f]','',str(v)).lower()

def sval(v):
    if v is None: return ''
    if isinstance(v,(bytes,bytearray)):
        try: return str(uuid.UUID(bytes=bytes(v)))
        except Exception: return bytes(v).hex()
    return str(v)

def tables():
    return [r[0] for r in con.execute("select name from sqlite_master where type='table' order by name")]

def cols(t):
    return [r[1] for r in con.execute('pragma table_info("'+t.replace('"','""')+'")')]

try:
    ts=tables()
    print('TABLES_MATCHING_DISPLAY='+json.dumps([t for t in ts if 'displaypreference' in t.lower()],separators=(',',':')))
    users={}
    if 'Users' in ts:
        uc=cols('Users')
        namecol='Username' if 'Username' in uc else ('Name' if 'Name' in uc else None)
        q='select Id'+((','+namecol) if namecol else '')+' from Users'
        for r in con.execute(q):
            users[norm(r['Id'])]=sval(r[namecol]) if namecol else norm(r['Id'])
    print('USER_COUNT='+str(len(users)))

    libs={}
    if 'BaseItems' in ts:
        bc=cols('BaseItems')
        needed=[c for c in ['Id','Name','Path','Type'] if c in bc]
        if 'Id' in needed and 'Name' in needed:
            where=" where Type like '%CollectionFolder%'" if 'Type' in bc else ''
            q='select '+','.join(needed)+' from BaseItems'+where+' order by Name'
            for r in con.execute(q):
                rid=norm(r['Id'])
                libs[rid]={'id':sval(r['Id']),'name':sval(r['Name']),'path':sval(r['Path']) if 'Path' in needed else '','type':sval(r['Type']) if 'Type' in needed else ''}
    if not libs and 'CollectionFolders' in ts:
        cc=cols('CollectionFolders')
        needed=[c for c in ['Id','Name','Path'] if c in cc]
        if 'Id' in needed and 'Name' in needed:
            for r in con.execute('select '+','.join(needed)+' from CollectionFolders order by Name'):
                rid=norm(r['Id'])
                libs[rid]={'id':sval(r['Id']),'name':sval(r['Name']),'path':sval(r['Path']) if 'Path' in needed else '','type':'CollectionFolder'}
    print('LIBRARY_COUNT='+str(len(libs)))
    for x in sorted(libs.values(),key=lambda z:z['name'].lower()):
        print('LIB|'+json.dumps(x,separators=(',',':')))

    kinds={7:'LatestItemExcludes',8:'MyMediaExcludes',9:'GroupedFolders',11:'OrderedViews'}
    pref_seen={}
    if 'Preferences' in ts:
        pc=cols('Preferences')
        if all(c in pc for c in ['UserId','Kind','Value']):
            for r in con.execute('select UserId,Kind,Value from Preferences where Kind in (7,8,9,11) order by UserId,Kind'):
                uidn=norm(r['UserId']); uname=users.get(uidn,uidn); kind=int(r['Kind']); raw=sval(r['Value'])
                vals=[v.strip() for v in raw.split(',') if v.strip()]
                mapped=[]; unmapped=[]
                for v in vals:
                    n=norm(v)
                    if n in libs: mapped.append({'id':v,'name':libs[n]['name']})
                    else: unmapped.append(v)
                obj={'user':uname,'userId':sval(r['UserId']),'kind':kinds.get(kind,str(kind)),'kindInt':kind,'count':len(vals),'values':vals,'mapped':mapped,'unmapped':unmapped}
                pref_seen[(uidn,kind)]=obj
                print('PREF|'+json.dumps(obj,separators=(',',':')))
    for uidn,uname in users.items():
        summary={'user':uname,'userId':uidn}
        for k,n in kinds.items(): summary[n]=pref_seen.get((uidn,k),{'count':0}).get('count',0)
        print('PREF_SUMMARY|'+json.dumps(summary,separators=(',',':')))

    dpt=[t for t in ts if 'displaypreference' in t.lower()]
    for t in dpt:
        c=cols(t)
        print('DP_SCHEMA|'+json.dumps({'table':t,'columns':c},separators=(',',':')))
        if t.lower()=='displaypreferences':
            selected=[x for x in ['Id','UserId','Client','ItemId','CustomPrefs','ViewType','SortBy','IndexBy'] if x in c]
            if selected:
                rows=list(con.execute('select '+','.join(selected)+' from DisplayPreferences limit 500'))
                print('DP_ROW_COUNT='+str(len(rows)))
                for r in rows:
                    uidn=norm(r['UserId']) if 'UserId' in selected else ''
                    raw=sval(r['CustomPrefs']) if 'CustomPrefs' in selected else ''
                    home={}
                    if raw:
                        try:
                            j=json.loads(raw)
                            if isinstance(j,dict):
                                for k,v in j.items():
                                    if k.lower().startswith('homesection') or k.lower().startswith('landing-'):
                                        home[k]=v
                        except Exception:
                            for m in re.finditer(r'(?i)(HomeSection\d+|landing-[A-Za-z0-9_.-]+)[^A-Za-z0-9_.-]{1,6}([^,;}\r\n]+)',raw):
                                home[m.group(1)]=m.group(2).strip(' \"')
                    obj={'user':users.get(uidn,uidn),'userId':sval(r['UserId']) if 'UserId' in selected else '', 'client':sval(r['Client']) if 'Client' in selected else '', 'itemId':sval(r['ItemId']) if 'ItemId' in selected else '', 'home':home}
                    for x in ['ViewType','SortBy','IndexBy']:
                        if x in selected: obj[x]=sval(r[x])
                    print('DP_ROW|'+json.dumps(obj,separators=(',',':')))
    print('AUDIT_STATUS=PASS')
finally:
    con.close()
'@
[IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
try {
  $exe=$py.Path
  if([IO.Path]::GetFileName($exe) -match '^py(\.exe)?$'){& $exe -3 $tmp $db}else{& $exe $tmp $db}
  $ec=$LASTEXITCODE
  Write-Output ('PYTHON_EXIT='+$ec)
  if($ec -ne 0){exit $ec}
} finally {Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
