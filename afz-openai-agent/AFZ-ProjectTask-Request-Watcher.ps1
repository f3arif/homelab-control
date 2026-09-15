#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalMilliseconds=750
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$IntervalMilliseconds=[math]::Max(250,[math]::Min($IntervalMilliseconds,5000))

$stateRoot='C:\ProgramData\AFZ\ProjectExecution'
$stateFile=Join-Path $stateRoot 'latest.json'
$pendingFile=Join-Path $stateRoot 'pending.json'
$resultFile=Join-Path $stateRoot 'result.json'
$historyRoot=Join-Path $stateRoot 'history'
$logFile=Join-Path $stateRoot 'watcher.log'
$sourceState='C:\ProgramData\AFZ\OpenAIAgent\source-state.json'
$requestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\project-task.json'
$routerFile=Join-Path $InstallRoot 'afz-openai-agent\control\project-execution-router.json'
$commanderPairing=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-WindowsMain-DesktopCommanderRemote.ps1'
$userTaskName='AFZ Hermes Project Task User Action'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagJson=Join-Path $diagRoot 'AFZ-PROJECT-EXECUTION-LATEST.json'
$diagText=Join-Path $diagRoot 'AFZ-OTHER-ACCOUNT-PROJECT-EXECUTION-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot,$historyRoot | Out-Null

function Log([string]$Message){try{Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8}catch{}}
function Get-Prop($Object,[string]$Name,$Default=$null){if($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name){return $Object.$Name};return $Default}
function Read-JsonFile([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return $null}}
function Current-Sha{$s=Read-JsonFile $sourceState;if($s -and ([string](Get-Prop $s 'remoteSha' '')) -match '^[0-9a-fA-F]{40}$'){return ([string]$s.remoteSha).Trim().ToLowerInvariant()};return ''}
function Is-TerminalStatus([string]$Status){return $Status -in @('completed','validation_failed','commander_fallback_ready','review_required','refused','failed')}
function Get-NextText([string]$Status){
  switch($Status){
    'completed' {return 'Continue from the verified result; commit/push through the approved GitHub path if still required.'}
    'validation_failed' {return 'Review the Hermes changes and validation output before any second executor touches the worktree.'}
    'commander_fallback_ready' {return 'Use Desktop Commander for this same request. Re-pair/change Commander account only if the current Commander connection is unavailable or quota-blocked.'}
    'review_required' {return 'Inspect live Git/worktree state first. Do not run Commander or another agent until partial Hermes changes are understood.'}
    'refused' {return 'Correct the request contract or source-SHA mismatch, then submit a new request_id.'}
    'failed' {return 'Inspect the failure classification and submit a new request_id after correcting the precondition.'}
    default {return 'Hermes execution is in progress; read the next result envelope before issuing duplicate work.'}
  }
}
function Write-Mirror($State){
  try{
    if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){return}
    $request=Get-Prop $State 'request' $null;$result=Get-Prop $State 'result' $null
    $safeResult=$null
    if($result){
      $safeResult=[ordered]@{
        ok=[bool](Get-Prop $result 'ok' $false)
        status=[string](Get-Prop $result 'status' '')
        classification=[string](Get-Prop $result 'classification' '')
        worker=[string](Get-Prop $result 'worker' '')
        route=[string](Get-Prop $result 'route' '')
        mutationStarted=[bool](Get-Prop $result 'mutationStarted' $false)
        projectRoot=[string](Get-Prop $result 'projectRoot' '')
        preGit=Get-Prop $result 'preGit' $null
        postGit=Get-Prop $result 'postGit' $null
        validation=Get-Prop $result 'validation' $null
        message=[string](Get-Prop $result 'message' '')
        time=[string](Get-Prop $result 'time' '')
      }
    }
    $mirror=[ordered]@{
      schema=1
      purpose='CROSS_CHAT_CONTINUATION_DIAGNOSTIC_ONLY'
      controlPlane='github+direct-fabric'
      source='windows-main'
      requestId=[string](Get-Prop $State 'requestId' '')
      status=[string](Get-Prop $State 'status' '')
      route=[string](Get-Prop $State 'route' '')
      sourceSha=[string](Get-Prop $State 'sourceSha' '')
      resumeKey=$(if($request){[string](Get-Prop $request 'resume_key' '')}else{''})
      project=$(if($request){[string](Get-Prop $request 'project' '')}else{''})
      projectRoot=$(if($request){[string](Get-Prop $request 'project_root' '')}else{''})
      task=$(if($request){[string](Get-Prop $request 'task' '')}else{''})
      crossChatNote=$(if($request){[string](Get-Prop $request 'cross_chat_note' '')}else{''})
      result=$safeResult
      next=(Get-NextText ([string](Get-Prop $State 'status' '')))
      updatedAt=[string](Get-Prop $State 'updatedAt' '')
    }
    $json=$mirror|ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($diagJson,$json,$utf8)
    $lines=@(
      'AFZ_PROJECT_EXECUTION_CROSS_CHAT',
      'PURPOSE=CROSS_CHAT_CONTINUATION_DIAGNOSTIC_ONLY',
      'RESUME_KEY='+[string]$mirror.resumeKey,
      'REQUEST_ID='+[string]$mirror.requestId,
      'STATUS='+[string]$mirror.status,
      'ROUTE='+[string]$mirror.route,
      'SOURCE_SHA='+[string]$mirror.sourceSha,
      'PROJECT='+[string]$mirror.project,
      'PROJECT_ROOT='+[string]$mirror.projectRoot,
      'RESULT_CLASSIFICATION='+$(if($safeResult){[string]$safeResult.classification}else{''}),
      'MUTATION_STARTED='+$(if($safeResult){[string]$safeResult.mutationStarted}else{'False'}),
      'NEXT='+[string]$mirror.next,
      'CANONICAL_GITHUB_HANDOFF=afz-openai-agent/control/AFZ-PROJECT-EXECUTION-HANDOFF-LATEST.md',
      'UPDATED_AT='+[string]$mirror.updatedAt
    )
    [IO.File]::WriteAllText($diagText,($lines -join "`r`n"),$utf8)
  }catch{}
}
function Save-State([string]$RequestId,[string]$Status,[string]$Route,[string]$Message,$Request=$null,$Result=$null){
  $o=[ordered]@{schema=1;ok=($Status -eq 'completed');requestId=$RequestId;status=$Status;route=$Route;message=$Message;sourceSha=(Current-Sha);request=$Request;result=$Result;updatedAt=(Get-Date -Format o)}
  $json=$o|ConvertTo-Json -Depth 24
  [IO.File]::WriteAllText($stateFile,$json,$utf8)
  if(Is-TerminalStatus $Status){try{[IO.File]::WriteAllText((Join-Path $historyRoot ($RequestId+'.json')),$json,$utf8)}catch{}}
  Write-Mirror $o
  return $o
}
function Valid-Request($r){
  if(-not $r){return $false};try{if([int](Get-Prop $r 'schema' 0) -ne 1){return $false}}catch{return $false}
  if([string](Get-Prop $r 'status' '') -ne 'ACTIVE'){return $false}
  if(([string](Get-Prop $r 'request_id' '')) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){return $false}
  if(([string](Get-Prop $r 'project' '')) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,100}$'){return $false}
  $task=[string](Get-Prop $r 'task' '');if([string]::IsNullOrWhiteSpace($task) -or $task.Length -gt 16000){return $false}
  $route=([string](Get-Prop $r 'force_route' 'auto')).ToLowerInvariant();if($route -notin @('auto','hermes','commander')){return $false}
  $affinity=([string](Get-Prop $r 'worker_affinity' 'auto')).ToLowerInvariant();if($affinity -notin @('auto','windows-main')){return $false}
  $profile=([string](Get-Prop $r 'validation_profile' 'git-status')).ToLowerInvariant();if($profile -notin @('none','git-status','android','dotnet','node','python')){return $false}
  $expected=([string](Get-Prop $r 'expected_source_sha' '')).Trim();if($expected -and $expected -notmatch '^[0-9a-fA-F]{40}$'){return $false}
  return $true
}
function Resolve-Route($Request,$Router){
  $forced=([string](Get-Prop $Request 'force_route' 'auto')).ToLowerInvariant()
  if($forced -in @('hermes','commander')){return $forced}
  $default=([string](Get-Prop $Router 'default_route' 'hermes')).ToLowerInvariant()
  if($default -notin @('hermes','commander')){$default='hermes'}
  return $default
}
function Maybe-LaunchCommanderPairing($Request,[string]$Sha){
  if(-not [bool](Get-Prop $Request 'launch_commander_pairing' $false)){return $null}
  if(-not(Test-Path -LiteralPath $commanderPairing -PathType Leaf)){return [ordered]@{ok=$false;status='pairing-launcher-missing'}}
  $jobId=([string](Get-Prop $Request 'request_id' 'project-task'));if($jobId.Length -gt 80){$jobId=$jobId.Substring(0,80)}
  try{
    $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $commanderPairing -ExpectedSha $Sha -JobId $jobId 2>&1|Out-String).Trim();$code=$LASTEXITCODE
    return [ordered]@{ok=($code -eq 0);status=$(if($code -eq 0){'pairing-launch-started'}else{'pairing-launch-failed'});exit=$code;output=$raw}
  }catch{return [ordered]@{ok=$false;status='pairing-launch-exception';error=$_.Exception.Message}}
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZProjectTaskRequestWatcher');$locked=$false
try{
  $locked=$mutex.WaitOne(0);if(-not $locked){exit 0}
  Log "START intervalMs=$IntervalMilliseconds typed=true hermes=file-sandbox+fixed-validation commander=fallback arbitraryShell=false"
  while($true){
    try{
      $request=Read-JsonFile $requestFile
      if(-not(Valid-Request $request)){Start-Sleep -Milliseconds $IntervalMilliseconds;continue}
      $requestId=[string]$request.request_id
      $current=Current-Sha
      if($current -notmatch '^[0-9a-f]{40}$'){Save-State $requestId 'refused' 'none' 'Deployed source SHA unavailable; refusing project task.' $request $null|Out-Null;Start-Sleep -Milliseconds $IntervalMilliseconds;continue}
      $expected=([string](Get-Prop $request 'expected_source_sha' '')).Trim().ToLowerInvariant()
      if($expected -and $expected -ne $current){Save-State $requestId 'refused' 'none' "Source SHA mismatch actual=$current expected=$expected" $request $null|Out-Null;Start-Sleep -Milliseconds $IntervalMilliseconds;continue}
      $prior=Read-JsonFile $stateFile
      if($prior -and [string](Get-Prop $prior 'requestId' '') -eq $requestId){
        $priorStatus=[string](Get-Prop $prior 'status' '')
        if(Is-TerminalStatus $priorStatus){Start-Sleep -Milliseconds $IntervalMilliseconds;continue}
        if($priorStatus -in @('dispatched','running')){
          $result=Read-JsonFile $resultFile
          if($result -and [string](Get-Prop $result 'requestId' '') -eq $requestId){
            if([bool](Get-Prop $result 'ok' $false)){
              Save-State $requestId 'completed' 'hermes' 'Hermes task completed and fixed validation passed.' $request $result|Out-Null;Log "COMPLETE request=$requestId";Start-Sleep -Milliseconds $IntervalMilliseconds;continue
            }
            $mutation=[bool](Get-Prop $result 'mutationStarted' $false)
            $router=Read-JsonFile $routerFile
            $fallback=Get-Prop $router 'fallback' $null
            $autoPre=[bool](Get-Prop $fallback 'auto_on_pre_execution_failure' $true)
            if(-not $mutation -and $autoPre){
              $pair=Maybe-LaunchCommanderPairing $request $current
              $result|Add-Member -NotePropertyName commanderPairing -NotePropertyValue $pair -Force
              Save-State $requestId 'commander_fallback_ready' 'commander' 'Hermes failed before project mutation; Commander fallback is safe.' $request $result|Out-Null;Log "FALLBACK request=$requestId classification=$([string](Get-Prop $result 'classification' ''))";Start-Sleep -Milliseconds $IntervalMilliseconds;continue
            }
            $status=$(if([string](Get-Prop $result 'status' '') -eq 'validation_failed'){'validation_failed'}else{'review_required'})
            Save-State $requestId $status 'hermes' 'Hermes may have changed the project; second-executor fallback is blocked until worktree review.' $request $result|Out-Null;Log "REVIEW_REQUIRED request=$requestId";Start-Sleep -Milliseconds $IntervalMilliseconds;continue
          }
          Start-Sleep -Milliseconds $IntervalMilliseconds;continue
        }
      }

      $router=Read-JsonFile $routerFile;if(-not $router){Save-State $requestId 'failed' 'none' 'Execution router config missing or invalid.' $request $null|Out-Null;Start-Sleep -Milliseconds $IntervalMilliseconds;continue}
      $route=Resolve-Route $request $router
      if($route -eq 'commander'){
        $pair=Maybe-LaunchCommanderPairing $request $current
        $result=[ordered]@{schema=1;ok=$true;status='commander_fallback_ready';classification='COMMANDER_ROUTE_SELECTED';requestId=$requestId;route='commander';worker='external-desktop-commander';mutationStarted=$false;pairing=$pair;message='Commander route selected. Use the connected Commander account, or re-pair if explicitly requested.';time=(Get-Date -Format o)}
        Save-State $requestId 'commander_fallback_ready' 'commander' 'Commander route selected by request/router.' $request $result|Out-Null;Log "COMMANDER request=$requestId";Start-Sleep -Milliseconds $IntervalMilliseconds;continue
      }

      $envelope=[ordered]@{}
      foreach($p in $request.PSObject.Properties){$envelope[$p.Name]=$p.Value}
      $envelope['source_sha']=$current
      [IO.File]::WriteAllText($pendingFile,($envelope|ConvertTo-Json -Depth 20 -Compress),$utf8)
      Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
      $task=Get-ScheduledTask -TaskName $userTaskName -ErrorAction SilentlyContinue
      if(-not $task){
        $result=[ordered]@{schema=1;ok=$false;status='failed';classification='PRE_EXECUTION_HERMES_USER_TASK_MISSING';requestId=$requestId;route='hermes';worker='windows-main';mutationStarted=$false;message='Hermes user-context task is not installed.';time=(Get-Date -Format o)}
        Save-State $requestId 'commander_fallback_ready' 'commander' 'Hermes user task missing before mutation; Commander fallback is safe.' $request $result|Out-Null;Start-Sleep -Milliseconds $IntervalMilliseconds;continue
      }
      Save-State $requestId 'dispatched' 'hermes' 'Hermes user-context project task dispatched.' $request $null|Out-Null
      Start-ScheduledTask -TaskName $userTaskName -ErrorAction Stop
      Log "DISPATCH request=$requestId sha=$current"
    }catch{
      Log "ERROR $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds $IntervalMilliseconds
  }
}finally{if($locked){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
