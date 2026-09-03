#Requires -Version 5.1
[CmdletBinding()]
param([string]$SyncedSha='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$jobId='afz-blog-qwen35b-vs-ridge27b-20260902-r1'
$markerRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-afz-blog-model-comparison-recovery-request'
$marker=Join-Path $markerRoot ($jobId+'-activation-v3.json')
$v4Marker=Join-Path $markerRoot ($jobId+'-activation-v4.json')
$carrierResult='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-afz-blog-model-comparison-recovery\'+$jobId+'.json'
$taskName='AFZ H3 AFZ Blog Recovery Transport'
$sharedDiagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$sharedDiagPath=Join-Path $sharedDiagRoot 'AFZ-BLOG-COMPARISON-RECOVERY-TRANSPORT-LATEST.txt'
$termDiagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$termDiagPath=Join-Path $termDiagRoot 'AFZ-BLOG-COMPARISON-RECOVERY-TRANSPORT-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)

function Read-SafeJson([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return [pscustomobject]@{readError=$_.Exception.Message}}
}

function Write-SafeJson([string]$Path,$Value){
  $parent=Split-Path $Path -Parent
  if($parent -and -not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
  [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 20 -Compress),$utf8)
}

function Invoke-H3ReadOnlyProbe {
  $key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
  $known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
  $ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
  foreach($required in @($key,$known,$ssh)){
    if(-not(Test-Path -LiteralPath $required -PathType Leaf)){
      return [pscustomobject]@{ok=$false;classification='H3_READONLY_PROBE_LOCAL_PREREQUISITE_MISSING';missing=$required;mutation='NONE'}
    }
  }

  $remote=@'
$ErrorActionPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
$statePath='C:\ProgramData\AFZ\H3AFZBlogModelComparison\state.json'
$taskName='AFZ H3 AFZ Blog Comparison Recovery'
$stdoutPath='C:\ProgramData\AFZ\H3AFZBlogModelComparison\recovery.stdout.log'
$stderrPath='C:\ProgramData\AFZ\H3AFZBlogModelComparison\recovery.stderr.log'
$projectRoot='C:\Projects\AFZ-Blog-Model-Comparison-20260902-r1'
function ReadJson([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return $null}}
function Tail([string]$Path,[int]$Max=3000){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{$t=[IO.File]::ReadAllText($Path);if($t.Length -gt $Max){return $t.Substring($t.Length-$Max)};return $t}catch{return $null}}
function ModelState($State,[string]$Name){
  $v=$null
  if($State -and $State.PSObject.Properties.Name -contains 'models'){
    foreach($p in $State.models.PSObject.Properties){if([string]$p.Name -eq $Name){$v=$p.Value;break}}
  }
  if(-not $v){return [ordered]@{present=$false;attempted=$false;status=$null}}
  $o=[ordered]@{present=$true;attempted=$(if($v.PSObject.Properties.Name -contains 'attempted'){[bool]$v.attempted}else{$false});status=$(if($v.PSObject.Properties.Name -contains 'status'){[string]$v.status}else{$null})}
  foreach($n in @('started_at','completed_at','finished_at','done_reason','output_tokens','output_tokens_per_second','wall_seconds','recovered_from_saved_response','recovery_kind')){if($v.PSObject.Properties.Name -contains $n){$o[$n]=$v.$n}}
  return $o
}
$state=ReadJson $statePath
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$info=$(if($task){Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue}else{$null})
$ollama=@(Get-Process -ErrorAction SilentlyContinue|Where-Object{$_.ProcessName -match '^ollama($|_)'}|ForEach-Object{[ordered]@{pid=[int]$_.Id;name=[string]$_.ProcessName}})
$o=[ordered]@{
  ok=$true;host=$env:COMPUTERNAME;readOnly=$true;mutation='NONE'
  stateExists=(Test-Path -LiteralPath $statePath -PathType Leaf)
  stateStatus=$(if($state -and $state.PSObject.Properties.Name -contains 'status'){[string]$state.status}else{$null})
  stateMessage=$(if($state -and $state.PSObject.Properties.Name -contains 'message'){[string]$state.message}else{$null})
  stateSourceSha=$(if($state -and $state.PSObject.Properties.Name -contains 'source_sha'){[string]$state.source_sha}else{$null})
  stateUpdatedAt=$(if($state -and $state.PSObject.Properties.Name -contains 'updated_at'){[string]$state.updated_at}else{$null})
  qwen35b=(ModelState $state 'qwen3.6:35b-a3b')
  ridge27b=(ModelState $state 'qwen3.8-ridge:27b-16k')
  ridgeSavedResponseExists=(Test-Path -LiteralPath (Join-Path $projectRoot 'ridge27b-16k-ollama-response.json') -PathType Leaf)
  qwen35bSavedResponseExists=(Test-Path -LiteralPath (Join-Path $projectRoot 'qwen35b-a3b-ollama-response.json') -PathType Leaf)
  recoveryTaskExists=($null -ne $task)
  recoveryTaskState=$(if($task){[string]$task.State}else{'missing'})
  recoveryTaskLastRun=$(if($info -and $info.LastRunTime -gt [datetime]'2000-01-01'){$info.LastRunTime.ToString('o')}else{$null})
  recoveryTaskLastResult=$(if($info){[int]$info.LastTaskResult}else{$null})
  ollamaProcesses=$ollama
  stdoutTail=(Tail $stdoutPath)
  stderrTail=(Tail $stderrPath)
  observedAt=(Get-Date -Format o)
}
[Console]::Out.WriteLine(($o|ConvertTo-Json -Depth 12 -Compress))
'@

  # Keep the remote command tiny. The full read-only probe travels over stdin,
  # avoiding Windows' command-line length limit while preserving zero mutation.
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 read-only probe stdin empty.''};Invoke-Expression $script'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))

  function Invoke-ProbeTarget([string]$Target,[string]$Transport,[string[]]$ExtraOptions){
    $tag=[guid]::NewGuid().ToString('N')
    $inFile=Join-Path $env:TEMP ($tag+'.in.ps1')
    $outFile=Join-Path $env:TEMP ($tag+'.out')
    $errFile=Join-Path $env:TEMP ($tag+'.err')
    $sshArgs=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known))
    if($ExtraOptions){$sshArgs+=@($ExtraOptions)}
    $sshArgs+=@($Target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
    try{
      [IO.File]::WriteAllText($inFile,$remote,$utf8)
      $p=Start-Process -FilePath $ssh -ArgumentList $sshArgs -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
      if(-not $p.WaitForExit(25000)){
        try{$p.Kill()}catch{}
        return [pscustomobject]@{ok=$false;classification='H3_READONLY_PROBE_TIMEOUT';transport=$Transport;mutation='NONE'}
      }
      $stdout=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
      $stderr=$(if(Test-Path -LiteralPath $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
      $parsed=$null
      foreach($line in @($stdout -split "`r?`n"|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})){try{$parsed=$line|ConvertFrom-Json}catch{}}
      if($parsed){$parsed|Add-Member -NotePropertyName transport -NotePropertyValue $Transport -Force;return $parsed}
      return [pscustomobject]@{ok=$false;classification='H3_READONLY_PROBE_INVALID_RESULT';transport=$Transport;exit=[int]$p.ExitCode;error=$(if($stderr){$stderr}else{$stdout});mutation='NONE'}
    }finally{
      Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue
    }
  }

  $probe=Invoke-ProbeTarget 'Faiz@100.106.186.118' 'tailscale-system-ssh' @()
  if(-not [bool]$probe.ok){$probe=Invoke-ProbeTarget 'Faiz@192.168.50.185' 'lan-system-ssh' @('-o','HostKeyAlias=100.106.186.118')}
  return $probe
}

function Invoke-GuardedRecoveryV4($Probe){
  if(Test-Path -LiteralPath $v4Marker -PathType Leaf){
    $prior=Read-SafeJson $v4Marker
    if($prior){return $prior}
    return [ordered]@{ok=$true;status='already-armed';jobId=$jobId;marker=$v4Marker;modelReplay35B=$false;ridgeOnlyIfUnattempted=$true}
  }

  $eligible=(
    $Probe -and [bool]$Probe.ok -and
    $Probe.qwen35b -and [bool]$Probe.qwen35b.attempted -and
    [bool]$Probe.qwen35bSavedResponseExists -and
    $Probe.ridge27b -and -not [bool]$Probe.ridge27b.attempted -and
    -not [bool]$Probe.ridgeSavedResponseExists -and
    @($Probe.ollamaProcesses).Count -eq 0 -and
    [bool]$Probe.recoveryTaskExists -and
    [string]$Probe.recoveryTaskState -eq 'Ready' -and
    [int]$Probe.recoveryTaskLastResult -ne 0
  )
  if(-not $eligible){return [ordered]@{ok=$true;status='not-eligible';jobId=$jobId;mutation='NONE';modelReplay35B=$false;ridgeOnlyIfUnattempted=$true}}
  if($SyncedSha -notmatch '^[0-9a-fA-F]{40}$'){return [ordered]@{ok=$false;status='invalid-synced-sha';jobId=$jobId;mutation='NONE'}}

  $bootstrap=Join-Path $PSScriptRoot 'Bootstrap-H3-AFZBlog-ModelComparisonRecovery.ps1'
  if(-not(Test-Path -LiteralPath $bootstrap -PathType Leaf)){return [ordered]@{ok=$false;status='bootstrap-missing';jobId=$jobId;path=$bootstrap;mutation='NONE'}}

  $armed=[ordered]@{
    ok=$true;status='armed';jobId=$jobId;marker=$v4Marker;syncedSha=$SyncedSha
    modelReplay35B=$false;ridgeOnlyIfUnattempted=$true
    authoritativeProof=[ordered]@{
      qwen35bAttempted=[bool]$Probe.qwen35b.attempted
      qwen35bSavedResponseExists=[bool]$Probe.qwen35bSavedResponseExists
      ridge27bAttempted=[bool]$Probe.ridge27b.attempted
      ridgeSavedResponseExists=[bool]$Probe.ridgeSavedResponseExists
      ollamaProcessCount=@($Probe.ollamaProcesses).Count
      recoveryTaskState=[string]$Probe.recoveryTaskState
      recoveryTaskLastResult=[int]$Probe.recoveryTaskLastResult
      observedAt=[string]$Probe.observedAt
    }
    armedAt=(Get-Date -Format o)
  }
  Write-SafeJson $v4Marker $armed

  try{
    $argLine="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$bootstrap`" -ExpectedSha `"$SyncedSha`" -JobId `"$jobId`""
    $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $armed.status='recovery-bootstrap-started'
    $armed.bootstrapPid=[int]$p.Id
    $armed.startedAt=(Get-Date -Format o)
    Write-SafeJson $v4Marker $armed
    return $armed
  }catch{
    $armed.ok=$false
    $armed.status='bootstrap-start-failed'
    $armed.error=$_.Exception.Message
    $armed.failedAt=(Get-Date -Format o)
    Write-SafeJson $v4Marker $armed
    return $armed
  }
}

$markerValue=Read-SafeJson $marker
$carrierValue=Read-SafeJson $carrierResult
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$taskInfo=$(if($task){Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue}else{$null})
$h3Probe=$null
try{$h3Probe=Invoke-H3ReadOnlyProbe}catch{$h3Probe=[pscustomobject]@{ok=$false;classification='H3_READONLY_PROBE_EXCEPTION';error=$_.Exception.Message;mutation='NONE'}}
$v4Action=$null
try{$v4Action=Invoke-GuardedRecoveryV4 $h3Probe}catch{$v4Action=[pscustomobject]@{ok=$false;status='v4-rearm-exception';error=$_.Exception.Message;modelReplay35B=$false;ridgeOnlyIfUnattempted=$true}}

$out=[ordered]@{
  schema=1;purpose='EMERGENCY_DIAGNOSTIC_AND_GUARDED_RECOVERY_REARM';diagnosticReadOnly=$true;source='windows-main';controlPlane='github';jobId=$jobId
  syncedSha=$(if($SyncedSha){$SyncedSha}else{$null})
  activationMarker='activation-v3';activationMarkerExists=(Test-Path -LiteralPath $marker -PathType Leaf);activation=$markerValue
  recoveryV4MarkerExists=(Test-Path -LiteralPath $v4Marker -PathType Leaf);recoveryV4=$v4Action
  carrierResultExists=(Test-Path -LiteralPath $carrierResult -PathType Leaf);carrierResult=$carrierValue
  transportTaskExists=($null -ne $task);transportTaskState=$(if($task){[string]$task.State}else{'missing'})
  transportTaskLastRunTime=$(if($taskInfo -and $taskInfo.LastRunTime -gt [datetime]'2000-01-01'){$taskInfo.LastRunTime.ToString('o')}else{$null})
  transportTaskLastTaskResult=$(if($taskInfo){[int]$taskInfo.LastTaskResult}else{$null})
  h3Probe=$h3Probe
  modelReplay35B=$false
  ridgeCallAuthorizedOnlyByAuthoritativeH3UnattemptedProof=$(if($v4Action -and [string]$v4Action.status -eq 'recovery-bootstrap-started'){$true}else{$false})
  modelActionPerformedByDiagnosticProbe=$false
  observedAt=(Get-Date -Format o)
}
$json=$out|ConvertTo-Json -Depth 30
foreach($target in @([pscustomobject]@{Root=$sharedDiagRoot;Path=$sharedDiagPath},[pscustomobject]@{Root=$termDiagRoot;Path=$termDiagPath})){
  try{if(Test-Path -LiteralPath $target.Root -PathType Container){[IO.File]::WriteAllText($target.Path,$json,$utf8)}}catch{}
}
Write-Output ($out|ConvertTo-Json -Depth 30 -Compress)
