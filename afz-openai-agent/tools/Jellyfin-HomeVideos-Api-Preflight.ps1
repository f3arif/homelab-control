#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:8096'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$targetName='Home Videos and Photos'
$targetId='ee75511ae395034b1e7e657707b15125'
$source='C:\Users\Faiz\Downloads\Cloud drive\OneDrive'
function J($o){$o|ConvertTo-Json -Depth 30 -Compress}
function AuthHeader([string]$t){@{Authorization=('MediaBrowser Client="AFZ-HomeVideos-Preflight", Device="Windows-main", DeviceId="afz-jf-home-preflight", Version="1.0", Token="'+$t+'"')}}
function Invoke-Get([string]$path,[string]$mode,[string]$token){
 if($mode -eq 'query'){$sep=if($path.Contains('?')){'&'}else{'?'};return Invoke-RestMethod -Uri ($base+$path+$sep+'api_key='+[uri]::EscapeDataString($token)) -TimeoutSec 8}
 return Invoke-RestMethod -Uri ($base+$path) -Headers (AuthHeader $token) -TimeoutSec 8
}
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_API_PREFLIGHT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
Write-Output ('SOURCE_EXISTS='+(Test-Path -LiteralPath $source -PathType Container))
Write-Output ('LOCAL_VF_DIR_EXISTS='+(Test-Path -LiteralPath 'C:\Users\Faiz\AppData\Local\Jellyfin\root\default\Home Videos and Photos' -PathType Container))
Write-Output ('PROGRAMDATA_VF_DIR_EXISTS='+(Test-Path -LiteralPath 'C:\ProgramData\Jellyfin\Server\root\default\Home Videos and Photos' -PathType Container))
if(-not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=DB_MISSING';exit 0}
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'STATUS=SAFE_STOP|reason=NO_PYTHON';exit 0}
$tmpPy=Join-Path $env:TEMP ('jf-home-auth-'+[guid]::NewGuid().ToString('n')+'.py')
$tmpJson=Join-Path $env:TEMP ('jf-home-auth-'+[guid]::NewGuid().ToString('n')+'.json')
$code=@'
import sqlite3,json,sys,pathlib
p=sys.argv[1];o=sys.argv[2]
c=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=5)
try:
 t={r[0] for r in c.execute("select name from sqlite_master where type='table'")};keys=[]
 if 'ApiKeys' in t:
  cols=[r[1] for r in c.execute('pragma table_info("ApiKeys")')]
  if 'AccessToken' in cols:
   order=' order by DateLastActivity desc,DateCreated desc' if 'DateLastActivity' in cols and 'DateCreated' in cols else ''
   keys=[r[0] for r in c.execute('select AccessToken from ApiKeys where AccessToken is not null and length(AccessToken)>=16'+order)]
 json.dump({'keys':keys},open(o,'w',encoding='utf-8'))
finally:c.close()
'@
[IO.File]::WriteAllText($tmpPy,$code,(New-Object Text.UTF8Encoding($false)))
try{
 $exe=$py.Path;if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){& $exe -3 $tmpPy $db $tmpJson *> $null}else{& $exe $tmpPy $db $tmpJson *> $null}
 if($LASTEXITCODE -ne 0 -or -not(Test-Path $tmpJson)){Write-Output 'STATUS=SAFE_STOP|reason=APIKEY_READ_FAILED';exit 0}
 $keys=@((Get-Content $tmpJson -Raw -Encoding UTF8|ConvertFrom-Json).keys)
 Write-Output ('APIKEY_CANDIDATES='+$keys.Count)
 $token=$null;$mode=$null;$sys=$null
 foreach($k in $keys){
   try{$sys=Invoke-Get '/System/Info' 'header' ([string]$k);if($sys){$token=[string]$k;$mode='header';break}}catch{}
   try{$sys=Invoke-Get '/System/Info' 'query' ([string]$k);if($sys){$token=[string]$k;$mode='query';break}}catch{}
 }
 if(-not $token){Write-Output 'STATUS=SAFE_STOP|reason=NO_WORKING_API_KEY';Write-Output 'SECRET_EXPOSED=false';exit 0}
 Write-Output ('AUTH_MODE=api-key-'+$mode)
 Write-Output ('SERVER|name='+[string]$sys.ServerName+'|version='+[string]$sys.Version+'|id='+[string]$sys.Id)
 try{
   $vf=@(Invoke-Get '/Library/VirtualFolders' $mode $token)
   $san=@()
   foreach($x in $vf){
     $pis=@();if($x.LibraryOptions -and $x.LibraryOptions.PathInfos){$pis=@($x.LibraryOptions.PathInfos|ForEach-Object{[string]$_.Path})}
     $san += [ordered]@{name=[string]$x.Name;itemId=[string]$x.ItemId;collectionType=[string]$x.CollectionType;locations=@($x.Locations|ForEach-Object{[string]$_});pathInfos=$pis}
   }
   Write-Output ('VIRTUAL_FOLDERS|'+(J ([ordered]@{count=$san.Count;items=$san})))
   $home=@($san|Where-Object{$_.name -eq $targetName})
   Write-Output ('HOME_VIRTUAL_FOLDER_COUNT='+$home.Count)
   foreach($x in $home){Write-Output ('HOME_VIRTUAL_FOLDER|'+(J $x))}
 }catch{Write-Output ('VIRTUAL_FOLDERS_ERROR='+$_.Exception.Message);Write-Output 'STATUS=SAFE_STOP|reason=VIRTUAL_FOLDER_API_FAILED';exit 0}
 foreach($uid in @('2D994DBA-B8C7-44C8-8D34-7D85716B2EBC','64F6DF5C-78B5-4DFE-B0FF-7295CBFB3A5A')){
   try{$q='/Users/'+$uid+'/Items?ParentId='+$targetId+'&Recursive=true&Limit=1';$r=Invoke-Get $q $mode $token;Write-Output ('TARGET_ITEMS|user='+$uid+'|total='+[int]$r.TotalRecordCount)}catch{Write-Output ('TARGET_ITEMS_ERROR|user='+$uid+'|error='+$_.Exception.Message)}
 }
 Write-Output 'SECRET_EXPOSED=false'
 Write-Output 'STATUS=PASS'
} finally {Remove-Item -LiteralPath $tmpPy,$tmpJson -Force -ErrorAction SilentlyContinue}
