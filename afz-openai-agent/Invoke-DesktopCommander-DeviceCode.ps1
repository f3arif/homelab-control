#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{2,100}$')]
  [string]$JobId
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$expectedHost='DESKTOP-10SKF0M'
$user='DESKTOP-10SKF0M\Faiz'
$taskName='AFZ Desktop Commander Remote Pairing'
$npx='C:\Program Files\nodejs\npx.cmd'
$logDir='C:\Users\Faiz\AppData\Local\AFZ\DesktopCommander'
$log=Join-Path $logDir 'remote.log'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\desktop-commander-device-code'
$stateFile=Join-Path $stateRoot ($JobId+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'AFZ-DESKTOP-COMMANDER-DEVICE-CODE-LATEST.json'
$verifyUrl='https://mcp.desktopcommander.app/device/verify'

function Save-Result($Object){
  New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
  $json=$Object|ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($stateFile,$json,(New-Object Text.UTF8Encoding($false)))
  if(Test-Path -LiteralPath $diagRoot -PathType Container){
    try{[IO.File]::WriteAllText($diagFile,$json,(New-Object Text.UTF8Encoding($false)))}catch{}
  }
}

if($env:COMPUTERNAME -ne $expectedHost){throw "Wrong host: $($env:COMPUTERNAME)"}
if(-not(Test-Path -LiteralPath $npx -PathType Leaf)){throw "npx launcher missing: $npx"}
New-Item -ItemType Directory -Force -Path $logDir,$stateRoot | Out-Null

$started=Get-Date
$result=[ordered]@{
  schema=1
  jobId=$JobId
  target=$expectedHost
  action='refresh-device-code'
  status='running'
  verifyUrl=$verifyUrl
  deviceCode=$null
  codeExpiresMinutes=$null
  taskName=$taskName
  taskState=$null
  processCount=0
  persistedAutostart=$false
  credentialsChanged=$false
  tailscaleChanged=$false
  firewallChanged=$false
  startedAt=$started.ToString('o')
  finishedAt=$null
  error=$null
}
Save-Result $result

try{
  $existing=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ([string]$_.CommandLine) -match '(?i)@wonderwhy-er/desktop-commander.*remote|desktop-commander.*remote'
  })
  foreach($p in $existing){
    try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue}catch{}
  }
  Start-Sleep -Seconds 2
  Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue

  $taskArgs='/d /s /c ""C:\Program Files\nodejs\npx.cmd" --yes @wonderwhy-er/desktop-commander@latest remote >> "C:\Users\Faiz\AppData\Local\AFZ\DesktopCommander\remote.log" 2>&1"'
  $action=New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $taskArgs
  $trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
  $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

  $deadline=(Get-Date).AddSeconds(150)
  $code=$null
  $connected=$false
  do{
    Start-Sleep -Seconds 2
    if(Test-Path -LiteralPath $log -PathType Leaf){
      $txt=Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
      if($txt){
        $m=[regex]::Match($txt,'(?im)^\s*([A-Z0-9]{4}-[A-Z0-9]{4})\s*$')
        if($m.Success){$code=$m.Groups[1].Value;break}
        if($txt -match '(?i)Connected to Remote MCP' -and $txt -notmatch '(?i)Waiting for authorization|Starting device authorization flow'){
          $connected=$true
        }
      }
    }
  }while((Get-Date) -lt $deadline)

  $procs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ([string]$_.CommandLine) -match '(?i)@wonderwhy-er/desktop-commander.*remote|desktop-commander.*remote'
  })
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  $result.status=$(if($code){'authorization-required'}elseif($connected){'connected'}elseif(@($procs).Count -gt 0){'started-no-code'}else{'failed'})
  $result.deviceCode=$code
  $result.codeExpiresMinutes=$(if($code){15}else{$null})
  $result.taskState=$(if($task){[string]$task.State}else{'MISSING'})
  $result.processCount=@($procs).Count
  $result.persistedAutostart=([bool]$task)
  $result.finishedAt=(Get-Date -Format o)
  Save-Result $result
  $result|ConvertTo-Json -Depth 8 -Compress
  if($code -or $connected){exit 0}
  exit 2
}catch{
  $result.status='failed'
  $result.error=$_.Exception.Message
  $result.finishedAt=(Get-Date -Format o)
  Save-Result $result
  $result|ConvertTo-Json -Depth 8 -Compress
  exit 1
}
