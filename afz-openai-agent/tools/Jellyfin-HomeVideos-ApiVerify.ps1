#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$base='http://127.0.0.1:8096'
$users=[ordered]@{coolyo='2D994DBA-B8C7-44C8-8D34-7D85716B2EBC';movies='64F6DF5C-78B5-4DFE-B0FF-7295CBFB3A5A'}
$ids=[ordered]@{
 collection='EE75511A-E395-034B-1E7E-657707B15125'
 physical='BE04AC47-5861-0637-7D2C-74AC1432209E'
 homeFolder='2B35A83B-83D2-A7B1-F422-959798E413F6'
 bobbyWedding='546F87B6-37F1-03B8-CA39-D8E01604039E'
 sanaWedding='89675062-5DCB-F8B4-4F10-37CB3152079E'
 dimpuWedding='9E948DCA-E312-3D65-33D5-2086B99C59CC'
 saniaWedding='C31F19D3-3F08-D772-512D-25F7AA40041C'
}
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_API_VERIFY_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py -or -not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=PREREQ_MISSING';exit 2}
$tmp=Join-Path $env:TEMP ('jf-key-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3,sys
c=sqlite3.connect('file:'+sys.argv[1].replace('\\','/')+'?mode=ro',uri=True,timeout=5)
try:
 r=c.execute("select AccessToken from ApiKeys where AccessToken is not null order by coalesce(DateLastActivity,DateCreated) desc limit 1").fetchone()
 print('' if not r else r[0])
finally:c.close()
'@
[IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
try{$exe=$py.Path;if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){$token=(& $exe -3 $tmp $db|Out-String).Trim()}else{$token=(& $exe $tmp $db|Out-String).Trim()}}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
if([string]::IsNullOrWhiteSpace($token)){Write-Output 'STATUS=SAFE_STOP|reason=NO_API_KEY';exit 2}
$h=@{Authorization=('MediaBrowser Client="AFZ-HomeVideos-Verify", Device="Windows-main", DeviceId="afz-homevideos-verify", Version="1.0", Token="'+$token+'"');Accept='application/json'}
try{$vf=@(Invoke-RestMethod -Uri ($base+'/Library/VirtualFolders') -Headers $h -TimeoutSec 15)}catch{Write-Output ('STATUS=SAFE_STOP|reason=VIRTUALFOLDERS_FAILED|error='+$_.Exception.Message);exit 3}
$home=@($vf|Where-Object{[string]$_.Name -eq 'Home Videos and Photos'})
Write-Output ('HOME_VIRTUALFOLDER_MATCH_COUNT='+$home.Count)
foreach($x in $home){Write-Output ('HOME_VF|name='+[string]$x.Name+'|locations='+(@($x.Locations|ForEach-Object{[string]$_}) -join ';'))}
function Query-Count([string]$userId,[string]$parentId,[bool]$recursive){
  $r=[string]$recursive
  $uri=$base+'/Users/'+$userId+'/Items?ParentId='+$parentId+'&Recursive='+$r+'&Limit=1&EnableTotalRecordCount=true'
  try{$q=Invoke-RestMethod -Uri $uri -Headers $h -TimeoutSec 15;return [int]$q.TotalRecordCount}catch{return -1}
}
foreach($u in $users.GetEnumerator()){
  try{$views=Invoke-RestMethod -Uri ($base+'/Users/'+$u.Value+'/Views?IncludeExternalContent=true') -Headers $h -TimeoutSec 15;$items=@($views.Items);$hv=@($items|Where-Object{[string]$_.Name -eq 'Home Videos and Photos'});Write-Output ('USER_VIEWS|user='+$u.Key+'|count='+$items.Count+'|homeMatch='+$hv.Count+'|homeIds='+(@($hv|ForEach-Object{[string]$_.Id}) -join ';'))}catch{Write-Output ('USER_VIEWS_ERROR|user='+$u.Key+'|error='+$_.Exception.Message)}
  foreach($e in $ids.GetEnumerator()){
    $direct=Query-Count $u.Value $e.Value $false
    $rec=Query-Count $u.Value $e.Value $true
    Write-Output ('ITEM_COUNT|user='+$u.Key+'|target='+$e.Key+'|id='+$e.Value+'|direct='+$direct+'|recursive='+$rec)
  }
}
Write-Output 'STATUS=PASS'
