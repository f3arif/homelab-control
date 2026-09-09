#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

$expectedHost='DESKTOP-10SKF0M'
$logRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$logFile=Join-Path $logRoot 'AFZ-WINDOWSMAIN-RECOVERY-LATEST.txt'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

function Log([string]$m){
  $line="$(Get-Date -Format o) $m"
  Write-Host $line
  Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}
function Is-Admin{
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  $p=New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Task-State([string]$name){
  $t=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if($t){return [string]$t.State}
  return 'MISSING'
}
function Start-IfPresent([string]$name){
  $t=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if(-not $t){Log "TASK $name MISSING";return $false}
  if([string]$t.State -ne 'Running'){
    try{Start-ScheduledTask -TaskName $name -ErrorAction Stop;Log "TASK $name START REQUESTED"}catch{Log "TASK $name START FAILED: $($_.Exception.Message)";return $false}
  } else {Log "TASK $name ALREADY RUNNING"}
  return $true
}
function Test-Port([int]$port){
  try{
    $c=New-Object Net.Sockets.TcpClient
    $ar=$c.BeginConnect('127.0.0.1',$port,$null,$null)
    $ok=$ar.AsyncWaitHandle.WaitOne(1500,$false)
    if($ok -and $c.Connected){$c.EndConnect($ar);$c.Close();return $true}
    $c.Close()
  }catch{}
  return $false
}

if($env:COMPUTERNAME -ne $expectedHost){throw "Wrong host: $($env:COMPUTERNAME). Expected $expectedHost."}
if(-not(Is-Admin)){throw 'Run this recovery launcher as Administrator.'}

Set-Content -LiteralPath $logFile -Value '' -Encoding UTF8
Log "BEGIN host=$env:COMPUTERNAME user=$env:USERDOMAIN\$env:USERNAME"
Log "InstallRoot=$InstallRoot"

# Repair canonical AFZ source/tasks from trusted GitHub main.
$tmp=Join-Path $env:TEMP ('AFZ-Update-'+[guid]::NewGuid().ToString('n')+'.ps1')
$uri='https://raw.githubusercontent.com/f3arif/homelab-control/main/afz-openai-agent/Update-AFZ-OpenAI-Agent.ps1'
Log "Downloading canonical updater"
Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $tmp -TimeoutSec 60
$tokens=$null;$parseErrors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ('Updater parse failed: '+(($parseErrors|ForEach-Object{$_.Message}) -join '; '))}
Log "Running canonical updater"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp -InstallRoot $InstallRoot
$code=$LASTEXITCODE
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
if($code -ne 0){throw "Canonical updater failed exit=$code"}
Log "Canonical updater completed"

$serviceTasks=@(
  'AFZ OpenAI Agent Updater',
  'AFZ OpenAI Agent',
  'AFZ OpenAI Agent Control',
  'AFZ OpenAI Agent Push Deploy Watcher'
)
foreach($n in $serviceTasks){[void](Start-IfPresent $n)}

# Restore OpenSSH only if the Windows OpenSSH service is already installed.
$sshd=Get-Service -Name sshd -ErrorAction SilentlyContinue
if($sshd){
  try{
    Set-Service -Name sshd -StartupType Automatic
    if($sshd.Status -ne 'Running'){Start-Service -Name sshd}
    Log "SSHD status=$((Get-Service sshd).Status) startup=Automatic"
  }catch{Log "SSHD repair failed: $($_.Exception.Message)"}
}else{Log 'SSHD service not installed; no package installation performed'}

# Restore existing Desktop Commander remote registration, or create a canonical
# current-user interactive task without changing any authentication material.
$dcTask='AFZ Desktop Commander Remote Pairing'
$existing=Get-ScheduledTask -TaskName $dcTask -ErrorAction SilentlyContinue
if($existing){
  try{
    if([string]$existing.State -eq 'Running'){Stop-ScheduledTask -TaskName $dcTask -ErrorAction SilentlyContinue;Start-Sleep -Seconds 1}
    Start-ScheduledTask -TaskName $dcTask -ErrorAction Stop
    Log 'Desktop Commander existing task restarted'
  }catch{Log "Desktop Commander existing task restart failed: $($_.Exception.Message)"}
}else{
  $npx=(Get-Command npx.cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source
  if(-not $npx){throw 'npx.cmd not found; Node/NPM installation is required before Desktop Commander can run.'}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  $principal=$null
  $trigger=$null
  $owner=''
  if([string]$identity.User.Value -eq 'S-1-5-18'){
    $carrier=Get-ScheduledTask -TaskName 'AFZ Edge Backup' -ErrorAction SilentlyContinue
    if(-not $carrier -or -not $carrier.Principal -or [string]$carrier.Principal.LogonType -notmatch 'Interactive'){
      throw 'Desktop Commander task missing and no interactive AFZ Edge Backup principal is available.'
    }
    $principal=$carrier.Principal
    $owner=[string]$principal.UserId
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $owner
  }else{
    $owner="$env:USERDOMAIN\$env:USERNAME"
    $principal=New-ScheduledTaskPrincipal -UserId $owner -LogonType Interactive -RunLevel Highest
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $owner
  }
  $action=New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/d /s /c ""'+$npx+'" --yes @wonderwhy-er/desktop-commander@latest remote"')
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName $dcTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName $dcTask
  Log "Desktop Commander task created for interactive principal $owner"
}

Start-Sleep -Seconds 12
$dcProc=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  ([string]$_.CommandLine) -match '(?i)desktop-commander.*remote|@wonderwhy-er/desktop-commander'
})
foreach($n in $serviceTasks){Log "FINAL_TASK $n=$(Task-State $n)"}
Log "FINAL_TASK $dcTask=$(Task-State $dcTask)"
Log "LOCAL_8796=$(Test-Port 8796)"
Log "LOCAL_8797=$(Test-Port 8797)"
Log "DESKTOP_COMMANDER_PROCESS_COUNT=$(@($dcProc).Count)"

$ok8796=Test-Port 8796
$ok8797=Test-Port 8797
$dcOk=(@($dcProc).Count -gt 0)
if($ok8796 -and $ok8797 -and $dcOk){
  Log 'RECOVERY_RESULT=PASS'
  exit 0
}
Log "RECOVERY_RESULT=PARTIAL agent8796=$ok8796 control8797=$ok8797 commander=$dcOk"
exit 2
