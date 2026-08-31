#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId
)

$ErrorActionPreference='Stop'
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha required'}
if($JobId -ne 'qwen35b-a3b-website-20260830-r1'){throw "Unexpected 35B benchmark JobId: $JobId"}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()

$principalSourceTask='AFZ Edge Backup'
$dedicatedTaskName='AFZ H3 Qwen35B A3B Transport'
$helper='C:\AFZ\homelab-control\afz-openai-agent\tools\Run-WindowsMain-H3-Qwen35BA3B-Carrier.ps1'
$helperResult='C:\Users\Faiz\AppData\Local\AFZ\H3Qwen35BA3BCarrier\'+$JobId+'.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-a3b-bootstrap'
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
    model='qwen3.6:35b-a3b'
    context=16384
    maxModelCalls=1
    transport='github-exact-sha+dedicated-windows-interactive-task+wake+strict-ssh-stdin+dedicated-h3-interactive-task'
    expectedSha=$ExpectedSha
    principalSourceTask=$principalSourceTask
    transportTask=$dedicatedTaskName
    updatedAt=(Get-Date -Format o)
  }
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  [IO.File]::WriteAllText($stateFile,($o|ConvertTo-Json -Depth 20 -Compress),$utf8)
}

$created=$false
try{
  if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only bootstrap; host=$env:COMPUTERNAME"}
  if(-not(Test-Path -LiteralPath $helper -PathType Leaf)){throw "35B carrier helper missing: $helper"}

  # Reuse only the proven Interactive principal identity; never mutate AFZ Edge Backup.
  $sourceTask=Get-ScheduledTask -TaskName $principalSourceTask -ErrorAction SilentlyContinue
  if(-not $sourceTask){throw "Interactive principal source task not found: $principalSourceTask"}
  $principal=$sourceTask.Principal
  if(-not $principal -or [string]::IsNullOrWhiteSpace([string]$principal.UserId)){throw "$principalSourceTask has no usable principal UserId."}
  if(([string]$principal.LogonType) -notmatch 'Interactive'){throw "$principalSourceTask principal is not Interactive; logonType=$([string]$principal.LogonType)"}

  $existing=Get-ScheduledTask -TaskName $dedicatedTaskName -ErrorAction SilentlyContinue
  if($existing -and $existing.State -eq 'Running'){throw "$dedicatedTaskName is already running; refusing duplicate transport."}

  Remove-Item -LiteralPath $helperResult -Force -ErrorAction SilentlyContinue
  Save-State 'running' 'Launching guarded 35B benchmark through dedicated windows-main Interactive transport.'

  $argLine="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$helper`" -ExpectedSha `"$ExpectedSha`" -JobId `"$JobId`""
  $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName $dedicatedTaskName -Action $action -Principal $principal -Settings $settings -Force|Out-Null
  $created=$true
  Start-ScheduledTask -TaskName $dedicatedTaskName

  $deadline=(Get-Date).AddMinutes(6)
  do{
    Start-Sleep -Seconds 2
    $r=Read-Json $helperResult
    if($r -and [string]$r.jobId -eq $JobId -and [string]$r.expectedSha -eq $ExpectedSha -and [string]$r.status -in @('completed','failed')){break}
    $current=Get-ScheduledTask -TaskName $dedicatedTaskName -ErrorAction SilentlyContinue
    if($current -and $current.State -ne 'Running' -and $r){break}
  }while((Get-Date) -lt $deadline)

  $r=Read-Json $helperResult
  if(-not $r){
    $info=Get-ScheduledTaskInfo -TaskName $dedicatedTaskName -ErrorAction SilentlyContinue
    throw "35B Interactive transport ended without result: $helperResult lastResult=$([string]$info.LastTaskResult)"
  }
  if([string]$r.jobId -ne $JobId -or [string]$r.expectedSha -ne $ExpectedSha){throw '35B transport result does not match exact job/SHA.'}
  if(-not [bool]$r.ok -or [string]$r.status -ne 'completed'){throw ('35B transport failed: '+[string]$r.message)}

  Save-State 'completed' 'H3 35B guarded runner state proved through dedicated transport.' $r
  Write-Output ('AFZ_QWEN35B_BOOTSTRAP_JSON='+((Get-Content $stateFile -Raw|ConvertFrom-Json)|ConvertTo-Json -Depth 20 -Compress))
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
