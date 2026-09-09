#Requires -Version 5.1
# AFZ_TIMEOUT_SECONDS = 240
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$expectedHost='DESKTOP-10SKF0M'
if($env:COMPUTERNAME -ne $expectedHost){throw "WRONG_HOST $($env:COMPUTERNAME)"}

$updaterTask='AFZ OpenAI Agent Updater'
$serviceTasks=@(
  'AFZ OpenAI Agent',
  'AFZ OpenAI Agent Control',
  'AFZ OpenAI Agent Push Deploy Watcher'
)
$commanderTask='AFZ Desktop Commander Remote Pairing'
$updateState='C:\ProgramData\AFZ\OpenAIAgent\last-update.json'

function Get-TaskState([string]$Name){
  $t=Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
  if($t){return [string]$t.State}
  return 'MISSING'
}
function Request-TaskStart([string]$Name){
  $t=Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
  if(-not $t){
    Write-Output ("TASK_START_"+($Name -replace ' ','_')+"=MISSING")
    return $false
  }
  try{
    if([string]$t.State -eq 'Running'){
      Write-Output ("TASK_START_"+($Name -replace ' ','_')+"=ALREADY_RUNNING")
    }else{
      Start-ScheduledTask -TaskName $Name -ErrorAction Stop
      Write-Output ("TASK_START_"+($Name -replace ' ','_')+"=REQUESTED")
    }
    return $true
  }catch{
    Write-Output ("TASK_START_"+($Name -replace ' ','_')+"=FAILED:"+$_.Exception.Message)
    return $false
  }
}
function Test-LocalTcp([int]$Port){
  try{
    $c=New-Object Net.Sockets.TcpClient
    $ar=$c.BeginConnect('127.0.0.1',$Port,$null,$null)
    $ok=$ar.AsyncWaitHandle.WaitOne(1500,$false)
    if($ok -and $c.Connected){$c.EndConnect($ar);$c.Close();return $true}
    $c.Close()
  }catch{}
  return $false
}

Write-Output '===== AFZ WINDOWS-MAIN TRUSTED TASK RECOVERY ====='
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output ('COMPUTER='+$env:COMPUTERNAME)
Write-Output ('IDENTITY='+[Security.Principal.WindowsIdentity]::GetCurrent().Name)
foreach($n in @($updaterTask)+$serviceTasks+@($commanderTask)){
  Write-Output ("TASK_BEFORE_"+($n -replace ' ','_')+"="+(Get-TaskState $n))
}

$beforeUpdate=$null
if(Test-Path -LiteralPath $updateState -PathType Leaf){$beforeUpdate=(Get-Item -LiteralPath $updateState).LastWriteTimeUtc}

[void](Request-TaskStart $updaterTask)
$deadline=(Get-Date).AddSeconds(100)
$updateAdvanced=$false
do{
  Start-Sleep -Seconds 2
  if(Test-Path -LiteralPath $updateState -PathType Leaf){
    $fi=Get-Item -LiteralPath $updateState
    if($null -eq $beforeUpdate -or $fi.LastWriteTimeUtc -gt $beforeUpdate){$updateAdvanced=$true;break}
  }
}while((Get-Date) -lt $deadline)
Write-Output ('UPDATER_STATE_ADVANCED='+$updateAdvanced)
if(Test-Path -LiteralPath $updateState -PathType Leaf){
  try{
    $raw=(Get-Content -LiteralPath $updateState -Raw -Encoding UTF8) -replace '[\r\n]+',' '
    if($raw.Length -gt 4000){$raw=$raw.Substring(0,4000)}
    Write-Output ('LAST_UPDATE_JSON='+$raw)
  }catch{Write-Output ('LAST_UPDATE_READ_ERROR='+$_.Exception.Message)}
}

foreach($n in $serviceTasks){[void](Request-TaskStart $n)}
Start-Sleep -Seconds 8

$commander=Get-ScheduledTask -TaskName $commanderTask -ErrorAction SilentlyContinue
if($commander){
  try{
    if([string]$commander.State -eq 'Running'){
      Stop-ScheduledTask -TaskName $commanderTask -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 1
    }
    Start-ScheduledTask -TaskName $commanderTask -ErrorAction Stop
    Write-Output 'COMMANDER_RESTART=REQUESTED'
  }catch{
    Write-Output ('COMMANDER_RESTART=FAILED:'+ $_.Exception.Message)
  }
}else{
  Write-Output 'COMMANDER_RESTART=MISSING_TASK'
}

Start-Sleep -Seconds 12
foreach($n in @($updaterTask)+$serviceTasks+@($commanderTask)){
  Write-Output ("TASK_AFTER_"+($n -replace ' ','_')+"="+(Get-TaskState $n))
}
$port8796=Test-LocalTcp 8796
$port8797=Test-LocalTcp 8797
Write-Output ('LOCAL_8796='+$port8796)
Write-Output ('LOCAL_8797='+$port8797)
$dc=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  ([string]$_.CommandLine) -match '(?i)@wonderwhy-er/desktop-commander|desktop-commander.*remote'
})
Write-Output ('COMMANDER_PROCESS_COUNT='+@($dc).Count)
Write-Output 'CREDENTIALS_CHANGED=False'
Write-Output 'FIREWALL_CHANGED=False'
Write-Output 'TAILSCALE_CHANGED=False'
Write-Output '===== END ====='

if($port8796 -or $port8797 -or @($dc).Count -gt 0){exit 0}
exit 2
