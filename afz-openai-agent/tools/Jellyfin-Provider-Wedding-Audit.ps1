#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
Write-Output 'AFZ_JELLYFIN_PROVIDER_WEDDING_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'

# Build a bounded set of candidate DBs/roots for Wedding discovery.
$dbCandidates=New-Object System.Collections.Generic.List[string]
foreach($p in @(
 'C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db',
 'C:\ProgramData\Jellyfin\Server\data\jellyfin.db',
 'C:\ProgramData\Jellyfin\data\jellyfin.db'
)) { if(Test-Path -LiteralPath $p -PathType Leaf){$dbCandidates.Add($p)} }
if(Test-Path 'C:\AFZ\MediaCatalog\Backups'){
 Get-ChildItem 'C:\AFZ\MediaCatalog\Backups' -Directory -Filter 'JellyfinControlledReload-*' -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 12 | ForEach-Object {
   $p=Join-Path $_.FullName 'jellyfin.db'; if(Test-Path -LiteralPath $p -PathType Leaf){$dbCandidates.Add($p)}
  }
}
$dbCandidates=@($dbCandidates|Select-Object -Unique)
Write-Output ('WEDDING_DB_CANDIDATES='+$dbCandidates.Count)

$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'AUDIT_STATUS=FAIL|reason=NO_PYTHON';exit 1}
$tmpPy=Join-Path $env:TEMP ('jf-provider-wedding-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import json,sqlite3,sys,os
mode=sys.argv[1]
if mode=='wedding':
 out=[]
 for p in sys.argv[2:]:
  try:
   c=sqlite3.connect('file:'+p.replace('\\','/')+'?mode=ro',uri=True,timeout=5);c.row_factory=sqlite3.Row
   tabs={r[0] for r in c.execute("select name from sqlite_master where type='table'")}
   if 'BaseItems' in tabs:
    cols=[r[1] for r in c.execute('pragma table_info(BaseItems)')];lc={x.lower():x for x in cols}
    if 'name' in lc:
     pick=[lc[x] for x in ('id','name','type','path','parentid') if x in lc]
     q='select '+','.join('"'+x+'"' for x in pick)+' from BaseItems where lower(cast("'+lc['name']+'" as text))=?'
     rows=[dict(r) for r in c.execute(q,('wedding',))]
     if rows: out.append({'db':p,'rows':rows})
   c.close()
  except Exception as e: out.append({'db':p,'error':type(e).__name__+':'+str(e)})
 print(json.dumps(out,separators=(',',':')))
elif mode=='strm':
 p=sys.argv[2];out={'torbox':[],'rd':[],'errors':[]}
 try:
  c=sqlite3.connect('file:'+p.replace('\\','/')+'?mode=ro',uri=True,timeout=5);c.row_factory=sqlite3.Row
  cols=[r[1] for r in c.execute('pragma table_info(BaseItems)')];lc={x.lower():x for x in cols}
  if 'path' in lc:
   pc=lc['path']
   q='select "'+pc+'" from BaseItems where lower(cast("'+pc+'" as text)) like ? limit 1000'
   paths=[r[0] for r in c.execute(q,('%.strm',)) if r[0]]
   for x in paths:
    lx=str(x).lower()
    if ('torbox' in lx or 'stream now' in lx or 'bollywood' in lx) and len(out['torbox'])<100: out['torbox'].append(x)
    if ('real-debrid' in lx or 'real debrid' in lx or 'realdebrid' in lx) and len(out['rd'])<100: out['rd'].append(x)
  c.close()
 except Exception as e: out['errors'].append(type(e).__name__+':'+str(e))
 print(json.dumps(out,separators=(',',':')))
'@
[IO.File]::WriteAllText($tmpPy,$code,(New-Object Text.UTF8Encoding($false)))
function Invoke-PyJson([string[]]$args){
 $exe=$py.Path
 if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){$s=(& $exe -3 $tmpPy @args 2>&1|Out-String)}else{$s=(& $exe $tmpPy @args 2>&1|Out-String)}
 if($LASTEXITCODE -ne 0){throw ('python audit failed: '+$s)}
 return ($s|ConvertFrom-Json)
}
try{
 $wa=Invoke-PyJson (@('wedding')+$dbCandidates)
 $wHits=0
 foreach($entry in @($wa)){
  if($entry.rows){
   foreach($r in @($entry.rows)){
    $wHits++
    $p=[string]$r.Path
    Write-Output ('WEDDING_HIT|db='+[IO.Path]::GetFileName((Split-Path ([string]$entry.db) -Parent))+'|type='+[string]$r.Type+'|path_exists='+(if($p){Test-Path -LiteralPath $p}else{$false})+'|path_leaf='+(if($p){[IO.Path]::GetFileName($p)}else{''}))
   }
  }
 }
 Write-Output ('WEDDING_DB_HIT_COUNT='+$wHits)

 $rootHits=@()
 foreach($root in @('C:\Users\Faiz\AppData\Local\Jellyfin\root\default','C:\ProgramData\Jellyfin\Server\root\default','C:\ProgramData\Jellyfin\root\default')){
  if(Test-Path -LiteralPath $root -PathType Container){
   $h=@(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue|Where-Object{$_.Name -ieq 'Wedding'})
   foreach($x in $h){$rootHits+=$x.FullName;Write-Output ('WEDDING_ROOT_HIT|root='+$root+'|exists=true')}
  }
 }
 Write-Output ('WEDDING_ROOT_HIT_COUNT='+$rootHits.Count)

 $sa=Invoke-PyJson @('strm',$db)
 $tb=@($sa.torbox);$rd=@($sa.rd)
 Write-Output ('TORBOX_STRM_CANDIDATES='+$tb.Count)
 Write-Output ('REAL_DEBRID_STRM_CANDIDATES='+$rd.Count)
 foreach($e in @($sa.errors)){Write-Output ('STRM_DB_ERROR='+[string]$e)}

 function Test-Range([string]$path,[string]$label){
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
  try{$line=(Get-Content -LiteralPath $path -TotalCount 3 -ErrorAction Stop|Where-Object{$_ -and $_.Trim()}|Select-Object -First 1).Trim()}catch{return $null}
  try{$uri=[Uri]$line}catch{return $null}
  if(-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http','https')){return $null}
  if($label -eq 'TORBOX'){
   if($uri.Port -ne 8766){return $null}
   $h=$uri.Host.ToLowerInvariant()
   $private=($h -in @('localhost','127.0.0.1','192.168.50.94') -or $h -match '^10\.' -or $h -match '^192\.168\.' -or $h -match '^100\.' -or $h -match '^172\.(1[6-9]|2[0-9]|3[01])\.')
   if(-not $private){return $null}
  }
  try{
   Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
   $client=New-Object System.Net.Http.HttpClient;$client.Timeout=[TimeSpan]::FromSeconds(20)
   $req=New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get,$uri)
   $req.Headers.Range=New-Object System.Net.Http.Headers.RangeHeaderValue(0,1048575)
   $resp=$client.SendAsync($req,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
   $status=[int]$resp.StatusCode;$stream=$resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult();$buf=New-Object byte[] 1048576;$total=0
   while($total -lt $buf.Length){$n=$stream.Read($buf,$total,$buf.Length-$total);if($n -le 0){break};$total+=$n}
   $stream.Dispose();$resp.Dispose();$client.Dispose()
   Write-Output ($label+'_RANGE|status='+$status+'|bytes_read='+$total+'|file='+[IO.Path]::GetFileName($path)+'|uri_host='+$uri.Host+'|uri_port='+$uri.Port)
   return [pscustomobject]@{Ok=($status -eq 206 -and $total -gt 0);Status=$status;Bytes=$total}
  }catch{Write-Output ($label+'_RANGE=FAIL|file='+[IO.Path]::GetFileName($path)+'|'+$_.Exception.Message);return [pscustomobject]@{Ok=$false;Status=0;Bytes=0}}
 }
 $tbPass=$false
 foreach($p in $tb){$r=Test-Range ([string]$p) 'TORBOX';if($r -and $r.Ok){$tbPass=$true;break}}
 Write-Output ('TORBOX_RANGE_PASS='+$tbPass)
 $rdPass=$false;$rdTried=$false
 foreach($p in $rd){$r=Test-Range ([string]$p) 'REAL_DEBRID';if($r){$rdTried=$true;if($r.Ok){$rdPass=$true;break}}}
 if(-not $rdTried){Write-Output 'REAL_DEBRID_RANGE=SKIP|no_usable_candidate'}else{Write-Output ('REAL_DEBRID_RANGE_PASS='+$rdPass)}
 Write-Output 'AUDIT_STATUS=PASS'
} finally {Remove-Item -LiteralPath $tmpPy -Force -ErrorAction SilentlyContinue}
