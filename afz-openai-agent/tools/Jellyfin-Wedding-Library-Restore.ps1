#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$dataRoot='C:\Users\Faiz\AppData\Local\Jellyfin'
$base='http://127.0.0.1:8096'
$name='Wedding'
$source='C:\Users\Faiz\Videos\Shared'
$collectionType='homevideos'
$users=[ordered]@{coolyo='2D994DBA-B8C7-44C8-8D34-7D85716B2EBC';movies='64F6DF5C-78B5-4DFE-B0FF-7295CBFB3A5A'}
Write-Output 'AFZ_JELLYFIN_WEDDING_LIBRARY_RESTORE_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'SECRET_EXPOSED=false'
Write-Output ('SOURCE='+$source)
Write-Output ('COLLECTION_TYPE='+$collectionType)
if(-not(Test-Path -LiteralPath $source -PathType Container)){Write-Output 'STATUS=SAFE_STOP|reason=SOURCE_MISSING';exit 2}
$media=0
foreach($f in Get-ChildItem -LiteralPath $source -File -Recurse -ErrorAction SilentlyContinue){if($f.Extension -match '(?i)^\.(mp4|mkv|mov|avi|m4v|mts|m2ts|mpg|mpeg|jpg|jpeg|png|heic|webp)$'){$media++;if($media -ge 10000){break}}}
Write-Output ('SOURCE_MEDIA_COUNT_CAPPED='+$media)
if($media -lt 1){Write-Output 'STATUS=SAFE_STOP|reason=SOURCE_HAS_NO_MEDIA';exit 2}
if(-not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=LIVE_DB_MISSING';exit 2}
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'STATUS=SAFE_STOP|reason=NO_PYTHON';exit 2}
$tmpPy=Join-Path $env:TEMP ('jf-wedding-'+[guid]::NewGuid().ToString('n')+'.py')
$tmpJson=Join-Path $env:TEMP ('jf-wedding-'+[guid]::NewGuid().ToString('n')+'.json')
$pyCode=@'
import sqlite3,sys,json,pathlib
p=sys.argv[1];o=sys.argv[2]
c=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=5)
try:
 r=c.execute("select AccessToken from ApiKeys where AccessToken is not null order by coalesce(DateLastActivity,DateCreated) desc limit 1").fetchone()
 json.dump({'token':'' if not r else r[0]},open(o,'w',encoding='utf-8'))
finally:c.close()
'@
[IO.File]::WriteAllText($tmpPy,$pyCode,(New-Object Text.UTF8Encoding($false)))
try{
 $exe=$py.Path
 if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){& $exe -3 $tmpPy $db $tmpJson *> $null}else{& $exe $tmpPy $db $tmpJson *> $null}
 if($LASTEXITCODE -ne 0 -or -not(Test-Path $tmpJson)){Write-Output 'STATUS=SAFE_STOP|reason=KEY_READ_FAILED';exit 2}
 $token=[string](Get-Content $tmpJson -Raw -Encoding UTF8|ConvertFrom-Json).token
}finally{Remove-Item -LiteralPath $tmpPy,$tmpJson -Force -ErrorAction SilentlyContinue}
if([string]::IsNullOrWhiteSpace($token)){Write-Output 'STATUS=SAFE_STOP|reason=NO_API_KEY';exit 2}
$h=@{Authorization=('MediaBrowser Client="AFZ-Wedding-Restore", Device="Windows-main", DeviceId="afz-wedding-restore", Version="1.0", Token="'+$token+'"');Accept='application/json'}
function Get-VirtualFolders {
  $resp=Invoke-WebRequest -UseBasicParsing -Uri ($base+'/Library/VirtualFolders') -Headers $h -Method Get -TimeoutSec 20
  if([int]$resp.StatusCode -ne 200){throw ('VirtualFolders HTTP '+$resp.StatusCode)}
  $obj=$resp.Content|ConvertFrom-Json
  return @($obj|ForEach-Object{$_})
}
function Get-Views([string]$uid){
  $resp=Invoke-WebRequest -UseBasicParsing -Uri ($base+'/Users/'+$uid+'/Views?IncludeExternalContent=true') -Headers $h -Method Get -TimeoutSec 20
  $obj=$resp.Content|ConvertFrom-Json
  return @($obj.Items|ForEach-Object{$_})
}
try{$vf=Get-VirtualFolders}catch{Write-Output ('STATUS=SAFE_STOP|reason=API_AUTH_OR_VF_FAILED|error='+$_.Exception.Message);exit 3}
$existing=@($vf|Where-Object{[string]$_.Name -eq $name})
Write-Output ('EXISTING_WEDDING_COUNT='+$existing.Count)
if($existing.Count -gt 1){Write-Output 'STATUS=SAFE_STOP|reason=DUPLICATE_WEDDING_EXISTS';exit 4}
if($existing.Count -eq 1){
  $loc=@($existing[0].Locations|ForEach-Object{[string]$_})
  Write-Output ('EXISTING_WEDDING_LOCATIONS='+($loc -join ';'))
  if(@($loc|Where-Object{$_ -ieq $source}).Count -eq 1){Write-Output 'MUTATION=NOOP_ALREADY_PRESENT'}else{Write-Output 'STATUS=SAFE_STOP|reason=WEDDING_EXISTS_WITH_DIFFERENT_SOURCE';exit 4}
}else{
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup=Join-Path 'C:\AFZ\MediaCatalog\Backups' ('JellyfinWeddingRestore-'+$stamp)
  New-Item -ItemType Directory -Force -Path $backup|Out-Null
  $dbBackup=Join-Path $backup 'jellyfin.db'
  $rootBackup=Join-Path $backup 'root-default'
  $tmpB=Join-Path $env:TEMP ('jf-backup-'+[guid]::NewGuid().ToString('n')+'.py')
  $bcode=@'
import sqlite3,sys
src,dst=sys.argv[1],sys.argv[2]
a=sqlite3.connect(src,timeout=15);b=sqlite3.connect(dst,timeout=15)
try:a.backup(b)
finally:b.close();a.close()
'@
  [IO.File]::WriteAllText($tmpB,$bcode,(New-Object Text.UTF8Encoding($false)))
  try{if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){& $exe -3 $tmpB $db $dbBackup *> $null}else{& $exe $tmpB $db $dbBackup *> $null};if($LASTEXITCODE -ne 0 -or -not(Test-Path $dbBackup)){Write-Output 'STATUS=SAFE_STOP|reason=DB_BACKUP_FAILED';exit 5}}finally{Remove-Item -LiteralPath $tmpB -Force -ErrorAction SilentlyContinue}
  $liveRoot=Join-Path $dataRoot 'root\default'
  if(Test-Path -LiteralPath $liveRoot -PathType Container){Copy-Item -LiteralPath $liveRoot -Destination $rootBackup -Recurse -Force -ErrorAction Stop}
  Write-Output ('BACKUP_DIR='+$backup)
  $uri=$base+'/Library/VirtualFolders?name='+[uri]::EscapeDataString($name)+'&collectionType='+[uri]::EscapeDataString($collectionType)+'&paths='+[uri]::EscapeDataString($source)+'&refreshLibrary=true'
  try{
    $resp=Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers $h -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 60
    Write-Output ('CREATE_HTTP_STATUS='+[int]$resp.StatusCode)
    if([int]$resp.StatusCode -notin @(200,204)){throw ('Unexpected create status '+$resp.StatusCode)}
  }catch{Write-Output ('STATUS=FAIL|reason=CREATE_API_FAILED|error='+$_.Exception.Message);exit 6}
  Write-Output 'MUTATION=CREATED_WEDDING_LIBRARY'
}
$found=$null
for($i=0;$i -lt 18;$i++){
  Start-Sleep -Seconds 5
  try{$now=Get-VirtualFolders;$matches=@($now|Where-Object{[string]$_.Name -eq $name});if($matches.Count -eq 1){$found=$matches[0];break}}catch{}
}
if(-not $found){Write-Output 'STATUS=FAIL|reason=WEDDING_NOT_VISIBLE_AFTER_CREATE';exit 7}
$foundLoc=@($found.Locations|ForEach-Object{[string]$_})
Write-Output ('VERIFY_WEDDING_LOCATIONS='+($foundLoc -join ';'))
if(@($foundLoc|Where-Object{$_ -ieq $source}).Count -ne 1){Write-Output 'STATUS=FAIL|reason=WEDDING_SOURCE_MISMATCH_AFTER_CREATE';exit 7}
$allOk=$true
foreach($u in $users.GetEnumerator()){
  try{
    $views=Get-Views $u.Value
    $wm=@($views|Where-Object{[string]$_.Name -eq $name})
    Write-Output ('USER_WEDDING_VIEW|user='+$u.Key+'|matchCount='+$wm.Count+'|ids='+(@($wm|ForEach-Object{[string]$_.Id}) -join ';'))
    if($wm.Count -ne 1){$allOk=$false;continue}
    $wid=[string]$wm[0].Id
    $count=-1
    for($j=0;$j -lt 12;$j++){
      try{$q=Invoke-RestMethod -Uri ($base+'/Users/'+$u.Value+'/Items?ParentId='+$wid+'&Recursive=true&Limit=1&EnableTotalRecordCount=true') -Headers $h -TimeoutSec 20;$count=[int]$q.TotalRecordCount}catch{$count=-1}
      if($count -gt 0){break};Start-Sleep -Seconds 5
    }
    Write-Output ('USER_WEDDING_ITEM_COUNT|user='+$u.Key+'|count='+$count)
    if($count -lt 1){$allOk=$false}
  }catch{Write-Output ('USER_VERIFY_ERROR|user='+$u.Key+'|error='+$_.Exception.Message);$allOk=$false}
}
if(-not $allOk){Write-Output 'STATUS=PARTIAL|reason=LIBRARY_CREATED_BUT_USER_SCAN_OR_VIEW_NOT_READY';exit 8}
Write-Output 'STATUS=PASS'
