#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId
)

$ErrorActionPreference='Stop'
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha required'}
if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid JobId'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()

$principalSourceTask='AFZ Edge Backup'
$dedicatedTaskName='AFZ H3 Qwen Ridge16K Transport'
$helper='C:\AFZ\homelab-control\afz-openai-agent\tools\Run-WindowsMain-H3-QwenRidge16K-Carrier.ps1'
$helperResult='C:\Users\Faiz\AppData\Local\AFZ\H3QwenRidge16KCarrier\'+$JobId+'.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwenridge16k-bootstrap'
$stateFile=Join-Path $stateRoot 'latest.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path)){return $null};try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return $null}}
function Save-State([string]$Status,[string]$Message,$Extra=$null){
  $o=[ordered]@{
    ok=($Status -eq 'completed')
    status=$Status
    message=$Message
    jobId=$JobId
    target='DESKTOP-H3R6CQN'
    transport='github-exact-sha+dedicated-windows-interactive-task+strict-ssh+detached-H3'
    expectedSha=$ExpectedSha
    principalSourceTask=$principalSourceTask
    transportTask=$dedicatedTaskName
    updatedAt=(Get-Date -Format o)
  }
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  [IO.File]::WriteAllText($stateFile,($o|ConvertTo-Json -Depth 12 -Compress),$utf8)
}

$created=$false
try{
  if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only bootstrap; host=$env:COMPUTERNAME"}
  if(-not(Test-Path -LiteralPath $helper -PathType Leaf)){throw "Interactive carrier helper missing: $helper"}

  # AFZ Edge Backup is used only as a proven source of the existing Interactive
  # user principal. It is never stopped, changed, enabled, disabled, or borrowed.
  $sourceTask=Get-ScheduledTask -TaskName $principalSourceTask -ErrorAction SilentlyContinue
  if(-not $sourceTask){throw "Interactive principal source task not found: $principalSourceTask"}
  $principal=$sourceTask.Principal
  if(-not $principal -or [string]::IsNullOrWhiteSpace([string]$principal.UserId)){
    throw "$principalSourceTask has no usable principal UserId."
  }
  if(([string]$principal.LogonType) -notmatch 'Interactive'){
    throw "$principalSourceTask principal is not Interactive; logonType=$([string]$principal.LogonType)"
  }

  $existing=Get-ScheduledTask -TaskName $dedicatedTaskName -ErrorAction SilentlyContinue
  if($existing -and $existing.State -eq 'Running'){
    throw "$dedicatedTaskName is already running; refusing a duplicate transport launch."
  }

  Remove-Item -LiteralPath $helperResult -Force -ErrorAction SilentlyContinue
  Save-State 'running' 'Launching Ridge16K through a dedicated triggerless windows-main Interactive task; shared AFZ Edge Backup is untouched.'

  $argLine="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$helper`" -ExpectedSha `"$ExpectedSha`" -JobId `"$JobId`""
  $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName $dedicatedTaskName -Action $action -Principal $principal -Settings $settings -Force|Out-Null
  $created=$true
  Start-ScheduledTask -TaskName $dedicatedTaskName

  $deadline=(Get-Date).AddMinutes(4)
  do{
    Start-Sleep -Seconds 2
    $r=Read-Json $helperResult
    if($r -and [string]$r.jobId -eq $JobId -and [string]$r.expectedSha -eq $ExpectedSha -and [string]$r.status -in @('running','completed','failed')){break}
    $current=Get-ScheduledTask -TaskName $dedicatedTaskName -ErrorAction SilentlyContinue
    if($current -and $current.State -ne 'Running' -and $r){break}
  }while((Get-Date) -lt $deadline)

  $r=Read-Json $helperResult
  if(-not $r){
    $info=Get-ScheduledTaskInfo -TaskName $dedicatedTaskName -ErrorAction SilentlyContinue
    throw "Dedicated Interactive transport ended without result: $helperResult lastResult=$([string]$info.LastTaskResult)"
  }
  if([string]$r.jobId -ne $JobId -or [string]$r.expectedSha -ne $ExpectedSha){throw 'Dedicated Interactive transport result does not match this exact job/SHA.'}
  if(-not [bool]$r.ok -or [string]$r.status -notin @('running','completed')){throw ('Dedicated Interactive transport failed: '+[string]$r.message)}

  Save-State 'completed' 'H3 Ridge16K detached runner launch proved through a dedicated windows-main Interactive transport task.' $r
  Write-Output ('AFZ_QWENRIDGE16K_BOOTSTRAP_JSON='+((Get-Content $stateFile -Raw|ConvertFrom-Json)|ConvertTo-Json -Depth 12 -Compress))
}catch{
  $msg=$_.Exception.Message
  Save-State 'failed' $msg
  Write-Error $msg
  exit 1
}finally{
  if($created){
    try{
      $task=Get-ScheduledTask -TaskName $dedicatedTaskName -ErrorAction SilentlyContinue
      if($task -and $task.State -ne 'Running'){
        Unregister-ScheduledTask -TaskName $dedicatedTaskName -Confirm:$false -ErrorAction SilentlyContinue
      }
    }catch{}
  }
}
