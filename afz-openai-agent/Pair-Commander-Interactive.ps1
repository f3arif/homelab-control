#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('windows-main','h3','auto')][string]$Target='auto',
  [string]$PrivateResultRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Control Hub\Commander'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$utf8=New-Object Text.UTF8Encoding($false)
if($Target -eq 'auto'){
  if($env:COMPUTERNAME -eq 'DESKTOP-10SKF0M'){$Target='windows-main'}
  elseif($env:COMPUTERNAME -eq 'DESKTOP-H3R6CQN'){$Target='h3'}
  else{throw "Unsupported host for automatic Commander pairing: $env:COMPUTERNAME"}
}
$expected=if($Target -eq 'windows-main'){'DESKTOP-10SKF0M'}else{'DESKTOP-H3R6CQN'}
if($env:COMPUTERNAME -ne $expected){throw "Wrong host for target=$Target host=$env:COMPUTERNAME expected=$expected"}
if($env:USERNAME -ne 'Faiz'){throw "Commander pairing must run in Faiz interactive profile; user=$env:USERNAME"}

$root=Join-Path $env:LOCALAPPDATA 'AFZ\DesktopCommander'
$log=Join-Path $root ("remote-alt-account-"+$Target+".log")
$localResult=Join-Path $root ("PAIRING-"+$Target.ToUpperInvariant()+"-LATEST.json")
$cloudResult=Join-Path $PrivateResultRoot $(if($Target -eq 'windows-main'){'PAIRING-WINDOWSMAIN-LATEST.json'}else{'PAIRING-H3-LATEST.json'})
$credential=Join-Path $env:USERPROFILE '.desktop-commander-device\device.json'
$task='AFZ Desktop Commander Remote Pairing'
New-Item -ItemType Directory -Force -Path $root | Out-Null

$npx=(Get-Command npx.cmd -ErrorAction Stop|Select-Object -First 1).Source
$oldTask=Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
if($oldTask -and [string]$oldTask.State -eq 'Running'){Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue}
try{
  foreach($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)){
    $cmd=[string]$p.CommandLine
    if($p.ProcessId -ne $PID -and $cmd -match '(?i)@wonderwhy-er/desktop-commander.*remote|desktop-commander.*remote'){
      try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue}catch{}
    }
  }
}catch{}
Start-Sleep -Seconds 2

$logoutOut=(& $npx --yes @wonderwhy-er/desktop-commander@latest remote --logout 2>&1|Out-String).Trim()
if($LASTEXITCODE -ne 0){throw "Desktop Commander official logout failed exit=$LASTEXITCODE"}
if(Test-Path -LiteralPath $credential -PathType Leaf){throw "Commander credential file remained after official logout: $credential"}
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
if($oldTask){Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue}

$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$cmdArgs='/d /s /c ""'+$npx+'" --yes @wonderwhy-er/desktop-commander@latest remote >> "'+$log+'" 2>&1"'
$action=New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $cmdArgs
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force|Out-Null
Start-ScheduledTask -TaskName $task -ErrorAction Stop

$deadline=(Get-Date).AddSeconds(105)
$code=$null
do{
  Start-Sleep -Seconds 2
  if(Test-Path -LiteralPath $log -PathType Leaf){
    $txt=Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
    if($txt){
      $m=[regex]::Match($txt,'(?im)^\s*([A-Z0-9]{4}-[A-Z0-9]{4})\s*$')
      if($m.Success){$code=$m.Groups[1].Value;break}
    }
  }
}while((Get-Date)-lt $deadline)
$taskState=[string](Get-ScheduledTask -TaskName $task -ErrorAction Stop).State
$result=[ordered]@{
  schema=1
  host=$env:COMPUTERNAME
  target=$Target
  status=$(if($code){'AUTHORIZATION_REQUIRED'}else{'NO_DEVICE_CODE'})
  verifyUrl='https://mcp.desktopcommander.app/device/verify'
  deviceCode=$code
  codeExpiresMinutes=$(if($code){15}else{$null})
  oldLocalCredentialsRemoved=(-not(Test-Path -LiteralPath $credential -PathType Leaf))
  taskName=$task
  taskState=$taskState
  generatedAt=(Get-Date -Format o)
}
[IO.File]::WriteAllText($localResult,($result|ConvertTo-Json -Depth 8),$utf8)
try{
  if(Test-Path -LiteralPath (Split-Path $PrivateResultRoot -Parent) -PathType Container){
    New-Item -ItemType Directory -Force -Path $PrivateResultRoot|Out-Null
    [IO.File]::WriteAllText($cloudResult,($result|ConvertTo-Json -Depth 8),$utf8)
  }
}catch{}
$b64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($result|ConvertTo-Json -Depth 8 -Compress)))
Write-Output ('AFZ_COMMANDER_PAIR_RESULT_B64='+$b64)
if(-not $code){exit 2}
