#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "Windows-main only; host=$env:COMPUTERNAME"}
if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\commander-alternate-account-pair.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){return}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
if([int]$req.schema -ne 1 -or [string]$req.status -ne 'ACTIVE' -or [string]$req.action -ne 'pair-alternate-commander-account'){return}
$id=([string]$req.id).Trim()
if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid request id'}
if(-not [bool]$req.windows_main -or -not [bool]$req.h3){throw 'Pairing request must explicitly target windows-main and H3'}
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\commander-alternate-account-pair'
$stateFile=Join-Path $stateRoot ($id+'.json')
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
if(Test-Path -LiteralPath $stateFile -PathType Leaf){
  try{
    $prior=Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$prior.status -in @('launched','completed')){return}
  }catch{}
}
$runner=Join-Path $InstallRoot 'afz-openai-agent\Pair-Commander-Both-Interactive.ps1'
if(-not(Test-Path -LiteralPath $runner -PathType Leaf)){throw "Pairing orchestrator missing: $runner"}
$carrier=Get-ScheduledTask -TaskName 'AFZ Edge Backup' -ErrorAction Stop
if(([string]$carrier.Principal.LogonType) -notmatch 'Interactive'){throw 'AFZ Edge Backup principal is not interactive'}
$user=[string]$carrier.Principal.UserId
if([string]::IsNullOrWhiteSpace($user)){throw 'Interactive carrier user missing'}
$taskName='AFZ Commander Alternate Account OneShot'
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -InstallRoot `"$InstallRoot`""
$trigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds(3))
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 8)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force|Out-Null
Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
$state=[ordered]@{
  schema=1
  requestId=$id
  status='launched'
  taskName=$taskName
  principal=$user
  targets=@('DESKTOP-10SKF0M','DESKTOP-H3R6CQN')
  source='github-post-sync'
  launchedAt=(Get-Date -Format o)
}
[IO.File]::WriteAllText($stateFile,($state|ConvertTo-Json -Depth 8),$utf8)
