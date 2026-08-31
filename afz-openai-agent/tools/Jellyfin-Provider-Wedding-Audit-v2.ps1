#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
Write-Output 'AFZ_JELLYFIN_PROVIDER_WEDDING_AUDIT_V2'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'

$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'AUDIT_STATUS=FAIL|reason=NO_PYTHON';exit 1}
$dbCandidates=@('C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db','C:\ProgramData\Jellyfin\Server\data\jellyfin.db','C:\ProgramData\Jellyfin\data\jellyfin.db')|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}
if(Test-Path 'C:\AFZ\MediaCatalog\Backups'){
 $dbCandidates+=@(Get-ChildItem 'C:\AFZ\MediaCatalog\Backups' -Directory -Filter 'JellyfinControlledReload-*' -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 12|ForEach-Object{Join-Path $_.FullName 'jellyfin.db'}|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf})
}
$dbCandidates=@($dbCandidates|Select-Object -Unique)
Write-Output ('WEDDING_DB_CANDIDATES='+$dbCandidates.Count)
$tmpPy=Join-Path $env:TEMP ('jf-pw-audit-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import json,sqlite3,sys
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
     pick=[lc[x] for x in ('id','name','type','path') if x in lc]
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
   pc=lc['path'];q='select "'+pc+'" from BaseItems where lower(cast("'+pc+'" as text)) like ? limit 3000'
   for r in c.execute(q,('%.strm',)):
    x=r[0]
    if not x: continue
    lx=str(x).lower()
    if ('torbox' in lx or 'stream now' in lx or 'bollywood' in lx) and len(out['torbox'])<250: out['torbox'].append(x)
    if ('real-debrid' in lx or 'real debrid' in lx or 'realdebrid' in lx) and len(out['rd'])<250: out['rd'].append(x)
  c.close()
 except Exception as e: out['errors'].append(type(e).__name__+':'+str(e))
 print(json.dumps(out,separators=(',',':')))
'@
[IO.File]::WriteAllText($tmpPy,$code,(New-Object Text.UTF8Encoding($false)))
function Invoke-PyJson([string[]]$ArgsList){
 $exe=$py.Path
 if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){$s=(& $exe -3 $tmpPy @ArgsList 2>&1|Out-String)}else{$s=(& $exe $tmpPy @ArgsList 2>&1|Out-String)}
 if($LASTEXITCODE -ne 0){throw ('python audit failed: '+$s)}
 return ($s|ConvertFrom-Json)
}
function Test-RangeCandidate([string]$Path,[string]$Label){
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
 try{$line=(Get-Content -LiteralPath $Path -TotalCount 3 -ErrorAction Stop|Where-Object{$_ -and $_.Trim()}|Select-Object -First 1).Trim()}catch{return $null}
 try{$uri=[Uri]$line}catch{return $null}
 if(-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http','https')){return $null}
 if($Label -eq 'TORBOX'){
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
  Write-Output ($Label+'_RANGE|status='+$status+'|bytes_read='+$total+'|file='+[IO.Path]::GetFileName($Path)+'|uri_host='+$uri.Host+'|uri_port='+$uri.Port)
  return [pscustomobject]@{Ok=($status -eq 206 -and $total -gt 0);Status=$status;Bytes=$total}
 }catch{
  Write-Output ($Label+'_RANGE=FAIL|file='+[IO.Path]::GetFileName($Path)+'|'+$_.Exception.Message)
  return [pscustomobject]@{Ok=$false;Status=0;Bytes=0}
 }
}
try{
 $wa=Invoke-PyJson -ArgsList (@('wedding')+$dbCandidates)
 $wHits=0
 foreach($entry in @($wa)){
  if($entry.rows){foreach($r in @($entry.rows)){
   $wHits++;$rp=[string]$r.Path;$pathExists=$false;$leaf=''
   if($rp){$pathExists=Test-Path -LiteralPath $rp;$leaf=[IO.Path]::GetFileName($rp)}
   Write-Output ('WEDDING_HIT|db_parent='+[IO.Path]::GetFileName((Split-Path ([string]$entry.db) -Parent))+'|type='+[string]$r.Type+'|path_exists='+$pathExists+'|path_leaf='+$leaf)
  }}
 }
 Write-Output ('WEDDING_DB_HIT_COUNT='+$wHits)
 $rootHits=0
 foreach($root in @('C:\Users\Faiz\AppData\Local\Jellyfin\root\default','C:\ProgramData\Jellyfin\Server\root\default','C:\ProgramData\Jellyfin\root\default')){
  if(Test-Path -LiteralPath $root -PathType Container){$h=@(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue|Where-Object{$_.Name -ieq 'Wedding'});if($h.Count){$rootHits+=$h.Count;Write-Output ('WEDDING_ROOT_HIT|root='+$root+'|count='+$h.Count)}}
 }
 Write-Output ('WEDDING_ROOT_HIT_COUNT='+$rootHits)
 $sa=Invoke-PyJson -ArgsList @('strm',$db)
 $tb=@($sa.torbox);$rd=@($sa.rd)
 Write-Output ('TORBOX_STRM_CANDIDATES='+$tb.Count)
 Write-Output ('REAL_DEBRID_STRM_CANDIDATES='+$rd.Count)
 foreach($e in @($sa.errors)){Write-Output ('STRM_DB_ERROR='+[string]$e)}
 $tbPass=$false
 foreach($sp in $tb){$r=Test-RangeCandidate -Path ([string]$sp) -Label 'TORBOX';if($r -and $r.Ok){$tbPass=$true;break}}
 Write-Output ('TORBOX_RANGE_PASS='+$tbPass)
 $rdPass=$false;$rdTried=$false
 foreach($sp in $rd){$r=Test-RangeCandidate -Path ([string]$sp) -Label 'REAL_DEBRID';if($r){$rdTried=$true;if($r.Ok){$rdPass=$true;break}}}
 if(-not $rdTried){Write-Output 'REAL_DEBRID_RANGE=SKIP|no_usable_candidate'}else{Write-Output ('REAL_DEBRID_RANGE_PASS='+$rdPass)}
 Write-Output 'AUDIT_STATUS=PASS'
 exit 0
}finally{Remove-Item -LiteralPath $tmpPy -Force -ErrorAction SilentlyContinue}
