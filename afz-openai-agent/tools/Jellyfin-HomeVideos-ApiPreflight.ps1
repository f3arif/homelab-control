#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$base='http://127.0.0.1:8096'
$name='Home Videos and Photos'
$source='C:\Users\Faiz\Downloads\Cloud drive\OneDrive'
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_API_PREFLIGHT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
if(-not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=DB_MISSING';exit 2}
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'STATUS=SAFE_STOP|reason=NO_PYTHON';exit 2}
$tmp=Join-Path $env:TEMP ('jf-key-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3,sys
p=sys.argv[1]
c=sqlite3.connect('file:'+p.replace('\\','/')+'?mode=ro',uri=True)
try:
 r=c.execute("select AccessToken from ApiKeys order by coalesce(DateLastActivity,DateCreated) desc limit 1").fetchone()
 print('' if not r else r[0])
finally:c.close()
'@
[IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
try{
 $exe=$py.Path
 if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){$token=(& $exe -3 $tmp $db|Out-String).Trim()}else{$token=(& $exe $tmp $db|Out-String).Trim()}
}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
if([string]::IsNullOrWhiteSpace($token)){Write-Output 'STATUS=SAFE_STOP|reason=NO_API_KEY';exit 2}
$auth='MediaBrowser Client="AFZ-Jellyfin-Repair", Device="Windows-main", DeviceId="afz-jellyfin-repair", Version="1.0", Token="'+$token+'"'
$headers=@{Authorization=$auth;Accept='application/json'}
try{$vf=Invoke-RestMethod -Uri ($base+'/Library/VirtualFolders') -Headers $headers -Method Get -TimeoutSec 20}catch{Write-Output ('STATUS=SAFE_STOP|reason=VIRTUALFOLDERS_API_FAILED|error='+$_.Exception.Message);exit 3}
$lib=@($vf|Where-Object {[string]$_.Name -eq $name})
Write-Output ('VIRTUAL_FOLDER_MATCH_COUNT='+$lib.Count)
if($lib.Count -ne 1){Write-Output 'STATUS=SAFE_STOP|reason=HOME_LIBRARY_NOT_UNIQUE';exit 4}
$l=$lib[0]
Write-Output ('LIB_NAME='+[string]$l.Name)
Write-Output ('LIB_ITEM_ID='+[string]$l.ItemId)
$locations=@($l.Locations)
Write-Output ('LOCATION_COUNT='+$locations.Count)
foreach($p in $locations){Write-Output ('LOCATION|path='+[string]$p+'|exists='+(Test-Path -LiteralPath ([string]$p)))}
$pis=@($l.LibraryOptions.PathInfos)
Write-Output ('PATHINFO_COUNT='+$pis.Count)
foreach($pi in $pis){Write-Output ('PATHINFO|path='+[string]$pi.Path+'|networkPath='+[string]$pi.NetworkPath)}
Write-Output ('SOURCE_IN_LOCATIONS='+[string]([bool](@($locations|Where-Object{[string]$_ -ieq $source}).Count)))
Write-Output ('SOURCE_IN_PATHINFOS='+[string]([bool](@($pis|Where-Object{[string]$_.Path -ieq $source}).Count)))
Write-Output ('SOURCE_EXISTS='+(Test-Path -LiteralPath $source -PathType Container))
Write-Output 'STATUS=PASS'
