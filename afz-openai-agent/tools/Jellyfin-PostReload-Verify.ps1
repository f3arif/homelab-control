#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$baseUri='http://127.0.0.1:8096'
$gatewayHealth='http://127.0.0.1:8766/health'
$expected=@(
 'Bollywood   Hindi (TorBox)',
 'Bollywood - Hindi (All Sources)',
 'Bollywood - Hindi (Downloaded)',
 'Downloaded Movies',
 'Downloading',
 'Home Videos and Photos',
 'Movies',
 'Movies - All Sources',
 'Real-Debrid Movies',
 'Stream Now (TorBox)',
 'TorBox Downloaded Movies',
 'qBittorrent Movies'
)
Write-Output 'AFZ_JELLYFIN_POST_RELOAD_VERIFY_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'

# 1) Live Jellyfin process and active datadir.
$procs=@(Get-CimInstance Win32_Process -Filter "Name='jellyfin.exe'" -ErrorAction SilentlyContinue)
Write-Output ('JELLYFIN_PROCESS_COUNT='+$procs.Count)
if($procs.Count -ne 1){Write-Output 'VERIFY_STATUS=FAIL|reason=JELLYFIN_PROCESS_COUNT_NOT_ONE';exit 1}
$p=$procs[0]
$pid1=[int]$p.ProcessId
$cmd=[string]$p.CommandLine
$dataDir=$null
if($cmd -match '--datadir\s+"([^"]+)"'){$dataDir=$matches[1]}
elseif($cmd -match '--datadir\s+(\S+)'){$dataDir=$matches[1]}
if(-not $dataDir){$dataDir='C:\Users\Faiz\AppData\Local\Jellyfin'}
$db=Join-Path $dataDir 'data\jellyfin.db'
$rootDefault=Join-Path $dataDir 'root\default'
Write-Output ('JELLYFIN_PID='+$pid1)
Write-Output ('DATADIR='+$dataDir)
Write-Output ('DB_EXISTS='+(Test-Path -LiteralPath $db -PathType Leaf))
Write-Output ('ROOT_DEFAULT_EXISTS='+(Test-Path -LiteralPath $rootDefault -PathType Container))

# 2) HTTP health and PID stability.
$httpOk=$false
try{
 $resp=Invoke-WebRequest -UseBasicParsing -Uri ($baseUri+'/System/Info/Public') -TimeoutSec 10
 $httpOk=([int]$resp.StatusCode -eq 200)
 Write-Output ('JELLYFIN_HTTP='+[int]$resp.StatusCode)
 $info=$resp.Content|ConvertFrom-Json
 Write-Output ('SERVER_VERSION='+[string]$info.Version)
}catch{Write-Output ('JELLYFIN_HTTP=FAIL|'+$_.Exception.Message)}
Start-Sleep -Seconds 5
$p2=@(Get-CimInstance Win32_Process -Filter "Name='jellyfin.exe'" -ErrorAction SilentlyContinue)
$pidStable=($p2.Count -eq 1 -and [int]$p2[0].ProcessId -eq $pid1)
Write-Output ('PID_STABLE_5S='+$pidStable)

# 3) Filesystem virtual-folder graph.
$rootNames=@()
if(Test-Path -LiteralPath $rootDefault -PathType Container){
 $rootNames=@(Get-ChildItem -LiteralPath $rootDefault -Directory -Force -ErrorAction SilentlyContinue|ForEach-Object{$_.Name}|Sort-Object -Unique)
}
Write-Output ('ROOT_LIBRARY_DIR_COUNT='+$rootNames.Count)
foreach($n in $rootNames){Write-Output ('ROOT_LIBRARY='+$n)}

# 4) Read-only SQLite inspection: BaseItems collection folders / expected names + user folder-access policy + .strm candidates.
$dbAudit=$null
$strmPaths=@()
if(Test-Path -LiteralPath $db -PathType Leaf){
 $py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
 if($py){
  $tmpPy=Join-Path $env:TEMP ('jf-postverify-'+[guid]::NewGuid().ToString('n')+'.py')
  $tmpJson=Join-Path $env:TEMP ('jf-postverify-'+[guid]::NewGuid().ToString('n')+'.json')
  $code=@'
import json, sqlite3, sys
p=sys.argv[1]
out={"tables":[],"libraries":[],"expected":[],"users":[],"strm_paths":[],"errors":[]}
expected=[
 "Bollywood   Hindi (TorBox)","Bollywood - Hindi (All Sources)","Bollywood - Hindi (Downloaded)",
 "Downloaded Movies","Downloading","Home Videos and Photos","Movies","Movies - All Sources",
 "Real-Debrid Movies","Stream Now (TorBox)","TorBox Downloaded Movies","qBittorrent Movies"]
try:
 c=sqlite3.connect("file:"+p.replace('\\','/')+"?mode=ro",uri=True,timeout=10)
 c.row_factory=sqlite3.Row
 tables=[r[0] for r in c.execute("select name from sqlite_master where type='table'")]
 out["tables"]=tables
 if "BaseItems" in tables:
  cols=[r[1] for r in c.execute("pragma table_info(BaseItems)")]
  lc={x.lower():x for x in cols}
  pick=[lc[x] for x in ("id","name","type","path","parentid") if x in lc]
  if "name" in lc:
   qs=','.join('?' for _ in expected)
   q="select "+','.join('"'+x+'"' for x in pick)+" from BaseItems where \""+lc['name']+"\" in ("+qs+")"
   out["expected"]=[dict(r) for r in c.execute(q,expected)]
  if "type" in lc and "name" in lc:
   q="select "+','.join('"'+x+'"' for x in pick)+" from BaseItems where lower(cast(\""+lc['type']+"\" as text)) like '%collectionfolder%'"
   out["libraries"]=[dict(r) for r in c.execute(q)]
  if "path" in lc:
   q="select \""+lc['path']+"\" from BaseItems where lower(cast(\""+lc['path']+"\" as text)) like '%.strm' limit 200"
   out["strm_paths"]=[r[0] for r in c.execute(q) if r[0]]
 if "Users" in tables:
  ucols=[r[1] for r in c.execute("pragma table_info(Users)")]; ulc={x.lower():x for x in ucols}
  if "id" in ulc and "username" in ulc:
   users=[dict(r) for r in c.execute('select "'+ulc['id']+'" as Id,"'+ulc['username']+'" as Username from Users')]
  elif "id" in ulc and "name" in ulc:
   users=[dict(r) for r in c.execute('select "'+ulc['id']+'" as Id,"'+ulc['name']+'" as Username from Users')]
  else: users=[]
  perms={}; prefs={}
  if "Permissions" in tables:
   pc=[r[1] for r in c.execute("pragma table_info(Permissions)")]; pl={x.lower():x for x in pc}
   if all(x in pl for x in ("userid","kind","value")):
    for r in c.execute('select "'+pl['userid']+'","'+pl['kind']+'","'+pl['value']+'" from Permissions where "'+pl['kind']+'"=?',(16,)):
     perms[str(r[0])]=r[2]
  if "Preferences" in tables:
   pc=[r[1] for r in c.execute("pragma table_info(Preferences)")]; pl={x.lower():x for x in pc}
   if all(x in pl for x in ("userid","kind","value")):
    for r in c.execute('select "'+pl['userid']+'","'+pl['kind']+'","'+pl['value']+'" from Preferences where "'+pl['kind']+'"=?',(5,)):
     prefs[str(r[0])]=r[2]
  for u in users:
   uid=str(u.get("Id"))
   out["users"].append({"Id":uid,"Username":u.get("Username"),"EnableAllFolders":perms.get(uid),"EnabledFolders":prefs.get(uid)})
 c.close()
except Exception as e:
 out["errors"].append(type(e).__name__+":"+str(e))
print(json.dumps(out,separators=(',',':')))
'@
  [IO.File]::WriteAllText($tmpPy,$code,(New-Object Text.UTF8Encoding($false)))
  try{
   $exe=$py.Path
   if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){$json=(& $exe -3 $tmpPy $db 2>&1|Out-String)}else{$json=(& $exe $tmpPy $db 2>&1|Out-String)}
   if($LASTEXITCODE -eq 0){$dbAudit=$json|ConvertFrom-Json}else{Write-Output ('DB_AUDIT=FAIL|python_exit='+$LASTEXITCODE)}
  }catch{Write-Output ('DB_AUDIT=FAIL|'+$_.Exception.Message)}finally{Remove-Item -LiteralPath $tmpPy -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $tmpJson -Force -ErrorAction SilentlyContinue}
 }else{Write-Output 'DB_AUDIT=SKIP|reason=NO_PYTHON'}
}
if($dbAudit){
 $libs=@($dbAudit.libraries)
 $exp=@($dbAudit.expected)
 Write-Output ('DB_COLLECTION_FOLDER_COUNT='+$libs.Count)
 foreach($r in $libs){Write-Output ('DB_LIBRARY='+[string]$r.Name)}
 $foundNames=@($exp|ForEach-Object{[string]$_.Name}|Sort-Object -Unique)
 $missing=@($expected|Where-Object{$_ -notin $foundNames})
 Write-Output ('EXPECTED_LIBRARY_FOUND_COUNT='+$foundNames.Count)
 Write-Output ('EXPECTED_LIBRARY_MISSING_COUNT='+$missing.Count)
 foreach($m in $missing){Write-Output ('EXPECTED_LIBRARY_MISSING='+$m)}
 foreach($u in @($dbAudit.users)){
  $ef=[string]$u.EnableAllFolders
  $folders=[string]$u.EnabledFolders
  if($folders.Length -gt 300){$folders=$folders.Substring(0,300)+'...'}
  Write-Output ('USER_FOLDER_POLICY|name='+[string]$u.Username+'|id='+[string]$u.Id+'|EnableAllFolders='+$ef+'|EnabledFolders='+$folders)
 }
 foreach($e in @($dbAudit.errors)){Write-Output ('DB_AUDIT_ERROR='+[string]$e)}
 $strmPaths=@($dbAudit.strm_paths)
 Write-Output ('DB_STRM_CANDIDATE_COUNT='+$strmPaths.Count)
}

# 5) TorBox gateway health, no secret/URL output.
$gatewayOk=$false
try{$g=Invoke-WebRequest -UseBasicParsing -Uri $gatewayHealth -TimeoutSec 8;$gatewayOk=([int]$g.StatusCode -eq 200);Write-Output ('TORBOX_HEALTH_HTTP='+[int]$g.StatusCode)}catch{Write-Output ('TORBOX_HEALTH_HTTP=FAIL|'+$_.Exception.Message)}

function Test-RangeCandidate([string]$path,[string]$label){
 if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $false}
 try{$line=(Get-Content -LiteralPath $path -TotalCount 3 -ErrorAction Stop|Where-Object{$_ -and $_.Trim()}|Select-Object -First 1).Trim()}catch{return $false}
 $uri=$null
 try{$uri=[Uri]$line}catch{return $false}
 if(-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http','https')){return $false}
 # Never print the URI/query. For TORBOX require only local gateway target.
 if($label -eq 'TORBOX' -and -not(($uri.Host -in @('127.0.0.1','localhost')) -and $uri.Port -eq 8766)){return $false}
 try{
  Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
  $client=New-Object System.Net.Http.HttpClient
  $client.Timeout=[TimeSpan]::FromSeconds(15)
  $req=New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get,$uri)
  $req.Headers.Range=New-Object System.Net.Http.Headers.RangeHeaderValue(0,1023)
  $resp=$client.SendAsync($req,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
  $status=[int]$resp.StatusCode
  $stream=$resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
  $buf=New-Object byte[] 1024
  $n=$stream.Read($buf,0,$buf.Length)
  $stream.Dispose();$resp.Dispose();$client.Dispose()
  Write-Output ($label+'_RANGE|status='+$status+'|bytes_read='+$n+'|file='+[IO.Path]::GetFileName($path))
  return ($status -eq 206 -and $n -gt 0)
 }catch{Write-Output ($label+'_RANGE=FAIL|file='+[IO.Path]::GetFileName($path)+'|'+$_.Exception.Message);return $false}
}

$tbRange=$false
foreach($sp in $strmPaths){
 if($tbRange){break}
 $tbRange=Test-RangeCandidate -path ([string]$sp) -label 'TORBOX'
}
if(-not $tbRange){Write-Output 'TORBOX_RANGE=SKIP_OR_FAIL|no_usable_local_gateway_candidate'}

$rdRange=$false;$rdCandidate=$false
foreach($sp in $strmPaths){
 if($rdRange){break}
 if(([string]$sp) -match '(?i)real[- ]?debrid'){$rdCandidate=$true;$rdRange=Test-RangeCandidate -path ([string]$sp) -label 'REAL_DEBRID'}
}
if(-not $rdCandidate){Write-Output 'REAL_DEBRID_RANGE=SKIP|no_candidate'}elseif(-not $rdRange){Write-Output 'REAL_DEBRID_RANGE=FAIL_OR_UNUSABLE'}

$allExpected=($dbAudit -and (@($dbAudit.expected|ForEach-Object{[string]$_.Name}|Sort-Object -Unique).Count -eq $expected.Count))
$pass=($httpOk -and $pidStable -and (Test-Path -LiteralPath $db -PathType Leaf) -and $allExpected -and $gatewayOk)
Write-Output ('CORE_VERIFY_PASS='+$pass)
if($pass){Write-Output 'VERIFY_STATUS=PASS';exit 0}else{Write-Output 'VERIFY_STATUS=FAIL';exit 1}
