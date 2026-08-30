#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
function Safe([object]$v){if($null -eq $v){return ''};return ([string]$v).Replace("`r",' ').Replace("`n",' ')}
Write-Output 'AFZ_JELLYFIN_RESTART_PREFLIGHT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
$procs=@(Get-CimInstance Win32_Process -Filter "Name='jellyfin.exe'" -ErrorAction SilentlyContinue)
Write-Output ('JELLYFIN_PROCESS_COUNT='+$procs.Count)
foreach($p in $procs){
  $owner='';try{$o=Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop;$owner=(($o.Domain+'\'+$o.User).Trim('\'))}catch{}
  $parent=Get-CimInstance Win32_Process -Filter ("ProcessId="+[int]$p.ParentProcessId) -ErrorAction SilentlyContinue
  Write-Output ('JELLYFIN|pid='+$p.ProcessId+'|parentPid='+$p.ParentProcessId+'|session='+$p.SessionId+'|owner='+(Safe $owner)+'|exe='+(Safe $p.ExecutablePath)+'|cmd='+(Safe $p.CommandLine))
  if($parent){Write-Output ('PARENT|pid='+$parent.ProcessId+'|name='+(Safe $parent.Name)+'|exe='+(Safe $parent.ExecutablePath)+'|cmd='+(Safe $parent.CommandLine))}
}
$ff=@(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue)
Write-Output ('FFMPEG_PROCESS_COUNT='+$ff.Count)
foreach($p in $ff){Write-Output ('FFMPEG|pid='+$p.ProcessId+'|parentPid='+$p.ParentProcessId+'|session='+$p.SessionId)}
$services=@(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue|Where-Object {$_.Name -match '(?i)jellyfin' -or $_.DisplayName -match '(?i)jellyfin' -or $_.PathName -match '(?i)jellyfin'})
Write-Output ('JELLYFIN_SERVICE_COUNT='+$services.Count)
foreach($s in $services){Write-Output ('SERVICE|name='+(Safe $s.Name)+'|display='+(Safe $s.DisplayName)+'|state='+(Safe $s.State)+'|startMode='+(Safe $s.StartMode)+'|path='+(Safe $s.PathName))}
$tasks=@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object { $_.TaskName -match '(?i)jellyfin' -or (@($_.Actions)|Where-Object {([string]$_.Execute+' '+[string]$_.Arguments) -match '(?i)jellyfin'}) })
Write-Output ('JELLYFIN_TASK_COUNT='+$tasks.Count)
foreach($t in $tasks){
  $a=@($t.Actions|ForEach-Object {([string]$_.Execute+' '+[string]$_.Arguments).Trim()}) -join ' || '
  Write-Output ('TASK|name='+(Safe $t.TaskName)+'|path='+(Safe $t.TaskPath)+'|state='+(Safe $t.State)+'|user='+(Safe $t.Principal.UserId)+'|logon='+(Safe $t.Principal.LogonType)+'|actions='+(Safe $a))
}
foreach($key in @(
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
  'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
)){
  if(Test-Path $key){
    try{$v=Get-ItemProperty -LiteralPath $key;foreach($p in $v.PSObject.Properties){if($p.Name -notmatch '^PS' -and ([string]$p.Value) -match '(?i)jellyfin'){Write-Output ('AUTORUN|key='+(Safe $key)+'|name='+(Safe $p.Name)+'|value='+(Safe $p.Value))}}}catch{}
  }
}
try{$tcp=@(Get-NetTCPConnection -LocalPort 8096 -State Listen -ErrorAction SilentlyContinue);foreach($c in $tcp){Write-Output ('LISTENER|address='+$c.LocalAddress+'|port='+$c.LocalPort+'|pid='+$c.OwningProcess)}}catch{}
try{$pub=Invoke-RestMethod -Uri 'http://127.0.0.1:8096/System/Info/Public' -TimeoutSec 8;Write-Output ('SERVER|name='+$pub.ServerName+'|version='+$pub.Version+'|id='+$pub.Id)}catch{Write-Output ('SERVER_ERROR|'+$_.Exception.Message)}
Write-Output 'PREFLIGHT_STATUS=PASS'
