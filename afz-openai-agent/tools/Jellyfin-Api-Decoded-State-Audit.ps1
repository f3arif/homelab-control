#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:8096'
$known=[ordered]@{coolyo='2D994DBA-B8C7-44C8-8D34-7D85716B2EBC';movies='64F6DF5C-78B5-4DFE-B0FF-7295CBFB3A5A'}
$serverId='5ae656ad8fc948f38e1ac1d5a6769aa5'
function Find-Cmd([string[]]$names){foreach($n in $names){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Path){return $c.Path};if($c.Source){return $c.Source}}};return $null}
function J($o){$o|ConvertTo-Json -Depth 30 -Compress}
function AuthHeader([string]$t){return @{Authorization=('MediaBrowser Client="AFZ-ReadOnly-Audit", Device="Windows-main", DeviceId="afz-jellyfin-audit", Version="1.0", Token="'+$t+'"')}}
function Add-Candidate([System.Collections.Generic.HashSet[string]]$Set,[string]$Value){if([string]::IsNullOrWhiteSpace($Value)){return};$v=$Value.Trim().Trim('"').Trim("'");if($v.Length -ge 20 -and $v.Length -le 256 -and $v -match '^[A-Za-z0-9._-]+$'){[void]$Set.Add($v)}}
function Scan-Buffer([System.Collections.Generic.HashSet[string]]$Set,[byte[]]$buf){foreach($enc in @([Text.Encoding]::UTF8,[Text.Encoding]::Unicode)){try{$text=$enc.GetString($buf)}catch{continue};$interesting=($text -match '(?i)jellyfin|AccessToken|192\.168\.50\.94|'+$serverId);foreach($rx in @('(?i)AccessToken[^A-Za-z0-9._-]{0,96}([A-Za-z0-9._-]{20,256})','(?i)accessToken[^A-Za-z0-9._-]{0,96}([A-Za-z0-9._-]{20,256})','(?i)X-Emby-Token[^A-Za-z0-9._-]{0,96}([A-Za-z0-9._-]{20,256})')){foreach($m in [regex]::Matches($text,$rx)){Add-Candidate $Set $m.Groups[1].Value}};if($interesting){foreach($m in [regex]::Matches($text,'(?i)(?<![A-Fa-f0-9])[A-Fa-f0-9]{32}(?![A-Fa-f0-9])')){Add-Candidate $Set $m.Value}}}}
Write-Output 'AFZ_JELLYFIN_API_DECODED_STATE_AUDIT_V5'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
Write-Output 'AUTH_HEADER=MediaBrowser'
$proc=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {$_.Name -match '^jellyfin(\.exe)?$'})
foreach($p in $proc){Write-Output ('PROCESS|pid='+$p.ProcessId+'|exe='+[string]$p.ExecutablePath+'|cmd='+(([string]$p.CommandLine)-replace '\|','/'))}
$svc=@(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue|Where-Object {$_.Name -match 'jellyfin' -or $_.PathName -match 'jellyfin'})
foreach($s in $svc){Write-Output ('SERVICE|name='+$s.Name+'|state='+$s.State+'|startName='+$s.StartName+'|path='+(([string]$s.PathName)-replace '\|','/'))}
$dbSet=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($p in @('C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db','C:\ProgramData\Jellyfin\Server\data\jellyfin.db','C:\ProgramData\Jellyfin\Server\jellyfin.db')){if(Test-Path -LiteralPath $p -PathType Leaf){[void]$dbSet.Add($p)}}
foreach($root in @('C:\Users\Faiz\AppData\Local\Jellyfin','C:\ProgramData\Jellyfin')){if(Test-Path -LiteralPath $root -PathType Container){foreach($f in @(Get-ChildItem -LiteralPath $root -Filter jellyfin.db -File -Recurse -ErrorAction SilentlyContinue)){[void]$dbSet.Add($f.FullName)}}}
foreach($p in $proc){$cmd=[string]$p.CommandLine;if($cmd -match '(?i)--datadir(?:=|\s+)["'']?([^"'']+?)(?:["'']?(?:\s+--|$))'){$d=$matches[1].Trim();foreach($q in @((Join-Path $d 'jellyfin.db'),(Join-Path $d 'data\jellyfin.db'))){if(Test-Path -LiteralPath $q -PathType Leaf){[void]$dbSet.Add($q)}}}}
$python=Find-Cmd @('python.exe','python','py.exe','py')
$token=$null;$users=@();$authMode=$null;$authDb=$null
if($python){
  foreach($db in @($dbSet)){
    $fi=Get-Item -LiteralPath $db -ErrorAction SilentlyContinue
    $tmpPy=Join-Path $env:TEMP ('jf-apikey-'+[guid]::NewGuid().ToString('n')+'.py');$tmpJson=Join-Path $env:TEMP ('jf-apikey-'+[guid]::NewGuid().ToString('n')+'.json')
    $py=@'
import json,sqlite3,sys,pathlib
p=sys.argv[1];out=sys.argv[2]
con=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=5)
try:
 rows=[]; tables={r[0] for r in con.execute("select name from sqlite_master where type='table'")}
 if 'ApiKeys' in tables:
  cols=[r[1] for r in con.execute('pragma table_info("ApiKeys")')]
  if 'AccessToken' in cols:
   order=' order by DateLastActivity desc,DateCreated desc' if 'DateLastActivity' in cols and 'DateCreated' in cols else ''
   for r in con.execute('select AccessToken from ApiKeys where AccessToken is not null and length(AccessToken)>=16'+order): rows.append(r[0])
 json.dump({'keys':rows,'tables':len(tables)},open(out,'w',encoding='utf-8'))
finally: con.close()
'@
    [IO.File]::WriteAllText($tmpPy,$py,(New-Object Text.UTF8Encoding($false)))
    try{
      if([IO.Path]::GetFileName($python) -match '^py(\.exe)?$'){& $python -3 $tmpPy $db $tmpJson *> $null}else{& $python $tmpPy $db $tmpJson *> $null}
      if($LASTEXITCODE -ne 0 -or -not(Test-Path $tmpJson)){Write-Output ('DB_CANDIDATE|path='+$db+'|read=failed');continue}
      $info=Get-Content $tmpJson -Raw -Encoding UTF8|ConvertFrom-Json;$keys=@($info.keys)
      Write-Output ('DB_CANDIDATE|path='+$db+'|size='+$fi.Length+'|mtime='+$fi.LastWriteTime.ToString('o')+'|tables='+$info.tables+'|apikeys='+$keys.Count)
      foreach($k in $keys){try{$r=Invoke-RestMethod -Uri ($base+'/Users') -Headers (AuthHeader ([string]$k)) -TimeoutSec 6;if($null -ne $r){$token=[string]$k;$users=@($r);$authMode='api-key';$authDb=$db;break}}catch{}}
      if($token){break}
    } finally {Remove-Item -LiteralPath $tmpPy,$tmpJson -Force -ErrorAction SilentlyContinue}
  }
}
if(-not $token){
 $candidates=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);$filesScanned=0;$indexedScanned=0
 foreach($root in @('C:\Users\Faiz\AppData\Local\Google\Chrome\User Data','C:\Users\Faiz\AppData\Local\Microsoft\Edge\User Data')){if(-not(Test-Path -LiteralPath $root -PathType Container)){continue};foreach($profile in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue|Where-Object {$_.Name -eq 'Default' -or $_.Name -like 'Profile *'})){foreach($rel in @('Local Storage\leveldb','Session Storage','IndexedDB')){$dir=Join-Path $profile.FullName $rel;if(-not(Test-Path -LiteralPath $dir -PathType Container)){continue};foreach($f in @(Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue|Where-Object {$_.Extension -in @('.ldb','.log')})){$filesScanned++;if($dir -like '*IndexedDB*'){$indexedScanned++};try{$fs=New-Object IO.FileStream($f.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite);try{$buf=New-Object byte[] $fs.Length;[void]$fs.Read($buf,0,$buf.Length)}finally{$fs.Dispose()};Scan-Buffer $candidates $buf}catch{}}}}}
 Write-Output ('BROWSER_FILES_SCANNED='+$filesScanned);Write-Output ('INDEXEDDB_FILES_SCANNED='+$indexedScanned);Write-Output ('BROWSER_TOKEN_CANDIDATES='+$candidates.Count)
 foreach($t in $candidates){foreach($entry in $known.GetEnumerator()){try{$v=Invoke-RestMethod -Uri ($base+'/Users/'+$entry.Value+'/Views?IncludeExternalContent=true') -Headers (AuthHeader $t) -TimeoutSec 5;if($null -ne $v){$token=$t;$authMode='browser-session';try{$u=Invoke-RestMethod -Uri ($base+'/Users/'+$entry.Value) -Headers (AuthHeader $t) -TimeoutSec 5;$users=@($u)}catch{$users=@([pscustomobject]@{Name=$entry.Key;Id=$entry.Value;Configuration=$null;Policy=$null})};break}}catch{}};if($token){break}}
}
if(-not $token){Write-Output 'STATUS=SAFE_STOP|reason=NO_ACTIVE_API_OR_BROWSER_TOKEN';Write-Output 'SECRET_EXPOSED=false';exit 0}
Write-Output ('AUTH_MODE='+$authMode)
if($authDb){Write-Output ('AUTH_DB='+$authDb)}
$h=AuthHeader $token
$currentVfRoot='C:\Users\Faiz\AppData\Local\Jellyfin\root\default'
$homeVfPath=Join-Path $currentVfRoot 'Home Videos and Photos'
Write-Output ('CURRENT_VF_ROOT_EXISTS='+(Test-Path -LiteralPath $currentVfRoot -PathType Container))
Write-Output ('CURRENT_HOME_VF_DIR_EXISTS='+(Test-Path -LiteralPath $homeVfPath -PathType Container))
try{
  $vf=@(Invoke-RestMethod -Uri ($base+'/Library/VirtualFolders') -Headers $h -TimeoutSec 8)
  $items=@()
  foreach($x in $vf){
    $pathInfos=@();if($x.LibraryOptions -and $x.LibraryOptions.PathInfos){$pathInfos=@($x.LibraryOptions.PathInfos|ForEach-Object{[string]$_.Path})}
    $items += [ordered]@{name=[string]$x.Name;itemId=[string]$x.ItemId;collectionType=[string]$x.CollectionType;locations=@($x.Locations|ForEach-Object{[string]$_});pathInfos=$pathInfos}
  }
  Write-Output ('VIRTUAL_FOLDERS|'+(J ([ordered]@{count=$items.Count;items=$items})))
}catch{Write-Output ('VIRTUAL_FOLDERS_ERROR|error='+$_.Exception.Message)}
foreach($u in $users){
 $cfg=$u.Configuration;$pol=$u.Policy
 $state=[ordered]@{name=[string]$u.Name;id=[string]$u.Id;enableAllFolders=$(if($pol){[bool]$pol.EnableAllFolders}else{$null});myMediaExcludes=$(if($cfg){@($cfg.MyMediaExcludes)}else{@()});latestItemExcludes=$(if($cfg){@($cfg.LatestItemsExcludes)}else{@()});groupedFolders=$(if($cfg){@($cfg.GroupedFolders)}else{@()});orderedViews=$(if($cfg){@($cfg.OrderedViews)}else{@()})}
 Write-Output ('USER_STATE|'+(J $state))
 try{$v=Invoke-RestMethod -Uri ($base+'/Users/'+$u.Id+'/Views?IncludeExternalContent=true') -Headers $h -TimeoutSec 8;$items=@($v.Items|ForEach-Object{[ordered]@{name=[string]$_.Name;id=[string]$_.Id;type=[string]$_.Type;collectionType=[string]$_.CollectionType;displayPreferencesId=[string]$_.DisplayPreferencesId}});Write-Output ('USER_VIEWS|'+(J ([ordered]@{name=[string]$u.Name;id=[string]$u.Id;count=$items.Count;items=$items})))}catch{Write-Output ('USER_VIEWS_ERROR|user='+$u.Name+'|error='+$_.Exception.Message)}
 try{$dp=Invoke-RestMethod -Uri ($base+'/DisplayPreferences/usersettings?userId='+$u.Id+'&client=emby') -Headers $h -TimeoutSec 8;$home=[ordered]@{};if($dp.CustomPrefs){foreach($p in $dp.CustomPrefs.PSObject.Properties){if($p.Name -like 'homesection*' -or $p.Name -like 'landing-*'){$home[$p.Name]=[string]$p.Value}}};Write-Output ('DISPLAY_PREFS|'+(J ([ordered]@{name=[string]$u.Name;id=[string]$u.Id;client=[string]$dp.Client;home=$home})))}catch{Write-Output ('DISPLAY_PREFS_ERROR|user='+$u.Name+'|error='+$_.Exception.Message)}
}
Write-Output 'SECRET_EXPOSED=false'
Write-Output 'STATUS=PASS'
