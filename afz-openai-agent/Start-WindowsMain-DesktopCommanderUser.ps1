#Requires -Version 5.1
# AFZ_TIMEOUT_SECONDS = 180
[CmdletBinding()]
param(
  [switch]$InstallAutostart
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "WRONG_HOST $($env:COMPUTERNAME)"}

$root=Join-Path $env:LOCALAPPDATA 'AFZ\DesktopCommander'
$log=Join-Path $root 'remote.log'
New-Item -ItemType Directory -Force -Path $root | Out-Null

function DcProcesses {
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ([string]$_.CommandLine) -match '(?i)@wonderwhy-er/desktop-commander.*remote|desktop-commander.*remote'
  })
}

Write-Output '===== AFZ DESKTOP COMMANDER USER RELAUNCH ====='
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output ('COMPUTER='+$env:COMPUTERNAME)
Write-Output ('IDENTITY='+[Security.Principal.WindowsIdentity]::GetCurrent().Name)

$npx=(Get-Command npx.cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if(-not $npx){throw 'NPX_NOT_FOUND'}
Write-Output ('NPX='+$npx)

$before=DcProcesses
Write-Output ('PROCESS_COUNT_BEFORE='+@($before).Count)

if(@($before).Count -eq 0){
  if(Test-Path -LiteralPath $log){Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue}
  $escapedNpx=$npx.Replace('"','""')
  $escapedLog=$log.Replace('"','""')
  $args='/d /s /c ""'+$escapedNpx+'" --yes @wonderwhy-er/desktop-commander@latest remote >> "'+$escapedLog+'" 2>&1"'
  $p=Start-Process -FilePath 'cmd.exe' -ArgumentList $args -WindowStyle Hidden -PassThru
  Write-Output ('LAUNCHER_PID='+$p.Id)
  Write-Output 'LAUNCH_REQUESTED=True'
}else{
  Write-Output 'LAUNCH_REQUESTED=False'
}

$deadline=(Get-Date).AddSeconds(55)
$proc=@()
do{
  Start-Sleep -Seconds 3
  $proc=DcProcesses
  if(@($proc).Count -gt 0){break}
}while((Get-Date) -lt $deadline)

Write-Output ('PROCESS_COUNT_AFTER='+@($proc).Count)
foreach($p in @($proc)){
  Write-Output ('PROCESS_PID='+$p.ProcessId)
  $cl=[string]$p.CommandLine
  if($cl.Length -gt 1000){$cl=$cl.Substring(0,1000)}
  Write-Output ('PROCESS_CMD='+$cl)
}

Start-Sleep -Seconds 10
if(Test-Path -LiteralPath $log){
  $tail=@(Get-Content -LiteralPath $log -Tail 80 -ErrorAction SilentlyContinue)
  Write-Output '--- REMOTE LOG TAIL ---'
  foreach($line in $tail){Write-Output $line}
  Write-Output '--- END REMOTE LOG TAIL ---'
}else{
  Write-Output 'REMOTE_LOG=MISSING'
}

if($InstallAutostart -and @($proc).Count -gt 0){
  $runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  New-Item -Path $runKey -Force | Out-Null
  $cmd='cmd.exe /d /s /c start "" /min "'+$npx+'" --yes @wonderwhy-er/desktop-commander@latest remote'
  New-ItemProperty -Path $runKey -Name 'AFZDesktopCommanderRemote' -PropertyType String -Value $cmd -Force | Out-Null
  Write-Output 'HKCU_AUTOSTART=INSTALLED'
}else{
  Write-Output ('HKCU_AUTOSTART='+(if($InstallAutostart){'NOT_INSTALLED_NO_PROCESS'}else{'NOT_REQUESTED'}))
}

Write-Output '===== END ====='
if(@($proc).Count -gt 0){exit 0}
exit 2
