#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'

$jobId='afz-site-git-cutover-r5-20260828T1151'
$siteSha='c38576741ce2d379723fde038300363429845656'
$piLan='192.168.50.68'
$watcherState='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-site-deploy\request-watcher.json'
$resultFile='C:\Users\Faiz\AppData\Local\AFZ\WebsiteGitDeploy\latest.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-site-deploy'
$stateFile=Join-Path $stateRoot 'r5-orphan-release.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'AFZ-SITE-R5-ORPHAN-RELEASE-LATEST.json'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json}catch{return $null}
}
function Save-State([string]$Status,[string]$Message,[hashtable]$Extra=@{}){
  $o=[ordered]@{
    schema=1;purpose='R5_ORPHAN_SSH_RELEASE';ok=($Status -in @('not-applicable','already-clear','released'))
    status=$Status;jobId=$jobId;expectedSiteSha=$siteSha;message=$Message;computer=$env:COMPUTERNAME;time=(Get-Date -Format o)
  }
  foreach($k in $Extra.Keys){$o[$k]=$Extra[$k]}
  $json=$o|ConvertTo-Json -Depth 8
  Set-Content -LiteralPath $stateFile -Value $json -Encoding UTF8
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){Set-Content -LiteralPath $diagFile -Value $json -Encoding UTF8}}catch{}
}

try{
  if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){
    Save-State 'not-applicable' 'Host is not windows-main; no process action taken.'
    exit 0
  }

  $watch=Read-Json $watcherState
  $exactFailed=($watch -and [string]$watch.status -eq 'failed' -and [string]$watch.jobId -eq $jobId -and ([string]$watch.expectedSiteSha).ToLowerInvariant() -eq $siteSha -and [string]$watch.message -eq 'Carrier task ended without a matching deployment result file.')
  if(-not $exactFailed){
    Save-State 'not-applicable' 'Exact retired R5 failed watcher state is not present; no process action taken.'
    exit 0
  }

  $terminal=Read-Json $resultFile
  if($terminal -and [string]$terminal.jobId -eq $jobId){
    Save-State 'not-applicable' 'A terminal R5 result exists; no process action taken.'
    exit 0
  }

  $all=@(Get-CimInstance Win32_Process -ErrorAction Stop)
  $core=@($all|Where-Object{
    [string]$_.Name -ieq 'powershell.exe' -and
    ([string]$_.CommandLine) -match '(?i)Deploy-AFZ-WebsiteToPi-Core[.]ps1' -and
    ([string]$_.CommandLine) -match [regex]::Escape($jobId) -and
    ([string]$_.CommandLine) -match $siteSha
  })
  if($core.Count -eq 0){
    Save-State 'already-clear' 'No exact R5 deploy core remains alive.'
    exit 0
  }
  if($core.Count -ne 1){
    Save-State 'refused' "Expected exactly one exact R5 deploy core; found $($core.Count)."
    exit 0
  }

  $corePid=[int]$core[0].ProcessId
  $ssh=@($all|Where-Object{
    [string]$_.Name -ieq 'ssh.exe' -and
    [int]$_.ParentProcessId -eq $corePid -and
    ([string]$_.CommandLine) -match [regex]::Escape($piLan) -and
    ([string]$_.CommandLine) -match '(?i)mkdir -p' -and
    ([string]$_.CommandLine) -match [regex]::Escape('/opt/edge/afz-site/git-deploy/stage') -and
    ([string]$_.CommandLine) -match [regex]::Escape('/opt/edge/afz-site/git-deploy/backups')
  })
  if($ssh.Count -eq 0){
    Save-State 'already-clear' 'Exact R5 core remains but its staging SSH child is already gone; parent was not touched.' @{corePid=$corePid}
    exit 0
  }
  if($ssh.Count -ne 1){
    Save-State 'refused' "Expected exactly one exact R5 staging SSH child; found $($ssh.Count)." @{corePid=$corePid}
    exit 0
  }

  $sshPid=[int]$ssh[0].ProcessId
  $created=[Management.ManagementDateTimeConverter]::ToDateTime([string]$ssh[0].CreationDate)
  $age=[math]::Round(((Get-Date)-$created).TotalSeconds,1)
  if($age -lt 120){
    Save-State 'refused' "Exact R5 SSH child is only ${age}s old; minimum release age is 120s." @{corePid=$corePid;sshPid=$sshPid;sshAgeSeconds=$age}
    exit 0
  }

  Stop-Process -Id $sshPid -Force -ErrorAction Stop
  $deadline=(Get-Date).AddSeconds(10)
  do{
    Start-Sleep -Milliseconds 500
    if(-not(Get-Process -Id $sshPid -ErrorAction SilentlyContinue)){break}
  }while((Get-Date) -lt $deadline)
  if(Get-Process -Id $sshPid -ErrorAction SilentlyContinue){throw 'Verified R5 SSH child remained alive after bounded stop.'}

  $coreExitDeadline=(Get-Date).AddSeconds(8)
  do{
    Start-Sleep -Milliseconds 500
    if(-not(Get-Process -Id $corePid -ErrorAction SilentlyContinue)){break}
  }while((Get-Date) -lt $coreExitDeadline)
  $coreStillAlive=[bool](Get-Process -Id $corePid -ErrorAction SilentlyContinue)
  Save-State 'released' 'Stopped only the exact retired R5 staging SSH child; deploy core was not directly stopped.' @{
    corePid=$corePid;sshPid=$sshPid;sshAgeSeconds=$age;sshStopped=$true;coreStillAliveAfterObservation=$coreStillAlive
    carrierTaskTouched=$false;legacySiteTaskTouched=$false;piMutationPerformed=$false
  }
  exit 0
}catch{
  Save-State 'error' $_.Exception.Message
  exit 1
}
