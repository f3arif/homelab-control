#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
function Find-CommandPath([string[]]$Names){foreach($n in $Names){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}};return $null}
function Safe([object]$v){if($null -eq $v){return ''};return ([string]$v).Replace("`r",' ').Replace("`n",' ')}
Write-Output 'AFZ_JELLYFIN_RUNTIME_ROOT_AUDIT_V4'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
foreach($p in @(Get-Process jellyfin -ErrorAction SilentlyContinue)){
  Write-Output ('PROCESS|pid='+$p.Id+'|start='+$p.StartTime.ToString('o')+'|path='+(Safe $p.Path))
}
foreach($p in @(Get-Process ffmpeg -ErrorAction SilentlyContinue)){
  Write-Output ('FFMPEG|pid='+$p.Id+'|start='+$p.StartTime.ToString('o'))
}
foreach($s in @(Get-Service -ErrorAction SilentlyContinue|Where-Object {$_.Name -match '(?i)jellyfin' -or $_.DisplayName -match '(?i)jellyfin'})){
  Write-Output ('SERVICE|name='+$s.Name+'|display='+(Safe $s.DisplayName)+'|status='+$s.Status+'|startType='+$s.StartType)
}
foreach($root in @('C:\Users\Faiz\AppData\Local\Jellyfin\root\default','C:\ProgramData\Jellyfin\Server\root\default')){
  if(Test-Path -LiteralPath $root -PathType Container){
    Write-Output ('ROOT|path='+$root)
    foreach($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue|Sort-Object Name)){
      Write-Output ('ROOT_LIBRARY|root='+$root+'|name='+(Safe $d.Name)+'|modified='+$d.LastWriteTime.ToString('o'))
    }
  }else{Write-Output ('ROOT_MISSING|path='+$root)}
}
try{$pub=Invoke-RestMethod -Uri 'http://127.0.0.1:8096/System/Info/Public' -TimeoutSec 8;Write-Output ('SERVER|name='+$pub.ServerName+'|version='+$pub.Version+'|id='+$pub.Id)}catch{Write-Output ('SERVER_ERROR|'+$_.Exception.Message)}
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
if(Test-Path -LiteralPath $db -PathType Leaf){
  $fi=Get-Item -LiteralPath $db;Write-Output ('DB|path='+$db+'|modified='+$fi.LastWriteTime.ToString('o')+'|bytes='+$fi.Length)
  $python=Find-CommandPath @('python.exe','python','py.exe','py')
  if($python){
    $launcher=([IO.Path]::GetFileName($python)-match '^py(\.exe)?$')
    $tmp=Join-Path $env:TEMP ('jf-runtime-v4-'+[guid]::NewGuid().ToString('n')+'.py')
    $py=@'
import sqlite3, pathlib, sys
p=sys.argv[1]
con=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=5)
try:
  for r in con.execute("select Id,Name,Path from BaseItems where Type like '%CollectionFolder%' order by Name"):
    print('DB_LIBRARY|id='+str(r[0])+'|name='+str(r[1])+'|path='+str(r[2]))
finally: con.close()
'@
    [IO.File]::WriteAllText($tmp,$py,(New-Object Text.UTF8Encoding($false)))
    try{if($launcher){& $python -3 $tmp $db}else{& $python $tmp $db}}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
  }
}
Write-Output 'AUDIT_STATUS=PASS'
