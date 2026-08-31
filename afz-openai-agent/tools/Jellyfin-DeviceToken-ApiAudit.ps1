#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$base='http://127.0.0.1:8096'
Write-Output 'AFZ_JELLYFIN_DEVICE_TOKEN_API_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py -or -not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=PREREQ_MISSING';exit 0}
$tmpPy=Join-Path $env:TEMP ('jf-device-'+[guid]::NewGuid().ToString('n')+'.py')
$tmpJson=Join-Path $env:TEMP ('jf-device-'+[guid]::NewGuid().ToString('n')+'.json')
$code=@'
import sqlite3,sys,json,pathlib
p=sys.argv[1];o=sys.argv[2]
c=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=5);c.row_factory=sqlite3.Row
try:
 tabs={r[0] for r in c.execute("select name from sqlite_master where type='table'")}
 out={'tables':sorted(tabs),'devices':[]}
 if 'Devices' in tabs:
  cols=[r[1] for r in c.execute('pragma table_info("Devices")')]
  sel=[x for x in ('Id','AccessToken','UserId','DeviceId','AppName','AppVersion','DeviceName','DateCreated','DateLastActivity') if x in cols]
  if sel:
   q='select '+','.join('"'+x+'"' for x in sel)+' from "Devices"'
   rows=[dict(r) for r in c.execute(q)]
   out['devices']=rows
 json.dump(out,open(o,'w',encoding='utf-8'),default=str)
finally:c.close()
'@
[IO.File]::WriteAllText($tmpPy,$code,(New-Object Text.UTF8Encoding($false)))
try{
 $exe=$py.Path
 if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){& $exe -3 $tmpPy $db $tmpJson *> $null}else{& $exe $tmpPy $db $tmpJson *> $null}
 if($LASTEXITCODE -ne 0 -or -not(Test-Path $tmpJson)){Write-Output 'STATUS=SAFE_STOP|reason=DB_READ_FAILED';exit 0}
 $info=Get-Content $tmpJson -Raw -Encoding UTF8|ConvertFrom-Json
 $devices=@($info.devices)
 Write-Output ('DEVICE_ROW_COUNT='+$devices.Count)
 $usable=0
 foreach($d in $devices){
   $tok=[string]$d.AccessToken
   if([string]::IsNullOrWhiteSpace($tok)){continue}
   $h=@{Authorization=('MediaBrowser Client="AFZ-Device-Audit", Device="Windows-main", DeviceId="afz-device-audit", Version="1.0", Token="'+$tok+'"');Accept='application/json'}
   $ok=$false;$admin=$false;$uname='';$uid=[string]$d.UserId;$vf=$false
   try{
     if($uid){$u=Invoke-RestMethod -Uri ($base+'/Users/'+$uid) -Headers $h -TimeoutSec 5;$uname=[string]$u.Name;if($u.Policy){$admin=[bool]$u.Policy.IsAdministrator};$ok=$true}
     else{$si=Invoke-RestMethod -Uri ($base+'/System/Info') -Headers $h -TimeoutSec 5;$ok=($null -ne $si)}
   }catch{}
   if($ok){try{$x=Invoke-RestMethod -Uri ($base+'/Library/VirtualFolders') -Headers $h -TimeoutSec 6;$vf=($null -ne $x)}catch{}}
   if($ok){$usable++}
   Write-Output ('DEVICE_AUTH|rowId='+[string]$d.Id+'|userId='+$uid+'|user='+$uname+'|app='+[string]$d.AppName+'|device='+[string]$d.DeviceName+'|auth_ok='+$ok+'|admin='+$admin+'|virtualfolders_ok='+$vf)
 }
 Write-Output ('USABLE_DEVICE_TOKEN_COUNT='+$usable)
 Write-Output 'STATUS=PASS'
}finally{Remove-Item -LiteralPath $tmpPy,$tmpJson -Force -ErrorAction SilentlyContinue}
