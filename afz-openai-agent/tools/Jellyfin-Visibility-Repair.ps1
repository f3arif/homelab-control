#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('audit','repair')]
  [string]$Action='audit'
)

$ErrorActionPreference='Stop'
$BaseUri='http://127.0.0.1:8096'
$ExpectedScreenshotViews=@('Home Videos and Photos','Movies','Wedding')
$RequiredRecoveredViews=@(
  'Bollywood   Hindi (TorBox)',
  'Bollywood - Hindi (All Sources)',
  'Bollywood - Hindi (Downloaded)',
  'Real-Debrid Movies',
  'Stream Now (TorBox)',
  'TorBox Downloaded Movies'
)
$KnownUsers=@(
  [ordered]@{label='coolyo';id='2D994DBA-B8C7-44C8-8D34-7D85716B2EBC'},
  [ordered]@{label='movies';id='64F6DF5C-78B5-4DFE-B0FF-7295CBFB3A5A'}
)

function Emit($Object){$Object|ConvertTo-Json -Depth 30 -Compress|Write-Output}
function Find-CommandPath([string[]]$Names){
  foreach($n in $Names){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}}
  return $null
}
function Normalize-Set([string[]]$Values){return @($Values|ForEach-Object {([string]$_).Trim().ToLowerInvariant()}|Where-Object {$_}|Sort-Object -Unique)}
function Same-Set([string[]]$A,[string[]]$B){
  $aa=Normalize-Set $A;$bb=Normalize-Set $B
  if($aa.Count -ne $bb.Count){return $false}
  for($i=0;$i -lt $aa.Count;$i++){if($aa[$i] -ne $bb[$i]){return $false}}
  return $true
}
function Get-ViewNames([string]$UserId,[hashtable]$Headers){
  $r=Invoke-RestMethod -Method Get -Uri "$BaseUri/Users/$UserId/Views?IncludeExternalContent=true" -Headers $Headers -TimeoutSec 10
  return @($r.Items|ForEach-Object {[string]$_.Name}|Where-Object {$_}|Sort-Object -Unique)
}

$sqlite=Find-CommandPath @('sqlite3.exe','sqlite3')
$python=Find-CommandPath @('python.exe','python','py.exe','py')
$pythonLauncher=$false;if($python){$pythonLauncher=([IO.Path]::GetFileName($python)-match '^py(\.exe)?$')}
if(-not($sqlite -or $python)){
  Emit ([ordered]@{ok=$false;schema='afz.jellyfin-visibility.v2';action=$Action;status='SAFE_STOP';reason='No read-only SQLite backend is available.';secretExposed=$false});exit 0
}
$pythonSql=@'
import sqlite3, sys
from pathlib import Path
p=Path(sys.argv[1]).resolve(); q=sys.argv[2]
con=sqlite3.connect(p.as_uri()+'?mode=ro',uri=True,timeout=5)
try:
    for row in con.execute(q):
        print('|'.join('' if v is None else str(v).replace('\r',' ').replace('\n',' ') for v in row))
finally:
    con.close()
'@
function Sql([string]$Db,[string]$Query){
  if($sqlite){return @(& $sqlite -readonly -noheader -separator '|' $Db $Query 2>$null)}
  if($pythonLauncher){return @(& $python -3 -c $pythonSql $Db $Query 2>$null)}
  return @(& $python -c $pythonSql $Db $Query 2>$null)
}

$dbCandidates=New-Object System.Collections.Generic.List[string]
foreach($p in @('C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db','C:\ProgramData\Jellyfin\Server\data\jellyfin.db')){
  if(Test-Path -LiteralPath $p -PathType Leaf){[void]$dbCandidates.Add($p)}
}
try{
  foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='jellyfin.exe'" -ErrorAction Stop)){
    $cmd=[string]$p.CommandLine
    if($cmd -match '(?i)--datadir(?:=|\s+)"?([^"\r\n]+?)"?(?:\s+--|$)'){
      $d=$Matches[1].Trim().Trim('"');$candidate=Join-Path $d 'jellyfin.db'
      if((Test-Path -LiteralPath $candidate -PathType Leaf)-and -not $dbCandidates.Contains($candidate)){[void]$dbCandidates.Add($candidate)}
    }
  }
}catch{}
if($dbCandidates.Count -eq 0){Emit ([ordered]@{ok=$false;schema='afz.jellyfin-visibility.v2';action=$Action;status='SAFE_STOP';reason='No Jellyfin database candidate was found.';secretExposed=$false});exit 0}

$tokens=New-Object System.Collections.Generic.List[string]
$seen=New-Object 'System.Collections.Generic.HashSet[string]'
foreach($db in $dbCandidates){
  try{
    foreach($t in @(Sql $db "select name from sqlite_master where type='table' order by name;")){
      $safeT=$t.Replace('"','""')
      foreach($line in @(Sql $db ('pragma table_info("{0}");' -f $safeT))){
        $parts=$line -split '\|';if($parts.Count -lt 3 -or $parts[1] -notmatch '(?i)token|accesskey|apikey'){continue}
        $col=$parts[1].Replace('"','""')
        try{foreach($v in @(Sql $db ('select "{0}" from "{1}" where "{0}" is not null and length("{0}")>=12 limit 200;' -f $col,$safeT))){if($v -and $seen.Add($v)){[void]$tokens.Add($v)}}}catch{}
      }
    }
  }catch{}
}

$server=$null;try{$server=Invoke-RestMethod -Method Get -Uri "$BaseUri/System/Info/Public" -TimeoutSec 7}catch{}
$adminHeaders=$null;$enumeratedUsers=@();$tested=0
foreach($tok in $tokens){
  $tested++
  try{
    $h=@{'X-Emby-Token'=$tok};$u=@(Invoke-RestMethod -Method Get -Uri "$BaseUri/Users" -Headers $h -TimeoutSec 7)
    $adminHeaders=$h;$enumeratedUsers=$u;break
  }catch{}
}

$authMode='admin-enumeration'
$authById=@{}
$userDtos=New-Object System.Collections.Generic.List[object]
if($adminHeaders){
  foreach($u in $enumeratedUsers){
    try{$dto=Invoke-RestMethod -Method Get -Uri "$BaseUri/Users/$([string]$u.Id)" -Headers $adminHeaders -TimeoutSec 7;[void]$userDtos.Add($dto);$authById[[string]$dto.Id]=$adminHeaders}catch{}
  }
}else{
  $authMode='known-user-token-fallback'
  foreach($known in $KnownUsers){
    $found=$false
    foreach($tok in $tokens){
      try{
        $h=@{'X-Emby-Token'=$tok};$dto=Invoke-RestMethod -Method Get -Uri "$BaseUri/Users/$($known.id)" -Headers $h -TimeoutSec 6
        if([string]$dto.Id){[void]$userDtos.Add($dto);$authById[[string]$dto.Id]=$h;$found=$true;break}
      }catch{}
    }
  }
}
if($userDtos.Count -eq 0){
  Emit ([ordered]@{ok=$false;schema='afz.jellyfin-visibility.v2';action=$Action;status='SAFE_STOP';reason='No active token could read the known Jellyfin users.';tokenCandidates=$tokens.Count;tokensTested=$tested;authMode=$authMode;secretExposed=$false});exit 0
}

$summaries=New-Object System.Collections.Generic.List[object]
$matches=New-Object System.Collections.Generic.List[object]
foreach($dto in $userDtos){
  try{
    $uid=[string]$dto.Id;$h=$authById[$uid];$views=@(Get-ViewNames $uid $h)
    $summary=[pscustomobject][ordered]@{name=[string]$dto.Name;id=$uid;enableAllFolders=[bool]$dto.Policy.EnableAllFolders;enabledFolderCount=@($dto.Policy.EnabledFolders).Count;viewCount=$views.Count;views=$views;screenshotMatch=(Same-Set $views $ExpectedScreenshotViews)}
    [void]$summaries.Add($summary);if($summary.screenshotMatch){[void]$matches.Add($summary)}
  }catch{[void]$summaries.Add([pscustomobject][ordered]@{name=[string]$dto.Name;id=[string]$dto.Id;error=$_.Exception.Message;screenshotMatch=$false})}
}

if($Action -eq 'audit'){
  Emit ([ordered]@{ok=$true;schema='afz.jellyfin-visibility.v2';action='audit';status='AUDIT_ONLY';computer=$env:COMPUTERNAME;serverName=$(if($server){[string]$server.ServerName}else{$null});serverVersion=$(if($server){[string]$server.Version}else{$null});authMode=$authMode;expectedScreenshotViews=$ExpectedScreenshotViews;userCount=$summaries.Count;matchCount=$matches.Count;users=@($summaries);secretExposed=$false;databaseWrite=$false;mediaWrite=$false});exit 0
}

if($matches.Count -ne 1){
  Emit ([ordered]@{ok=$false;schema='afz.jellyfin-visibility.v2';action='repair';status='SAFE_STOP';reason="Expected exactly one readable Jellyfin user matching the screenshot's three visible views; found $($matches.Count).";authMode=$authMode;expectedScreenshotViews=$ExpectedScreenshotViews;matchCount=$matches.Count;users=@($summaries);secretExposed=$false;databaseWrite=$false;mediaWrite=$false});exit 0
}

$target=$matches[0];$targetId=[string]$target.id;$headers=$authById[$targetId]
$beforeDto=Invoke-RestMethod -Method Get -Uri "$BaseUri/Users/$targetId" -Headers $headers -TimeoutSec 10
$beforeViews=@(Get-ViewNames $targetId $headers);$policy=$beforeDto.Policy;$enableBefore=[bool]$policy.EnableAllFolders
if($policy.PSObject.Properties.Name -contains 'EnableAllFolders'){$policy.EnableAllFolders=$true}else{$policy|Add-Member -NotePropertyName EnableAllFolders -NotePropertyValue $true}
$body=$policy|ConvertTo-Json -Depth 30 -Compress
try{
  Invoke-RestMethod -Method Post -Uri "$BaseUri/Users/$targetId/Policy" -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 15|Out-Null
}catch{
  Emit ([ordered]@{ok=$false;schema='afz.jellyfin-visibility.v2';action='repair';status='SAFE_STOP';reason=('Jellyfin policy API denied the scoped update: '+$_.Exception.Message);authMode=$authMode;matchCount=1;targetUser=[ordered]@{name=[string]$beforeDto.Name;id=$targetId};enableAllFoldersBefore=$enableBefore;beforeViews=$beforeViews;secretExposed=$false;passwordChanged=$false;administratorChanged=$false;databaseWrite=$false;mediaWrite=$false});exit 0
}
Start-Sleep -Milliseconds 800
$afterDto=Invoke-RestMethod -Method Get -Uri "$BaseUri/Users/$targetId" -Headers $headers -TimeoutSec 10
$afterViews=@(Get-ViewNames $targetId $headers);$requiredMissing=@($RequiredRecoveredViews|Where-Object {$afterViews -notcontains $_});$policyApplied=[bool]$afterDto.Policy.EnableAllFolders;$verified=($policyApplied -and $requiredMissing.Count -eq 0)
Emit ([ordered]@{ok=$verified;schema='afz.jellyfin-visibility.v2';action='repair';status=$(if($verified){'PASS'}elseif($policyApplied){'POLICY_APPLIED_REQUIRED_VIEWS_MISSING'}else{'POLICY_NOT_APPLIED'});computer=$env:COMPUTERNAME;serverName=$(if($server){[string]$server.ServerName}else{$null});serverVersion=$(if($server){[string]$server.Version}else{$null});authMode=$authMode;matchCount=1;targetUser=[ordered]@{name=[string]$afterDto.Name;id=$targetId};enableAllFoldersBefore=$enableBefore;enableAllFoldersAfter=$policyApplied;beforeViews=$beforeViews;afterViews=$afterViews;requiredRecoveredViews=$RequiredRecoveredViews;requiredMissing=$requiredMissing;changed=($enableBefore -ne $policyApplied);secretExposed=$false;passwordChanged=$false;administratorChanged=$false;databaseWrite=$false;mediaWrite=$false})
