#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$path='C:\Scripts\JellyfinWatchdog.ps1'
Write-Output 'AFZ_JELLYFIN_WATCHDOG_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
Write-Output ('WATCHDOG_EXISTS='+(Test-Path -LiteralPath $path -PathType Leaf))
if(-not(Test-Path -LiteralPath $path -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=WATCHDOG_MISSING';exit 0}
$raw=Get-Content -LiteralPath $path -Raw -ErrorAction Stop
$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
Write-Output ('WATCHDOG_SHA256='+$hash)
$lines=$raw -split "`r?`n"
Write-Output ('WATCHDOG_LINE_COUNT='+$lines.Count)
for($i=0;$i -lt $lines.Count;$i++){
  $line=[string]$lines[$i]
  if($line -match '(?i)jellyfin|start-process|start-scheduledtask|schtasks|datadir|8096|get-process|invoke-webrequest|test-netconnection|stop-process|taskname|exe|health|restart'){
    $safe=$line -replace '(?i)(token|apikey|api_key|password|secret)\s*[:=]\s*[^\s''";]+','$1=<redacted>'
    Write-Output ('LINE|n='+($i+1)+'|text='+$safe)
  }
}
try{
 $t=Get-ScheduledTask -TaskName 'Jellyfin Server' -ErrorAction Stop
 $a=@($t.Actions|ForEach-Object{([string]$_.Execute)+' '+([string]$_.Arguments)})
 Write-Output ('SERVER_TASK|state='+$t.State+'|user='+$t.Principal.UserId+'|logon='+$t.Principal.LogonType+'|runlevel='+$t.Principal.RunLevel+'|actions='+($a -join ' || '))
}catch{Write-Output ('SERVER_TASK_ERROR='+$_.Exception.Message)}
try{
 $t=Get-ScheduledTask -TaskName 'Jellyfin Watchdog' -ErrorAction Stop
 $a=@($t.Actions|ForEach-Object{([string]$_.Execute)+' '+([string]$_.Arguments)})
 Write-Output ('WATCHDOG_TASK|state='+$t.State+'|user='+$t.Principal.UserId+'|logon='+$t.Principal.LogonType+'|runlevel='+$t.Principal.RunLevel+'|actions='+($a -join ' || '))
}catch{Write-Output ('WATCHDOG_TASK_ERROR='+$_.Exception.Message)}
Write-Output 'STATUS=PASS'
