#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$base='http://127.0.0.1:8096'
Write-Output 'AFZ_JELLYFIN_VIRTUALFOLDERS_LIVE_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py -or -not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=PREREQ_MISSING';exit 2}
$tmp=Join-Path $env:TEMP ('jf-vfkey-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3,sys
p=sys.argv[1]
c=sqlite3.connect('file:'+p.replace('\\','/')+'?mode=ro',uri=True)
try:
 r=c.execute("select AccessToken from ApiKeys where AccessToken is not null order by coalesce(DateLastActivity,DateCreated) desc limit 1").fetchone()
 print('' if not r else r[0])
finally:c.close()
'@
[IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
try{
 $exe=$py.Path
 if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){$token=(& $exe -3 $tmp $db|Out-String).Trim()}else{$token=(& $exe $tmp $db|Out-String).Trim()}
}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
if([string]::IsNullOrWhiteSpace($token)){Write-Output 'STATUS=SAFE_STOP|reason=NO_API_KEY';exit 2}
$headers=@{Authorization=('MediaBrowser Client="AFZ-VF-Audit", Device="Windows-main", DeviceId="afz-vf-audit", Version="1.0", Token="'+$token+'"');Accept='application/json'}
try{$vf=@(Invoke-RestMethod -Uri ($base+'/Library/VirtualFolders') -Headers $headers -Method Get -TimeoutSec 20)}catch{Write-Output ('STATUS=SAFE_STOP|reason=VIRTUALFOLDERS_API_FAILED|error='+$_.Exception.Message);exit 3}
Write-Output ('VIRTUAL_FOLDER_COUNT='+$vf.Count)
foreach($x in $vf){
 $loc=@($x.Locations|ForEach-Object{[string]$_})
 $pi=@();if($x.LibraryOptions -and $x.LibraryOptions.PathInfos){$pi=@($x.LibraryOptions.PathInfos|ForEach-Object{[string]$_.Path})}
 Write-Output ('VF|name='+[string]$x.Name+'|itemId='+[string]$x.ItemId+'|collectionType='+[string]$x.CollectionType+'|locations='+($loc -join ';')+'|pathInfos='+($pi -join ';'))
}
try{$users=@(Invoke-RestMethod -Uri ($base+'/Users') -Headers $headers -TimeoutSec 20)}catch{$users=@();Write-Output ('USERS_ERROR='+$_.Exception.Message)}
foreach($u in $users){
 try{$v=Invoke-RestMethod -Uri ($base+'/Users/'+$u.Id+'/Views?IncludeExternalContent=true') -Headers $headers -TimeoutSec 20;$items=@($v.Items);Write-Output ('USER_VIEWS|user='+[string]$u.Name+'|id='+[string]$u.Id+'|count='+$items.Count);foreach($i in $items){Write-Output ('VIEW|user='+[string]$u.Name+'|name='+[string]$i.Name+'|id='+[string]$i.Id+'|collectionType='+[string]$i.CollectionType)}}catch{Write-Output ('USER_VIEWS_ERROR|user='+[string]$u.Name+'|error='+$_.Exception.Message)}
}
Write-Output 'STATUS=PASS'
