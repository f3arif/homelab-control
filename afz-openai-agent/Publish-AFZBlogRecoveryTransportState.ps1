#Requires -Version 5.1
[CmdletBinding()]
param([string]$SyncedSha='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$jobId='afz-blog-qwen35b-vs-ridge27b-20260902-r1'
$markerRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-afz-blog-model-comparison-recovery-request'
$v3Marker=Join-Path $markerRoot ($jobId+'-activation-v3.json')
$v4Marker=Join-Path $markerRoot ($jobId+'-activation-v4.json')
$v5Marker=Join-Path $markerRoot ($jobId+'-activation-v5.json')
$carrierResult='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-afz-blog-model-comparison-recovery\'+$jobId+'.json'
$transportTaskName='AFZ H3 AFZ Blog Recovery Transport'
$sharedDiagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$sharedDiagPath=Join-Path $sharedDiagRoot 'AFZ-BLOG-COMPARISON-RECOVERY-TRANSPORT-LATEST.txt'
$termDiagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$termDiagPath=Join-Path $termDiagRoot 'AFZ-BLOG-COMPARISON-RECOVERY-TRANSPORT-LATEST.txt'
$h3Tailscale='100.106.186.118'
$h3Lan='192.168.50.213'
$h3Mac='4C-ED-FB-3F-B0-9E'
$broadcast='192.168.50.255'
$utf8=New-Object Text.UTF8Encoding($false)

function Read-SafeJson([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return [pscustomobject]@{readError=$_.Exception.Message;path=$Path}}
}
function Write-SafeJson([string]$Path,$Value){
  $parent=Split-Path $Path -Parent
  if($parent -and -not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
  [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 30 -Compress),$utf8)
}
function Ensure-H3Awake {
  $wasOnline=(Test-Connection -ComputerName $h3Tailscale -Count 1 -Quiet -ErrorAction SilentlyContinue) -or (Test-Connection -ComputerName $h3Lan -Count 1 -Quiet -ErrorAction SilentlyContinue)
  if($wasOnline){return [ordered]@{ok=$true;wakeAttempted=$false;online=$true;target='DESKTOP-H3R6CQN'}}
  try{
    $bytes=$h3Mac -split '[:-]'|ForEach-Object{[Convert]::ToByte($_,16)}
    $packet=New-Object byte[] 102
    0..5|ForEach-Object{$packet[$_]=0xFF}
    for($i=1;$i -le 16;$i++){[Array]::Copy($bytes,0,$packet,6+(($i-1)*6),6)}
    $client=New-Object Net.Sockets.UdpClient
    try{
      $client.EnableBroadcast=$true
      foreach($round in 1..5){foreach($port in @(9,7)){$ep=New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($broadcast)),$port;[void]$client.Send($packet,$packet.Length,$ep)};Start-Sleep -Milliseconds 400}
    }finally{$client.Dispose()}
  }catch{return [ordered]@{ok=$false;wakeAttempted=$true;online=$false;error=$_.Exception.Message;target='DESKTOP-H3R6CQN'}}
  foreach($i in 1..24){
    if((Test-Connection -ComputerName $h3Lan -Count 1 -Quiet -ErrorAction SilentlyContinue) -or (Test-Connection -ComputerName $h3Tailscale -Count 1 -Quiet -ErrorAction SilentlyContinue)){
      return [ordered]@{ok=$true;wakeAttempted=$true;online=$true;target='DESKTOP-H3R6CQN';waitSeconds=($i*3)}
    }
    Start-Sleep -Seconds 3
  }
  return [ordered]@{ok=$false;wakeAttempted=$true;online=$false;target='DESKTOP-H3R6CQN';error='H3 did not become reachable after bounded Wake-on-LAN wait.'}
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
function Tail([string]$Path,[int]$Max=4000){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{$t=[IO.File]::ReadAllText($Path);if($t.Length -gt $Max){return $t.Substring($t.Length-$Max)};return $t}catch{return $null}}
function ModelState($State,[string]$Name){
  $v=$null
  if($State -and $State.PSObject.Properties.Name -contains 'models'){
    foreach($p in $State.models.PSObject.Properties){if([string]$p.Name -eq $Name){$v=$p.Value;break}}
  }
  if(-not $v){return [ordered]@{present=$false;attempted=$false;status=$null}}
  $o=[ordered]@{present=$true;attempted=$(if($v.PSObject.Properties.Name -contains 'attempted'){[bool]$v.attempted}else{$false});status=$(if($v.PSObject.Properties.Name -contains 'status'){[string]$v.status}else{$null})}
  foreach($n in @('started_at','completed_at','finished_at','done_reason','output_tokens','output_tokens_per_second','wall_seconds','prompt_tokens','prompt_tokens_per_second','strict_json_valid','schema_valid','article_word_count','word_target_met','recovered_from_saved_response','recovery_kind','curl_exit','error')){if($v.PSObject.Properties.Name -contains $n){$o[$n]=$v.$n}}
  return $o
}
$state=ReadJson $statePath
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$info=$(if($task){Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue}else{$null})
$ollama=@(Get-Process -ErrorAction SilentlyContinue|Where-Object{$_.ProcessName -match '^ollama($|_)'}|ForEach-Object{[ordered]@{pid=[int]$_.Id;name=[string]$_.ProcessName}})
$ollamaApiReady=$false;$ollamaModels=@();$ollamaApiError=$null
try{$tags=Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 5 -ErrorAction Stop;$ollamaApiReady=$true;$ollamaModels=@($tags.models|ForEach-Object{[string]$_.name})}catch{$ollamaApiError=$_.Exception.Message}
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
  recoveryTaskPrincipalUser=$(if($task){[string]$task.Principal.UserId}else{$null})
  recoveryTaskLogonType=$(if($task){[string]$task.Principal.LogonType}else{$null})
  recoveryTaskLastRun=$(if($info -and $info.LastRunTime -gt [datetime]'2000-01-01'){$info.LastRunTime.ToString('o')}else{$null})
  recoveryTaskLastResult=$(if($info){[int]$info.LastTaskResult}else{$null})
  ollamaProcesses=$ollama
  ollamaApiReady=$ollamaApiReady
  ollamaModels=$ollamaModels
  ollamaApiError=$ollamaApiError
  stdoutTail=(Tail $stdoutPath)
  stderrTail=(Tail $stderrPath)
  observedAt=(Get-Date -Format o)
}
[Console]::Out.WriteLine(($o|ConvertTo-Json -Depth 15 -Compress))
'@

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
      if(-not $p.WaitForExit(30000)){
        try{$p.Kill()}catch{}
        return [pscustomobject]@{ok=$false;classification='H3_READONLY_PROBE_TIMEOUT';transport=$Transport;mutation='NONE'}
      }
      $stdout=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
      $stderr=$(if(Test-Path -LiteralPath $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
      $parsed=$null
      foreach($line in @($stdout -split "`r?`n"|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})){try{$parsed=$line|ConvertFrom-Json}catch{}}
      if($parsed){$parsed|Add-Member -NotePropertyName transport -NotePropertyValue $Transport -Force;return $parsed}
      return [pscustomobject]@{ok=$false;classification='H3_READONLY_PROBE_INVALID_RESULT';transport=$Transport;exit=[int]$p.ExitCode;error=$(if($stderr){$stderr}else{$stdout});mutation='NONE'}
    }finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
  }

  $probe=Invoke-ProbeTarget ('Faiz@'+$h3Tailscale) 'tailscale-system-ssh' @()
  if(-not [bool]$probe.ok){$probe=Invoke-ProbeTarget ('Faiz@'+$h3Lan) 'lan-system-ssh' @('-o',('HostKeyAlias='+$h3Tailscale))}
  return $probe
}

function Invoke-GuardedRecoveryV5($Probe,$V4,$Carrier){
  if(Test-Path -LiteralPath $v5Marker -PathType Leaf){
    $prior=Read-SafeJson $v5Marker
    if($prior){return $prior}
    return [ordered]@{ok=$true;status='already-armed';jobId=$jobId;marker=$v5Marker;modelReplay35B=$false;ridgeOnlyIfUnattempted=$true}
  }
  if(-not $V4 -or [string]$V4.status -ne 'recovery-bootstrap-started'){return [ordered]@{ok=$true;status='v4-proof-missing';mutation='NONE'}}
  if(-not $Carrier -or -not [bool]$Carrier.ok -or [string]$Carrier.status -ne 'launched'){return [ordered]@{ok=$true;status='v4-carrier-proof-missing';mutation='NONE'}}
  if([string]$Carrier.expectedSha -ne [string]$V4.syncedSha){return [ordered]@{ok=$true;status='v4-carrier-sha-mismatch';mutation='NONE'}}

  $carrierAt=$null;$taskLast=$null
  try{$carrierAt=[datetime]::Parse([string]$Carrier.updatedAt)}catch{}
  try{$taskLast=[datetime]::Parse([string]$Probe.recoveryTaskLastRun)}catch{}
  $v4TaskDidNotAdvance=($carrierAt -and $taskLast -and $taskLast -lt $carrierAt)

  $eligible=(
    $Probe -and [bool]$Probe.ok -and
    $Probe.qwen35b -and [bool]$Probe.qwen35b.attempted -and
    [bool]$Probe.qwen35bSavedResponseExists -and
    $Probe.ridge27b -and -not [bool]$Probe.ridge27b.attempted -and
    -not [bool]$Probe.ridgeSavedResponseExists -and
    [bool]$Probe.recoveryTaskExists -and
    [string]$Probe.recoveryTaskState -eq 'Ready' -and
    $v4TaskDidNotAdvance
  )
  if(-not $eligible){return [ordered]@{ok=$true;status='not-eligible';jobId=$jobId;mutation='NONE';modelReplay35B=$false;ridgeOnlyIfUnattempted=$true;v4TaskDidNotAdvance=$v4TaskDidNotAdvance}}
  if($SyncedSha -notmatch '^[0-9a-fA-F]{40}$'){return [ordered]@{ok=$false;status='invalid-synced-sha';jobId=$jobId;mutation='NONE'}}

  $bootstrap=Join-Path $PSScriptRoot 'Bootstrap-H3-AFZBlog-ModelComparisonRecovery.ps1'
  if(-not(Test-Path -LiteralPath $bootstrap -PathType Leaf)){return [ordered]@{ok=$false;status='bootstrap-missing';jobId=$jobId;path=$bootstrap;mutation='NONE'}}

  $armed=[ordered]@{
    ok=$true;status='armed';jobId=$jobId;marker=$v5Marker;syncedSha=$SyncedSha
    modelReplay35B=$false;ridgeOnlyIfUnattempted=$true
    authoritativeProof=[ordered]@{
      qwen35bAttempted=[bool]$Probe.qwen35b.attempted
      qwen35bSavedResponseExists=[bool]$Probe.qwen35bSavedResponseExists
      ridge27bAttempted=[bool]$Probe.ridge27b.attempted
      ridgeSavedResponseExists=[bool]$Probe.ridgeSavedResponseExists
      recoveryTaskState=[string]$Probe.recoveryTaskState
      recoveryTaskLastRun=[string]$Probe.recoveryTaskLastRun
      v4CarrierUpdatedAt=[string]$Carrier.updatedAt
      v4TaskDidNotAdvance=$v4TaskDidNotAdvance
      ollamaApiReady=[bool]$Probe.ollamaApiReady
      ridgeModelAdvertised=(@($Probe.ollamaModels) -contains 'qwen3.8-ridge:27b-16k')
      observedAt=[string]$Probe.observedAt
    }
    armedAt=(Get-Date -Format o)
  }
  Write-SafeJson $v5Marker $armed
  try{
    $argLine="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$bootstrap`" -ExpectedSha `"$SyncedSha`" -JobId `"$jobId`""
    $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $armed.status='recovery-bootstrap-started';$armed.bootstrapPid=[int]$p.Id;$armed.startedAt=(Get-Date -Format o)
    Write-SafeJson $v5Marker $armed
    return $armed
  }catch{
    $armed.ok=$false;$armed.status='bootstrap-start-failed';$armed.error=$_.Exception.Message;$armed.failedAt=(Get-Date -Format o)
    Write-SafeJson $v5Marker $armed
    return $armed
  }
}

$v3=Read-SafeJson $v3Marker
$v4=Read-SafeJson $v4Marker
$carrier=Read-SafeJson $carrierResult
$transportTask=Get-ScheduledTask -TaskName $transportTaskName -ErrorAction SilentlyContinue
$transportInfo=$(if($transportTask){Get-ScheduledTaskInfo -TaskName $transportTaskName -ErrorAction SilentlyContinue}else{$null})
$wake=$null
try{$wake=Ensure-H3Awake}catch{$wake=[ordered]@{ok=$false;wakeAttempted=$false;online=$false;error=$_.Exception.Message}}
$probe=$null
if($wake -and [bool]$wake.online){try{$probe=Invoke-H3ReadOnlyProbe}catch{$probe=[pscustomobject]@{ok=$false;classification='H3_READONLY_PROBE_EXCEPTION';error=$_.Exception.Message;mutation='NONE'}}}else{$probe=[pscustomobject]@{ok=$false;classification='H3_OFFLINE_AFTER_WAKE';error=$(if($wake){$wake.error}else{'wake-state-missing'});mutation='NONE'}}
$v5=$null
try{$v5=Invoke-GuardedRecoveryV5 $probe $v4 $carrier}catch{$v5=[pscustomobject]@{ok=$false;status='v5-rearm-exception';error=$_.Exception.Message;modelReplay35B=$false;ridgeOnlyIfUnattempted=$true}}

$out=[ordered]@{
  schema=1;purpose='EMERGENCY_DIAGNOSTIC_AND_GUARDED_RECOVERY_REARM';diagnosticReadOnly=$true
  source='windows-main';controlPlane='github';jobId=$jobId;syncedSha=$(if($SyncedSha){$SyncedSha}else{$null})
  wake=$wake;activationV3=$v3;activationV4=$v4
  recoveryV5MarkerExists=(Test-Path -LiteralPath $v5Marker -PathType Leaf);recoveryV5=$v5
  carrierResultExists=(Test-Path -LiteralPath $carrierResult -PathType Leaf);carrierResult=$carrier
  transportTaskExists=($null -ne $transportTask);transportTaskState=$(if($transportTask){[string]$transportTask.State}else{'missing'})
  transportTaskLastRunTime=$(if($transportInfo -and $transportInfo.LastRunTime -gt [datetime]'2000-01-01'){$transportInfo.LastRunTime.ToString('o')}else{$null})
  transportTaskLastTaskResult=$(if($transportInfo){[int]$transportInfo.LastTaskResult}else{$null})
  h3Probe=$probe
  modelReplay35B=$false
  ridgeCallAuthorizedOnlyByAuthoritativeH3UnattemptedProof=$(if($v5 -and [string]$v5.status -eq 'recovery-bootstrap-started'){$true}else{$false})
  modelActionPerformedByDiagnosticProbe=$false
  observedAt=(Get-Date -Format o)
}
$json=$out|ConvertTo-Json -Depth 35
foreach($target in @([pscustomobject]@{Root=$sharedDiagRoot;Path=$sharedDiagPath},[pscustomobject]@{Root=$termDiagRoot;Path=$termDiagPath})){
  try{if(Test-Path -LiteralPath $target.Root -PathType Container){[IO.File]::WriteAllText($target.Path,$json,$utf8)}}catch{}
}
Write-Output ($out|ConvertTo-Json -Depth 35 -Compress)
