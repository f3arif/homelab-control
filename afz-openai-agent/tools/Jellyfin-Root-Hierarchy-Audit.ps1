#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
Write-Output 'AFZ_JELLYFIN_ROOT_HIERARCHY_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'DB_WRITE=false'
Write-Output 'SERVICE_ACTION=false'
if(-not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'AUDIT_STATUS=SAFE_STOP|reason=DB_NOT_FOUND';exit 0}
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'AUDIT_STATUS=SAFE_STOP|reason=NO_PYTHON';exit 0}
$tmp=Join-Path $env:TEMP ('jf-root-hierarchy-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3,pathlib,json,sys,uuid,re
p=sys.argv[1]
con=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=5)
con.row_factory=sqlite3.Row

def sv(v):
    if v is None:return ''
    if isinstance(v,(bytes,bytearray)):
        try:return str(uuid.UUID(bytes=bytes(v)))
        except:return bytes(v).hex()
    return str(v)
def n(v):return re.sub(r'[^0-9A-Fa-f]','',sv(v)).lower()
def cols(t):return [r[1] for r in con.execute('pragma table_info("'+t+'")')]
try:
    c=cols('BaseItems')
    fields=[x for x in ['Id','Name','Type','Path','ParentId','TopParentId','OwnerId','IsFolder','IsVirtualItem','PresentationUniqueKey','Data'] if x in c]
    allrows=list(con.execute('select '+','.join(fields)+' from BaseItems'))
    byid={n(r['Id']):r for r in allrows}
    colls=[r for r in allrows if 'CollectionFolder' in sv(r['Type'])]
    print('COLLECTION_COUNT='+str(len(colls)))
    parentids=set(); topids=set()
    for r in sorted(colls,key=lambda x:sv(x['Name']).lower()):
        pid=n(r['ParentId']) if 'ParentId' in fields else ''; tid=n(r['TopParentId']) if 'TopParentId' in fields else ''
        if pid:parentids.add(pid)
        if tid:topids.add(tid)
        obj={k:sv(r[k]) for k in fields if k!='Data'}
        if 'Data' in fields:
            raw=sv(r['Data']); ct=''
            try:
                j=json.loads(raw) if raw else {}
                for key in ['CollectionType','collectionType']:
                    if key in j:ct=str(j[key]);break
            except:pass
            obj['collectionType']=ct
        obj['parentResolved']=sv(byid[pid]['Name']) if pid in byid else ''
        obj['parentType']=sv(byid[pid]['Type']) if pid in byid else ''
        obj['topResolved']=sv(byid[tid]['Name']) if tid in byid else ''
        obj['topType']=sv(byid[tid]['Type']) if tid in byid else ''
        print('COLLECTION|'+json.dumps(obj,separators=(',',':')))
    print('DISTINCT_PARENT_IDS='+str(len(parentids)))
    for pid in sorted(parentids):
        r=byid.get(pid)
        print('PARENT|'+json.dumps({'id':sv(r['Id']) if r else pid,'name':sv(r['Name']) if r else '','type':sv(r['Type']) if r else '','path':sv(r['Path']) if r and 'Path' in fields else '','parentId':sv(r['ParentId']) if r and 'ParentId' in fields else '','topParentId':sv(r['TopParentId']) if r and 'TopParentId' in fields else ''},separators=(',',':')))
    rootish=[]
    for r in allrows:
        typ=sv(r['Type']); name=sv(r['Name']); path=sv(r['Path']) if 'Path' in fields else ''
        if any(x in typ for x in ['AggregateFolder','UserRootFolder','RootFolder']) or (not n(r['ParentId']) if 'ParentId' in fields else False):
            rootish.append(r)
    print('ROOTISH_COUNT='+str(len(rootish)))
    for r in rootish[:100]:
        print('ROOTISH|'+json.dumps({k:sv(r[k]) for k in fields if k!='Data'},separators=(',',':')))
    # Count direct children per distinct collection parent and list their collection-folder names.
    for pid in sorted(parentids):
        kids=[r for r in allrows if n(r['ParentId'])==pid]
        print('PARENT_CHILDREN|'+json.dumps({'parentId':pid,'count':len(kids),'collectionNames':[sv(r['Name']) for r in kids if 'CollectionFolder' in sv(r['Type'])]},separators=(',',':')))
    print('AUDIT_STATUS=PASS')
finally:con.close()
'@
[IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
try{
 $exe=$py.Path
 if([IO.Path]::GetFileName($exe) -match '^py(\.exe)?$'){& $exe -3 $tmp $db}else{& $exe $tmp $db}
 $ec=$LASTEXITCODE;Write-Output ('PYTHON_EXIT='+$ec);if($ec -ne 0){exit $ec}
}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
foreach($root in @('C:\Users\Faiz\AppData\Local\Jellyfin\root\default','C:\ProgramData\Jellyfin\Server\root\default')){
 Write-Output ('FS_ROOT|path='+$root+'|exists='+(Test-Path -LiteralPath $root -PathType Container))
 if(Test-Path -LiteralPath $root -PathType Container){
   foreach($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue|Sort-Object Name)){
     $links=@(Get-ChildItem -LiteralPath $d.FullName -Filter *.mblink -File -ErrorAction SilentlyContinue)
     Write-Output ('FS_LIBRARY|root='+$root+'|name='+$d.Name+'|mblinks='+$links.Count)
   }
 }
}
