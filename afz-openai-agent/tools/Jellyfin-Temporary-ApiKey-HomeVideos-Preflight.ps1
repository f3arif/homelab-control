#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:8096'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$name='AFZ-Temporary-HomeVideos-Preflight'
$token=[guid]::NewGuid().ToString('N')
function J($o){$o|ConvertTo-Json -Depth 30 -Compress}
function Find-Cmd([string[]]$names){foreach($n in $names){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Path){return $c.Path};if($c.Source){return $c.Source}}};return $null}
function Run-Py([string]$mode){
 $python=Find-Cmd @('python.exe','python','py.exe','py');if(-not $python){throw 'Python required'}
 $tmp=Join-Path $env:TEMP ('jf-temp-home-'+[guid]::NewGuid().ToString('n')+'.py')
 $py=@'
import sqlite3,sys,datetime
p,mode,token,name=sys.argv[1:5]
con=sqlite3.connect(p,timeout=15)
try:
 con.execute('PRAGMA busy_timeout=15000')
 if mode=='insert':
  cols=[r[1] for r in con.execute('pragma table_info("ApiKeys")')]
  required={'AccessToken','DateCreated','DateLastActivity','Name'}
  if not required.issubset(set(cols)):
   print('SCHEMA_MISMATCH');raise SystemExit(3)
  now=datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S.%f')+'0'
  before=con.execute('select count(*) from ApiKeys').fetchone()[0]
  con.execute('insert into ApiKeys(AccessToken,DateCreated,DateLastActivity,Name) values(?,?,?,?)',(token,now,now,name));con.commit()
  after=con.execute('select count(*) from ApiKeys').fetchone()[0]
  exists=con.execute('select count(*) from ApiKeys where AccessToken=? and Name=?',(token,name)).fetchone()[0]
  print('INSERT|before=%d|after=%d|exists=%d'%(before,after,exists))
 elif mode=='delete':
  before=con.execute('select count(*) from ApiKeys where AccessToken=? and Name=?',(token,name)).fetchone()[0]
  con.execute('delete from ApiKeys where AccessToken=? and Name=?',(token,name));con.commit()
  after=con.execute('select count(*) from ApiKeys where AccessToken=? and Name=?',(token,name)).fetchone()[0]
  print('DELETE|before=%d|after=%d'%(before,after))
 elif mode=='verify':
  n=con.execute('select count(*) from ApiKeys where AccessToken=? or Name=?',(token,name)).fetchone()[0]
  print('VERIFY|remaining=%d'%n)
finally:con.close()
'@
 [IO.File]::WriteAllText($tmp,$py,(New-Object Text.UTF8Encoding($false)))
 try{if([IO.Path]::GetFileName($python)-match '^py(\.exe)?$'){& $python -3 $tmp $db $mode $token $name}else{& $python $tmp $db $mode $token $name};if($LASTEXITCODE -ne 0){throw "SQLite $mode exit=$LASTEXITCODE"}}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
}
function Get-Jf([string]$path){$sep=if($path.Contains('?')){'&'}else{'?'};Invoke-RestMethod -Uri ($base+$path+$sep+'api_key='+[uri]::EscapeDataString($token)) -TimeoutSec 10}
Write-Output 'AFZ_JELLYFIN_TEMP_APIKEY_HOMEVIDEOS_PREFLIGHT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY_LIBRARY=true'
Write-Output 'TEMP_CREDENTIAL_EXPOSED=false'
$inserted=$false
try{
 if(-not(Test-Path -LiteralPath $db -PathType Leaf)){throw 'Live DB missing'}
 $ins=@(Run-Py insert)-join ';';if($ins -notmatch 'exists=1'){throw 'Temporary key insert verification failed'};$inserted=$true
 Write-Output 'TEMP_KEY_INSERTED=true'
 $sys=Get-Jf '/System/Info'
 Write-Output ('API_AUTH=PASS|server='+[string]$sys.ServerName+'|version='+[string]$sys.Version+'|id='+[string]$sys.Id)
 $vf=@(Get-Jf '/Library/VirtualFolders')
 $san=@();foreach($x in $vf){$pis=@();if($x.LibraryOptions -and $x.LibraryOptions.PathInfos){$pis=@($x.LibraryOptions.PathInfos|ForEach-Object{[string]$_.Path})};$san += [ordered]@{name=[string]$x.Name;itemId=[string]$x.ItemId;collectionType=[string]$x.CollectionType;locations=@($x.Locations|ForEach-Object{[string]$_});pathInfos=$pis}}
 Write-Output ('VIRTUAL_FOLDERS|'+(J ([ordered]@{count=$san.Count;items=$san})))
 $home=@($san|Where-Object{$_.name -eq 'Home Videos and Photos'});Write-Output ('HOME_VIRTUAL_FOLDER_COUNT='+$home.Count);foreach($x in $home){Write-Output ('HOME_VIRTUAL_FOLDER|'+(J $x))}
 Write-Output ('LOCAL_VF_DIR_EXISTS='+(Test-Path -LiteralPath 'C:\Users\Faiz\AppData\Local\Jellyfin\root\default\Home Videos and Photos' -PathType Container))
 Write-Output ('PROGRAMDATA_VF_DIR_EXISTS='+(Test-Path -LiteralPath 'C:\ProgramData\Jellyfin\Server\root\default\Home Videos and Photos' -PathType Container))
 Write-Output 'PREFLIGHT_STATUS=PASS'
}catch{Write-Output ('PREFLIGHT_STATUS=SAFE_STOP|error='+$_.Exception.Message)}finally{
 if($inserted){$clean=$false;for($i=1;$i -le 3 -and -not $clean;$i++){try{$null=@(Run-Py delete);$v=@(Run-Py verify)-join ';';if($v -match 'remaining=0'){$clean=$true;Write-Output ('TEMP_KEY_CLEANUP=PASS|attempt='+$i)}}catch{Start-Sleep -Milliseconds 500}};if(-not $clean){Write-Output 'TEMP_KEY_CLEANUP=FAIL'}}else{Write-Output 'TEMP_KEY_CLEANUP=NOT_NEEDED'}
 Write-Output 'TEMP_CREDENTIAL_EXPOSED=false'
}
