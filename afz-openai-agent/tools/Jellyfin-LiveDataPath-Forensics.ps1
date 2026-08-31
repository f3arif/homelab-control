#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Write-Output 'AFZ_JELLYFIN_LIVE_DATAPATH_FORENSICS_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
$base='http://127.0.0.1:8096'
try{$pub=Invoke-RestMethod -Uri ($base+'/System/Info/Public') -TimeoutSec 5;Write-Output ('PUBLIC_SERVER|name='+[string]$pub.ServerName+'|version='+[string]$pub.Version+'|id='+[string]$pub.Id+'|local='+[string]$pub.LocalAddress)}catch{Write-Output ('PUBLIC_SERVER_ERROR='+$_.Exception.Message)}
$procs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '(?i)^jellyfin(\.exe)?$'})
Write-Output ('JELLYFIN_PROCESS_COUNT='+$procs.Count)
foreach($p in $procs){
 $owner='';try{$o=Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop;$owner=([string]$o.Domain+'\'+[string]$o.User).Trim('\')}catch{}
 Write-Output ('PROCESS|pid='+$p.ProcessId+'|ppid='+$p.ParentProcessId+'|owner='+$owner+'|exe='+[string]$p.ExecutablePath+'|cmd='+(([string]$p.CommandLine)-replace '\|','/'))
}
try{
 $listeners=@(Get-NetTCPConnection -LocalPort 8096 -State Listen -ErrorAction SilentlyContinue)
 Write-Output ('LISTENER_COUNT='+$listeners.Count)
 foreach($l in $listeners){$pp=Get-CimInstance Win32_Process -Filter ('ProcessId='+$l.OwningProcess) -ErrorAction SilentlyContinue;Write-Output ('LISTENER|addr='+$l.LocalAddress+'|pid='+$l.OwningProcess+'|process='+[string]$pp.Name+'|exe='+[string]$pp.ExecutablePath+'|cmd='+(([string]$pp.CommandLine)-replace '\|','/'))}
}catch{Write-Output ('LISTENER_ERROR='+$_.Exception.Message)}
foreach($tn in @('Jellyfin Server','Jellyfin Watchdog')){try{$t=Get-ScheduledTask -TaskName $tn -ErrorAction Stop;$acts=@($t.Actions|ForEach-Object{([string]$_.Execute+' '+[string]$_.Arguments).Trim()});Write-Output ('TASK|name='+$tn+'|state='+[string]$t.State+'|user='+[string]$t.Principal.UserId+'|logon='+[string]$t.Principal.LogonType+'|actions='+($acts -join ' ; '))}catch{Write-Output ('TASK|name='+$tn+'|missing=true')}}
$candidateRoots=@(
 'C:\Users\Faiz\AppData\Local\Jellyfin',
 'C:\ProgramData\Jellyfin',
 'C:\Windows\System32\config\systemprofile\AppData\Local\Jellyfin',
 'C:\Windows\SysWOW64\config\systemprofile\AppData\Local\Jellyfin',
 'C:\AFZ'
)
$dbSet=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($r in $candidateRoots){if(Test-Path -LiteralPath $r -PathType Container){Write-Output ('CANDIDATE_ROOT|path='+$r+'|exists=true');foreach($f in @(Get-ChildItem -LiteralPath $r -Recurse -Filter 'jellyfin.db' -File -ErrorAction SilentlyContinue)){[void]$dbSet.Add($f.FullName)}}else{Write-Output ('CANDIDATE_ROOT|path='+$r+'|exists=false')}}
# Also inspect shallow user/system locations for alternate installations.
foreach($r in @('C:\Users','C:\ProgramData','C:\Windows\System32\config\systemprofile')){if(Test-Path -LiteralPath $r -PathType Container){foreach($f in @(Get-ChildItem -LiteralPath $r -Recurse -Filter 'jellyfin.db' -File -ErrorAction SilentlyContinue|Select-Object -First 50)){[void]$dbSet.Add($f.FullName)}}}
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
foreach($db in @($dbSet|Sort-Object)){
 $fi=Get-Item -LiteralPath $db -ErrorAction SilentlyContinue
 $api=-1;$users=-1;$baseItems=-1;$home=0;$wedding=0;$err=''
 if($py){
   $tmp=Join-Path $env:TEMP ('jf-dbmeta-'+[guid]::NewGuid().ToString('n')+'.py')
   $code=@'
import sqlite3,sys,pathlib,json
p=sys.argv[1]
o={'api':-1,'users':-1,'base':-1,'home':0,'wedding':0,'err':''}
try:
 c=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=4)
 t={r[0] for r in c.execute("select name from sqlite_master where type='table'")}
 if 'ApiKeys' in t:o['api']=c.execute('select count(*) from ApiKeys').fetchone()[0]
 if 'Users' in t:o['users']=c.execute('select count(*) from Users').fetchone()[0]
 if 'BaseItems' in t:
  o['base']=c.execute('select count(*) from BaseItems').fetchone()[0]
  cols=[r[1] for r in c.execute('pragma table_info(BaseItems)')]
  if 'Name' in cols:
   o['home']=c.execute("select count(*) from BaseItems where lower(Name)='home videos and photos'").fetchone()[0]
   o['wedding']=c.execute("select count(*) from BaseItems where lower(Name)='wedding'").fetchone()[0]
 c.close()
except Exception as e:o['err']=type(e).__name__+':'+str(e)
print(json.dumps(o,separators=(',',':')))
'@
   [IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
   try{$exe=$py.Path;if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){$raw=& $exe -3 $tmp $db}else{$raw=& $exe $tmp $db};if($LASTEXITCODE -eq 0){$m=$raw|ConvertFrom-Json;$api=$m.api;$users=$m.users;$baseItems=$m.base;$home=$m.home;$wedding=$m.wedding;$err=[string]$m.err}else{$err='python_exit_'+$LASTEXITCODE}}catch{$err=$_.Exception.Message}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
 }
 Write-Output ('DB|path='+$db+'|size='+$fi.Length+'|mtime='+$fi.LastWriteTime.ToString('o')+'|apikeys='+$api+'|users='+$users+'|baseitems='+$baseItems+'|homeRows='+$home+'|weddingRows='+$wedding+'|error='+($err -replace '\|','/'))
}
# Read only startup-path lines from newest Jellyfin logs in likely data roots.
$logFiles=New-Object System.Collections.Generic.List[object]
foreach($r in $candidateRoots){if(Test-Path -LiteralPath $r -PathType Container){foreach($f in @(Get-ChildItem -LiteralPath $r -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '(?i)jellyfin.*\.log$|log_.*\.log$|\.log$'}|Sort-Object LastWriteTime -Descending|Select-Object -First 8)){$logFiles.Add($f)}}}
$seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($f in @($logFiles|Sort-Object LastWriteTime -Descending|Select-Object -First 25)){if(-not $seen.Add($f.FullName)){continue};Write-Output ('LOG_FILE|path='+$f.FullName+'|mtime='+$f.LastWriteTime.ToString('o')+'|size='+$f.Length);try{$lines=Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction Stop|Where-Object{$_ -match '(?i)(program data path|data directory|data path|config directory|cache path|log directory|arguments:|command line|jellyfin version|server id|web resources path|application directory)'}|Select-Object -First 40;foreach($ln in $lines){Write-Output ('LOG_PATH_LINE|file='+$f.Name+'|'+(([string]$ln)-replace '\|','/'))}}catch{}}
Write-Output 'FORENSICS_STATUS=PASS'
