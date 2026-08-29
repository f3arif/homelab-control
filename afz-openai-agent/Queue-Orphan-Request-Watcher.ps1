#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalSeconds=5
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$IntervalSeconds=[math]::Max(3,[math]::Min($IntervalSeconds,30))

$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\queue-orphan-remediation'
$stateFile=Join-Path $stateRoot 'request-watcher.json'
$logFile=Join-Path $stateRoot 'request-watcher.log'
$sourceState='C:\ProgramData\AFZ\OpenAIAgent\source-state.json'
$runner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-AFZ-Queue-Orphan-Remediation.ps1'
$requestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\queue-orphan-remediation.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'AFZ-QUEUE-ORPHAN-REMEDIATION-LATEST.txt'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Log([string]$Message){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8}
function Read-JsonFile([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop|ConvertFrom-Json}catch{return $null}}
function Current-Sha{$s=Read-JsonFile $sourceState;if($s -and ([string]$s.remoteSha) -match '^[0-9a-fA-F]{40}$'){return ([string]$s.remoteSha).Trim().ToLowerInvariant()};return ''}
function Get-State{return Read-JsonFile $stateFile}
function Save-State([string]$RequestId,[string]$Status,[string]$Message,[string]$TaskId,$Audit=$null,$Apply=$null,$Post=$null){
  $o=[ordered]@{ok=($Status -in @('idle','completed','no-op'));requestId=$RequestId;status=$Status;message=$Message;sourceSha=(Current-Sha);taskId=$TaskId;transport='atomic-local-request-from-exact-github-source';intervalSeconds=$IntervalSeconds;audit=$Audit;apply=$Apply;postAudit=$Post;updatedAt=(Get-Date -Format o)}
  $o|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $stateFile -Encoding UTF8
  return $o
}
function Save-Diagnostic($State){
  try{
    if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){return}
    $audit=$State.audit;$apply=$State.apply;$post=$State.postAudit
    $lines=@(
      'AFZ_QUEUE_ORPHAN_REMEDIATION',
      'PURPOSE=EMERGENCY_DIAGNOSTIC_ACK_ONLY',
      'CONTROL_PLANE=github',
      'SOURCE=windows-main',
      ('REQUEST_ID='+[string]$State.requestId),
      ('STATUS='+[string]$State.status),
      ('MESSAGE='+[string]$State.message),
      ('SOURCE_SHA='+[string]$State.sourceSha),
      ('TASK_ID='+[string]$State.taskId),
      ('AUDIT_DIAGNOSIS='+$(if($audit){[string]$audit.diagnosis}else{''})),
      ('AUDIT_LIVE='+$(if($audit -and $audit.counts){[string]$audit.counts.liveExecutors}else{''})),
      ('AUDIT_TERMINAL='+$(if($audit -and $audit.counts){[string]$audit.counts.terminal}else{''})),
      ('AUDIT_MOVABLE='+$(if($audit -and $audit.counts){[string]$audit.counts.movable}else{''})),
      ('JANITOR_STATE='+$(if($audit -and $audit.janitor){[string]$audit.janitor.state}else{''})),
      ('JANITOR_LAST_RESULT='+$(if($audit -and $audit.janitor){[string]$audit.janitor.lastResult}else{''})),
      ('APPLY_OK='+$(if($apply){[string]$apply.ok}else{''})),
      ('APPLY_QUARANTINED='+$(if($apply -and $apply.quarantinedArtifacts){[string]@($apply.quarantinedArtifacts).Count}else{'0'})),
      ('APPLY_DELETED_FILES='+$(if($apply -and $apply.safety){[string]$apply.safety.deletedFiles}else{''})),
      ('APPLY_TERMINAL_RESULT_MOVED='+$(if($apply -and $apply.safety){[string]$apply.safety.terminalResultMoved}else{''})),
      ('POST_DIAGNOSIS='+$(if($post){[string]$post.diagnosis}else{''})),
      ('POST_MOVABLE='+$(if($post -and $post.counts){[string]$post.counts.movable}else{''})),
      ('UPDATED_AT='+[string]$State.updatedAt)
    )
    [IO.File]::WriteAllText($diagFile,($lines -join "`r`n"),(New-Object Text.UTF8Encoding($false)))
  }catch{}
}
function Get-LocalRequest{return Read-JsonFile $requestFile}
function Valid-Request($r){
  if(-not $r){return $false};try{if([int]$r.schema -ne 1){return $false}}catch{return $false}
  if([string]$r.project -ne 'ops'){return $false}
  if([string]$r.action -ne 'audit-then-quarantine-proven-orphan'){return $false}
  if(([string]$r.request_id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,100}$'){return $false}
  if(([string]$r.task_id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,180}$'){return $false}
  if($r.PSObject.Properties.Name -notcontains 'enabled' -or [bool]$r.enabled -ne $true){return $false}
  return $true
}
function Invoke-Runner([string]$Action,[string]$TaskId){
  if(-not(Test-Path -LiteralPath $runner -PathType Leaf)){throw "Queue remediation runner missing: $runner"}
  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -Action $Action -TaskId $TaskId 2>&1|Out-String).Trim();$code=$LASTEXITCODE
  if($code -ne 0){throw "Runner action=$Action failed exit=$code output=$raw"}
  if([string]::IsNullOrWhiteSpace($raw)){throw "Runner action=$Action returned empty output"}
  try{return $raw|ConvertFrom-Json}catch{throw "Runner action=$Action returned invalid JSON"}
}
function Is-TerminalWatcherStatus([string]$Status){return $Status -in @('completed','no-op','refused','failed')}

$mutex=New-Object Threading.Mutex($false,'Global\AFZQueueOrphanRequestWatcher');$locked=$false
try{
  $locked=$mutex.WaitOne(0);if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s request=local-exact-source typed=true arbitrary_shell=false"
  while($true){
    $request=$null
    try{
      $request=Get-LocalRequest
      if(-not(Valid-Request $request)){Start-Sleep -Seconds $IntervalSeconds;continue}
      $requestId=[string]$request.request_id;$taskId=[string]$request.task_id;$state=Get-State
      if($state -and [string]$state.requestId -eq $requestId -and (Is-TerminalWatcherStatus ([string]$state.status))){Start-Sleep -Seconds $IntervalSeconds;continue}
      $current=Current-Sha
      if($current -notmatch '^[0-9a-f]{40}$'){
        $s=Save-State $requestId 'refused' 'Deployed source SHA is unavailable; refusing typed remediation.' $taskId;Save-Diagnostic $s;Log "REFUSED request=$requestId reason=no-source-sha";Start-Sleep -Seconds $IntervalSeconds;continue
      }
      $running=Save-State $requestId 'running' 'Atomic local request loaded from the deployed GitHub source; typed audit started.' $taskId
      Save-Diagnostic $running;Log "AUDIT_START request=$requestId task=$taskId sha=$current"
      $audit=Invoke-Runner 'audit' $taskId
      if([string]$audit.diagnosis -eq 'TERMINAL_RESULT_NO_ORPHAN'){
        $s=Save-State $requestId 'no-op' 'Terminal result exists and no movable orphan remains.' $taskId $audit;Save-Diagnostic $s;Log "NOOP request=$requestId diagnosis=TERMINAL_RESULT_NO_ORPHAN";Start-Sleep -Seconds $IntervalSeconds;continue
      }
      if([string]$audit.diagnosis -ne 'ORPHAN_AFTER_TERMINAL_RESULT' -or [int]$audit.counts.liveExecutors -ne 0 -or [int]$audit.counts.terminal -lt 1 -or [int]$audit.counts.movable -lt 1){
        $s=Save-State $requestId 'refused' ("Audit did not prove a safe orphan: diagnosis="+[string]$audit.diagnosis) $taskId $audit;Save-Diagnostic $s;Log "REFUSED request=$requestId diagnosis=$($audit.diagnosis)";Start-Sleep -Seconds $IntervalSeconds;continue
      }
      Log "APPLY_START request=$requestId task=$taskId";$apply=Invoke-Runner 'apply' $taskId
      if(-not [bool]$apply.ok -or [string]$apply.diagnosis -ne 'ORPHAN_AFTER_TERMINAL_RESULT' -or [int]$apply.safety.deletedFiles -ne 0 -or [bool]$apply.safety.terminalResultMoved -ne $false -or [int]$apply.safety.liveExecutorsBeforeApply -ne 0){throw 'Apply returned an invalid safety result.'}
      $post=Invoke-Runner 'audit' $taskId
      if([int]$post.counts.liveExecutors -ne 0 -or [int]$post.counts.movable -ne 0){throw "Post-audit failed: diagnosis=$($post.diagnosis) movable=$($post.counts.movable) live=$($post.counts.liveExecutors)"}
      $s=Save-State $requestId 'completed' ("Proven orphan quarantined; count="+[string]@($apply.quarantinedArtifacts).Count) $taskId $audit $apply $post
      Save-Diagnostic $s;Log "COMPLETE request=$requestId quarantined=$(@($apply.quarantinedArtifacts).Count) post=$($post.diagnosis)"
    }catch{
      $msg=$_.Exception.Message
      try{$rid=$(if($request){[string]$request.request_id}else{''});$tid=$(if($request){[string]$request.task_id}else{''});if($rid){$s=Save-State $rid 'failed' $msg $tid;Save-Diagnostic $s}}catch{}
      Log "ERROR $msg"
    }
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{if($locked){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
