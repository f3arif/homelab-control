#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$base='http://127.0.0.1:8096'
Write-Output 'AFZ_JELLYFIN_EXISTING_APIKEY_QUERY_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
if(-not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=DB_MISSING';exit 0}
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'STATUS=SAFE_STOP|reason=NO_PYTHON';exit 0}
$tmpPy=Join-Path $env:TEMP ('jf-qkey-'+[guid]::NewGuid().ToString('n')+'.py')
$tmpJson=Join-Path $env:TEMP ('jf-qkey-'+[guid]::NewGuid().ToString('n')+'.json')
$code=@'
import sqlite3,sys,json,pathlib
p=sys.argv[1];o=sys.argv[2]
c=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=5);c.row_factory=sqlite3.Row
try:
 tabs={r[0] for r in c.execute("select name from sqlite_master where type='table'")}
 rows=[]
 if 'ApiKeys' in tabs:
  cols=[r[1] for r in c.execute('pragma table_info("ApiKeys")')]
  sel=[x for x in ('Id','AccessToken','Name','DateCreated','DateLastActivity') if x in cols]
  q='select '+','.join('"'+x+'"' for x in sel)+' from "ApiKeys"'
  rows=[dict(r) for r in c.execute(q)]
 json.dump(rows,open(o,'w',encoding='utf-8'),default=str)
finally:c.close()
'@
[IO.File]::WriteAllText($tmpPy,$code,(New-Object Text.UTF8Encoding($false)))
try{
 $exe=$py.Path
 if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){& $exe -3 $tmpPy $db $tmpJson *> $null}else{& $exe $tmpPy $db $tmpJson *> $null}
 if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $tmpJson)){Write-Output 'STATUS=SAFE_STOP|reason=DB_READ_FAILED';exit 0}
 $keys=@(Get-Content -LiteralPath $tmpJson -Raw -Encoding UTF8|ConvertFrom-Json)
 Write-Output ('APIKEY_ROW_COUNT='+$keys.Count)
 $usable=0;$vfusable=0
 foreach($k in $keys){
   $tok=[string]$k.AccessToken
   if([string]::IsNullOrWhiteSpace($tok)){continue}
   $ok=$false;$vf=$false;$status=''
   try{
     $u=$base+'/System/Info?ApiKey='+[uri]::EscapeDataString($tok)
     $r=Invoke-RestMethod -Uri $u -Method Get -TimeoutSec 8
     if($null -ne $r){$ok=$true;$status='200'}
   }catch{$status=[string]$_.Exception.Response.StatusCode.value__}
   if($ok){
     $usable++
     try{
       $u2=$base+'/Library/VirtualFolders?ApiKey='+[uri]::EscapeDataString($tok)
       $v=Invoke-RestMethod -Uri $u2 -Method Get -TimeoutSec 8
       if($null -ne $v){$vf=$true;$vfusable++}
     }catch{}
   }
   Write-Output ('APIKEY_TEST|rowId='+[string]$k.Id+'|name='+([string]$k.Name -replace '\|','/')+'|systeminfo_ok='+$ok+'|virtualfolders_ok='+$vf+'|status='+$status)
 }
 Write-Output ('USABLE_APIKEY_COUNT='+$usable)
 Write-Output ('VIRTUALFOLDER_APIKEY_COUNT='+$vfusable)
 Write-Output 'SECRET_EXPOSED=false'
 Write-Output 'STATUS=PASS'
}finally{Remove-Item -LiteralPath $tmpPy,$tmpJson -Force -ErrorAction SilentlyContinue}
