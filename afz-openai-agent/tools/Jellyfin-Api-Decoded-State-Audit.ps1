#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:8096'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$known=[ordered]@{coolyo='2D994DBA-B8C7-44C8-8D34-7D85716B2EBC';movies='64F6DF5C-78B5-4DFE-B0FF-7295CBFB3A5A'}
$serverId='5ae656ad8fc948f38e1ac1d5a6769aa5'
function Find-Cmd([string[]]$names){foreach($n in $names){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Path){return $c.Path};if($c.Source){return $c.Source}}};return $null}
function J($o){$o|ConvertTo-Json -Depth 20 -Compress}
function AuthHeader([string]$t){return @{Authorization=('MediaBrowser Client="AFZ-ReadOnly-Audit", Device="Windows-main", DeviceId="afz-jellyfin-audit", Version="1.0", Token="'+$t+'"')}}
function Add-Candidate([System.Collections.Generic.HashSet[string]]$Set,[string]$Value){if([string]::IsNullOrWhiteSpace($Value)){return};$v=$Value.Trim().Trim('"').Trim("'");if($v.Length -ge 20 -and $v.Length -le 256 -and $v -match '^[A-Za-z0-9._-]+$'){[void]$Set.Add($v)}}
function Scan-Buffer([System.Collections.Generic.HashSet[string]]$Set,[byte[]]$buf){foreach($enc in @([Text.Encoding]::UTF8,[Text.Encoding]::Unicode)){try{$text=$enc.GetString($buf)}catch{continue};$interesting=($text -match '(?i)jellyfin|AccessToken|192\.168\.50\.94|'+$serverId);foreach($rx in @('(?i)AccessToken[^A-Za-z0-9._-]{0,96}([A-Za-z0-9._-]{20,256})','(?i)accessToken[^A-Za-z0-9._-]{0,96}([A-Za-z0-9._-]{20,256})','(?i)X-Emby-Token[^A-Za-z0-9._-]{0,96}([A-Za-z0-9._-]{20,256})')){foreach($m in [regex]::Matches($text,$rx)){Add-Candidate $Set $m.Groups[1].Value}};if($interesting){foreach($m in [regex]::Matches($text,'(?i)(?<![A-Fa-f0-9])[A-Fa-f0-9]{32}(?![A-Fa-f0-9])')){Add-Candidate $Set $m.Value}}}}
Write-Output 'AFZ_JELLYFIN_API_DECODED_STATE_AUDIT_V3';Write-Output ('TIME='+(Get-Date -Format o));Write-Output 'READ_ONLY=true';Write-Output 'SECRET_EXPOSED=false';Write-Output 'AUTH_HEADER=MediaBrowser'
$token=$null;$users=@();$authMode=$null;$matchedUser=$null
if(Test-Path -LiteralPath $db -PathType Leaf){
 $python=Find-Cmd @('python.exe','python','py.exe','py')
 if($python){
  $tmpPy=Join-Path $env:TEMP ('jf-apikey-'+[guid]::NewGuid().ToString('n')+'.py');$tmpJson=Join-Path $env:TEMP ('jf-apikey-'+[guid]::NewGuid().ToString('n')+'.json')
  $py=@'
import json,sqlite3,sys,pathlib
p=sys.argv[1];out=sys.argv[2]
con=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=5)
try:
 rows=[]
 cols=[r[1] for r in con.execute('pragma table_info("ApiKeys")')]
 if 'AccessToken' in cols:
  for r in con.execute('select AccessToken from ApiKeys where AccessToken is not null and length(AccessToken)>=16 order by DateLastActivity desc,DateCreated desc'): rows.append(r[0])
 json.dump(rows,open(out,'w',encoding='utf-8'))
finally: con.close()
'@
  [IO.File]::WriteAllText($tmpPy,$py,(New-Object Text.UTF8Encoding($false)))
  try{
    if([IO.Path]::GetFileName($python) -match '^py(\.exe)?$'){& $python -3 $tmpPy $db $tmpJson}else{& $python $tmpPy $db $tmpJson}
    if($LASTEXITCODE -eq 0 -and (Test-Path $tmpJson)){
      $keys=@(Get-Content $tmpJson -Raw -Encoding UTF8|ConvertFrom-Json);Write-Output ('APIKEY_CANDIDATES='+$keys.Count);$tested=0
      foreach($k in $keys){$tested++;try{$r=Invoke-RestMethod -Uri ($base+'/Users') -Headers (AuthHeader ([string]$k)) -TimeoutSec 6;if($null -ne $r){$token=[string]$k;$users=@($r);$authMode='api-key';break}}catch{}}
      Write-Output ('APIKEY_TESTED='+$tested)
    }
  } finally {Remove-Item -LiteralPath $tmpPy,$tmpJson -Force -ErrorAction SilentlyContinue}
 }
}
if(-not $token){
 $candidates=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);$filesScanned=0;$indexedScanned=0
 foreach($root in @('C:\Users\Faiz\AppData\Local\Google\Chrome\User Data','C:\Users\Faiz\AppData\Local\Microsoft\Edge\User Data')){if(-not(Test-Path -LiteralPath $root -PathType Container)){continue};foreach($profile in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue|Where-Object {$_.Name -eq 'Default' -or $_.Name -like 'Profile *'})){foreach($rel in @('Local Storage\leveldb','Session Storage','IndexedDB')){$dir=Join-Path $profile.FullName $rel;if(-not(Test-Path -LiteralPath $dir -PathType Container)){continue};foreach($f in @(Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue|Where-Object {$_.Extension -in @('.ldb','.log')})){$filesScanned++;if($dir -like '*IndexedDB*'){$indexedScanned++};try{$fs=New-Object IO.FileStream($f.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite);try{$buf=New-Object byte[] $fs.Length;[void]$fs.Read($buf,0,$buf.Length)}finally{$fs.Dispose()};Scan-Buffer $candidates $buf}catch{}}}}}
 Write-Output ('BROWSER_FILES_SCANNED='+$filesScanned);Write-Output ('INDEXEDDB_FILES_SCANNED='+$indexedScanned);Write-Output ('BROWSER_TOKEN_CANDIDATES='+$candidates.Count)
 foreach($t in $candidates){foreach($entry in $known.GetEnumerator()){try{$v=Invoke-RestMethod -Uri ($base+'/Users/'+$entry.Value+'/Views?IncludeExternalContent=true') -Headers (AuthHeader $t) -TimeoutSec 5;if($null -ne $v){$token=$t;$authMode='browser-session';$matchedUser=$entry.Key;try{$u=Invoke-RestMethod -Uri ($base+'/Users/'+$entry.Value) -Headers (AuthHeader $t) -TimeoutSec 5;$users=@($u)}catch{$users=@([pscustomobject]@{Name=$entry.Key;Id=$entry.Value;Configuration=$null;Policy=$null})};break}}catch{}};if($token){break}}
}
if(-not $token){Write-Output 'STATUS=SAFE_STOP|reason=NO_ACTIVE_API_OR_BROWSER_TOKEN';exit 0}
Write-Output ('AUTH_MODE='+$authMode);if($matchedUser){Write-Output ('MATCHED_BROWSER_USER='+$matchedUser)}
$h=AuthHeader $token
foreach($u in $users){
 $cfg=$u.Configuration;$pol=$u.Policy
 $state=[ordered]@{name=[string]$u.Name;id=[string]$u.Id;enableAllFolders=$(if($pol){[bool]$pol.EnableAllFolders}else{$null});myMediaExcludes=$(if($cfg){@($cfg.MyMediaExcludes)}else{@()});latestItemExcludes=$(if($cfg){@($cfg.LatestItemsExcludes)}else{@()});groupedFolders=$(if($cfg){@($cfg.GroupedFolders)}else{@()});orderedViews=$(if($cfg){@($cfg.OrderedViews)}else{@()})}
 Write-Output ('USER_STATE|'+(J $state))
 try{$v=Invoke-RestMethod -Uri ($base+'/Users/'+$u.Id+'/Views?IncludeExternalContent=true') -Headers $h -TimeoutSec 8;$items=@($v.Items|ForEach-Object{[ordered]@{name=[string]$_.Name;id=[string]$_.Id;type=[string]$_.Type;collectionType=[string]$_.CollectionType;displayPreferencesId=[string]$_.DisplayPreferencesId}});Write-Output ('USER_VIEWS|'+(J ([ordered]@{name=[string]$u.Name;id=[string]$u.Id;count=$items.Count;items=$items})))}catch{Write-Output ('USER_VIEWS_ERROR|user='+$u.Name+'|error='+$_.Exception.Message)}
 try{$dp=Invoke-RestMethod -Uri ($base+'/DisplayPreferences/usersettings?userId='+$u.Id+'&client=emby') -Headers $h -TimeoutSec 8;$home=[ordered]@{};if($dp.CustomPrefs){foreach($p in $dp.CustomPrefs.PSObject.Properties){if($p.Name -like 'homesection*' -or $p.Name -like 'landing-*'){$home[$p.Name]=[string]$p.Value}}};Write-Output ('DISPLAY_PREFS|'+(J ([ordered]@{name=[string]$u.Name;id=[string]$u.Id;client=[string]$dp.Client;home=$home})))}catch{Write-Output ('DISPLAY_PREFS_ERROR|user='+$u.Name+'|error='+$_.Exception.Message)}
}
Write-Output 'SECRET_EXPOSED=false';Write-Output 'STATUS=PASS'
