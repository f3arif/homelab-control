#Requires -Version 5.1
# AFZ_TIMEOUT_SECONDS = 120
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "WRONG_HOST $($env:COMPUTERNAME)"}

$root=Join-Path $env:LOCALAPPDATA 'AFZ\DesktopCommander'
$log=Join-Path $root 'remote.log'
New-Item -ItemType Directory -Force -Path $root | Out-Null

$procs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  ([string]$_.CommandLine) -match '(?i)@wonderwhy-er/desktop-commander.*remote|desktop-commander.*remote'
})
Write-Output ('PROCESS_COUNT_BEFORE='+@($procs).Count)
foreach($p in $procs){
  try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue}catch{}
}
Start-Sleep -Seconds 2

if(Test-Path -LiteralPath $log){Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue}
$npx=(Get-Command npx.cmd -ErrorAction Stop | Select-Object -First 1).Source
$escapedNpx=$npx.Replace('"','""')
$escapedLog=$log.Replace('"','""')
$args='/d /s /c ""'+$escapedNpx+'" --yes @wonderwhy-er/desktop-commander@latest remote >> "'+$escapedLog+'" 2>&1"'
$p=Start-Process -FilePath 'cmd.exe' -ArgumentList $args -WindowStyle Hidden -PassThru
Write-Output ('LAUNCHER_PID='+$p.Id)

$deadline=(Get-Date).AddSeconds(55)
$code=$null
$url=$null
do{
  Start-Sleep -Seconds 2
  if(Test-Path -LiteralPath $log){
    $txt=Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
    if($txt){
      $m=[regex]::Match($txt,'(?im)^\s*([A-Z0-9]{4}-[A-Z0-9]{4})\s*$')
      if($m.Success){$code=$m.Groups[1].Value}
      $u=[regex]::Match($txt,'https://mcp\.desktopcommander\.app/device/verify')
      if($u.Success){$url=$u.Value}
      if($code -and $url){break}
    }
  }
}while((Get-Date) -lt $deadline)

Write-Output ('VERIFY_URL='+$url)
Write-Output ('DEVICE_CODE='+$code)
if(Test-Path -LiteralPath $log){
  Write-Output '--- LOG TAIL ---'
  Get-Content -LiteralPath $log -Tail 60
  Write-Output '--- END LOG TAIL ---'
}
if($code){exit 0}
exit 2
