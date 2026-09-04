#Requires -Version 5.1
# AFZ_TIMEOUT_SECONDS=900
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$ProgressPreference='SilentlyContinue'

$JobId='9d9eea1b7618'
$H3='Faiz@100.106.186.118'
$H3Ip='100.106.186.118'
$H3Lan='192.168.50.185'
$H3Mac='4C-ED-FB-3F-B0-9E'
$Broadcast='192.168.50.255'
$Key='C:\Users\Faiz\.ssh\afz_h3_worker'
$Known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$LocalBaseCandidates=@('qwen3.5:9b','qwen3.8:9b','qwen3.6:8b')
$LocalAlias='qwen3.5:9b-64k-rh'
$CloudProvider='openai-codex'
$CloudModel='gpt-5.6-luna'

if([Environment]::MachineName -ne 'DESKTOP-10SKF0M'){throw ('windows-main only; actual='+[Environment]::MachineName)}
foreach($p in @($Key,$Known)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw ('Missing required path: '+$p)}}
$Ssh=(Get-Command ssh.exe -ErrorAction Stop).Source

function Send-H3Wake {
  $macBytes=[byte[]](($H3Mac -split '[:-]')|ForEach-Object{[Convert]::ToByte($_,16)})
  $packet=New-Object byte[] 102
  0..5|ForEach-Object{$packet[$_]=0xFF}
  for($i=0;$i -lt 16;$i++){[Array]::Copy($macBytes,0,$packet,6+($i*6),6)}
  $udp=New-Object Net.Sockets.UdpClient
  try {
    $udp.EnableBroadcast=$true
    foreach($target in @($Broadcast,$H3Lan,'255.255.255.255')){
      foreach($port in @(9,7)){
        foreach($attempt in 1..2){
          try{[void]$udp.Send($packet,$packet.Length,$target,$port)}catch{}
          Start-Sleep -Milliseconds 120
        }
      }
    }
  } finally {$udp.Dispose()}
}

function Test-Tcp22 {
  $c=New-Object Net.Sockets.TcpClient
  try{
    $ar=$c.BeginConnect($H3Ip,22,$null,$null)
    if(-not $ar.AsyncWaitHandle.WaitOne(1200)){return $false}
    $c.EndConnect($ar)
    return $true
  }catch{return $false}finally{$c.Dispose()}
}

function Invoke-SshRemote([string]$Remote,[int]$TimeoutSeconds=720){
  $stdin=Join-Path $env:TEMP ('afz-rh-timeout-'+[guid]::NewGuid().ToString('N')+'.ps1')
  $stdout=Join-Path $env:TEMP ('afz-rh-timeout-'+[guid]::NewGuid().ToString('N')+'.out')
  $stderr=Join-Path $env:TEMP ('afz-rh-timeout-'+[guid]::NewGuid().ToString('N')+'.err')
  $utf8=New-Object Text.UTF8Encoding($false)
  try{
    [IO.File]::WriteAllText($stdin,$Remote,$utf8)
    $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''empty repair stdin''};Invoke-Expression $script'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    $args=@('-i',$Key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','ServerAliveInterval=10','-o','ServerAliveCountMax=3','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$Known),$H3,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
    $p=Start-Process -FilePath $Ssh -ArgumentList $args -RedirectStandardInput $stdin -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit($TimeoutSeconds*1000)){
      try{$p.Kill()}catch{}
      try{$p.WaitForExit()}catch{}
      throw 'H3 SSH repair timeout'
    }
    try{$p.WaitForExit()}catch{}
    $out=$(if(Test-Path $stdout){[IO.File]::ReadAllText($stdout)}else{''})
    $err=$(if(Test-Path $stderr){[IO.File]::ReadAllText($stderr)}else{''})
    $code=[int]$p.ExitCode
    [pscustomobject]@{ExitCode=$code;StdOut=$out;StdErr=$err}
  } finally {
    Remove-Item $stdin,$stdout,$stderr -Force -ErrorAction SilentlyContinue
  }
}

Send-H3Wake
$ready=$false
for($i=0;$i -lt 45;$i++){
  if(Test-Tcp22){$ready=$true;break}
  Start-Sleep -Seconds 2
}
if(-not $ready){throw 'H3 SSH did not become reachable after wake'}

$remote=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$ProgressPreference='SilentlyContinue'

$JobId='9d9eea1b7618'
$LocalBaseCandidates=@('qwen3.5:9b','qwen3.8:9b','qwen3.6:8b')
$LocalAlias='qwen3.5:9b-64k-rh'
$CloudProvider='openai-codex'
$CloudModel='gpt-5.6-luna'

$Hermes='C:\Users\Faiz\AppData\Local\hermes\bin\hermes.exe'
$HermesHome='C:\Users\Faiz\AppData\Local\hermes'
$Jobs=Join-Path $HermesHome 'cron\jobs.json'
$Config=Join-Path $HermesHome 'config.yaml'
$Ollama='C:\Users\Faiz\AppData\Local\Programs\Ollama\ollama.exe'

foreach($p in @($Hermes,$Jobs,$Config,$Ollama)){
  if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw ('Missing H3 path: '+$p)}
}

$compact=@"
You are Radio Hilal's bounded lecture controller. The pre-run monitor supplies compact JSON from radiohilal_intake_monitor.py.

FAST PATH: if changed_since_previous_run=false and next_action=no_change, return exactly RADIOHILAL_NO_CHANGE active=<active_lecture_count> next=next-cycle. Do not call tools.

Finish within 90 seconds. Use at most one bounded action sequence. Never perform diagnostics after the decision, never retry/recreate work because of timeout/reporting failure, and never duplicate queued, processing, intake, or terminal reviews.

Windows-main owns Radio Hilal API/database/local-media/service mutations. Do not alter source media, security/allowlists, unrelated services, or credentials. Do not wake other workers.

Intake: never add a lecture when intake_allowed=false or active_lecture_count>=2. When allowed, exact-URL dedupe first and submit at most one eligible recent standalone speaker-diverse lecture. Preserve exact SourceUrl/title/speaker/language/date, ContentType Lecture, rightsConfirmed=false, and rightsBasis "Not provided; permission not asserted".

ReadyForReview: reconcile only the same relevant ID using minimum metadata. Verify source/media identity and integrity, deterministic local/lexical/promo gates, and explicit final OpenAI verification PASSED. Any missing/PENDING/ERROR/FAIL/uncertain gate => HUMAN_HOLD. Never let an outer PASS override inner failure.

Return exactly one compact result: RADIOHILAL_NO_CHANGE active=<N> next=next-cycle; BLOCKED <count/status> next=next-cycle; SUBMITTED speaker=<...> title=<...> id=<...> status=<...>; TERMINAL speaker=<...> id=<...> result=<Approved|Rejected|HUMAN_HOLD> reason=<short>; FAILURE blocker=<short> next=<single smallest action>; or CONTROLLER_TIMEOUT.
"@

function Get-Job {
  $doc=Get-Content -LiteralPath $Jobs -Raw -Encoding UTF8|ConvertFrom-Json
  $arr=$(if($doc.PSObject.Properties.Name -contains 'jobs'){@($doc.jobs)}else{@($doc)})
  @($arr|Where-Object{[string]$_.id -eq $JobId})|Select-Object -First 1
}

function Job-Summary($j){
  [ordered]@{
    provider=$(if($j){[string]$j.provider}else{$null})
    model=$(if($j){[string]$j.model}else{$null})
    reasoning=$(if($j -and $j.PSObject.Properties.Name -contains 'reasoning_effort'){[string]$j.reasoning_effort}else{$null})
    schedule=$(if($j){[string]$j.schedule_display}else{$null})
    enabled=$(if($j){[bool]$j.enabled}else{$false})
    state=$(if($j){[string]$j.state}else{$null})
    lastStatus=$(if($j){[string]$j.last_status}else{$null})
    lastError=$(if($j){[string]$j.last_error}else{$null})
    failureStreak=$(if($j){[int]$j.failure_streak}else{$null})
    lastRunAt=$(if($j){[string]$j.last_run_at}else{$null})
  }
}

function Invoke-CronCanary {
  $before=Get-Job
  $txt=(& $Hermes cron run $JobId 2>&1|Out-String).Trim()
  Start-Sleep -Seconds 3
  $after=Get-Job
  $bad=(
    $txt -match '(?i)ran now:\s*failed|provider timeout|timed out|HTTP 5\d\d|failed after|context window|no llm provider|unexpected reasoning effort' -or
    [string]$after.last_status -eq 'error'
  )
  [ordered]@{
    ok=(-not $bad)
    output=($txt -replace '[\r\n]+',' | ')
    after=Job-Summary $after
  }
}

$original=Get-Job
if(-not $original){throw 'RadioHilal cron job missing'}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backup=$Jobs+'.timeout-repair-'+$stamp+'.bak'
Copy-Item -LiteralPath $Jobs -Destination $backup -Force
$configHashBefore=(Get-FileHash -LiteralPath $Config -Algorithm SHA256).Hash

& $Hermes cron pause $JobId | Out-Null

$cloudAuth=(& $Hermes auth status openai-codex 2>&1|Out-String)
$cloudReady=($cloudAuth -match '(?i)logged in|authenticated|active')

$list=(& $Ollama list 2>&1|Out-String)
$localBase=$null
foreach($candidate in $LocalBaseCandidates){
  if($list -match [regex]::Escape($candidate)){$localBase=$candidate;break}
}

$localReady=$false
$localSmokeSeconds=$null
$localSmokeError=$null
if($localBase){
  $mf=Join-Path $env:TEMP ('rh-9b-'+[guid]::NewGuid().ToString('N')+'.Modelfile')
  try{
    $mfText='FROM '+$localBase+[Environment]::NewLine+'PARAMETER num_ctx 65536'+[Environment]::NewLine
    [IO.File]::WriteAllText($mf,$mfText,(New-Object Text.UTF8Encoding($false)))
    & $Ollama create $LocalAlias -f $mf *> $null
    if($LASTEXITCODE -ne 0){throw 'Ollama local alias create failed'}
  } finally {Remove-Item $mf -Force -ErrorAction SilentlyContinue}

  $body=[ordered]@{
    model=$LocalAlias
    messages=@(
      @{role='system';content='Return one short controller status only.'},
      @{role='user';content='{"active_lecture_count":6,"changed_since_previous_run":false,"intake_allowed":false,"next_action":"no_change"}'}
    )
    max_tokens=48
    stream=$false
    reasoning_effort='low'
  }|ConvertTo-Json -Depth 8 -Compress
  $sw=[Diagnostics.Stopwatch]::StartNew()
  try{
    $resp=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/v1/chat/completions' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 60
    $sw.Stop()
    $localSmokeSeconds=[math]::Round($sw.Elapsed.TotalSeconds,2)
    $answer=[string]$resp.choices[0].message.content
    $localReady=(-not [string]::IsNullOrWhiteSpace($answer) -and $localSmokeSeconds -le 60)
  }catch{
    $sw.Stop()
    $localSmokeSeconds=[math]::Round($sw.Elapsed.TotalSeconds,2)
    $localSmokeError=$_.Exception.Message
  }
}

$primaryProvider=$(if($localReady){'ollama'}elseif($cloudReady){$CloudProvider}else{$null})
$primaryModel=$(if($localReady){$LocalAlias}elseif($cloudReady){$CloudModel}else{$null})

if(-not $primaryProvider){
  Copy-Item -LiteralPath $backup -Destination $Jobs -Force
  & $Hermes cron pause $JobId | Out-Null
  throw ('No viable inference route; localBase='+$localBase+' localError='+$localSmokeError+' cloudReady='+$cloudReady)
}

& $Hermes cron edit $JobId --schedule 'every 1h' --prompt $compact --provider $primaryProvider --model $primaryModel --reasoning-effort low
if($LASTEXITCODE -ne 0){
  Copy-Item -LiteralPath $backup -Destination $Jobs -Force
  & $Hermes cron pause $JobId | Out-Null
  throw 'Primary cron edit failed'
}

$readback=Get-Job
$readReason=$(if($readback.PSObject.Properties.Name -contains 'reasoning_effort'){[string]$readback.reasoning_effort}else{''})
if([string]$readback.provider -ne $primaryProvider -or [string]$readback.model -ne $primaryModel -or $readReason -ne 'low' -or [int]$readback.schedule.minutes -ne 60){
  Copy-Item -LiteralPath $backup -Destination $Jobs -Force
  & $Hermes cron pause $JobId | Out-Null
  throw 'Primary cron readback mismatch'
}

& $Hermes cron resume $JobId | Out-Null
$primaryCanary=Invoke-CronCanary
$finalProvider=$primaryProvider
$finalModel=$primaryModel
$cloudFallbackUsed=$false
$cloudCanary=$null

if(-not [bool]$primaryCanary.ok -and $primaryProvider -eq 'ollama' -and $cloudReady){
  & $Hermes cron pause $JobId | Out-Null
  & $Hermes cron edit $JobId --schedule 'every 1h' --prompt $compact --provider $CloudProvider --model $CloudModel --reasoning-effort low
  if($LASTEXITCODE -ne 0){
    Copy-Item -LiteralPath $backup -Destination $Jobs -Force
    & $Hermes cron pause $JobId | Out-Null
    throw 'Cloud fallback cron edit failed'
  }
  & $Hermes cron resume $JobId | Out-Null
  $cloudCanary=Invoke-CronCanary
  if([bool]$cloudCanary.ok){
    $finalProvider=$CloudProvider
    $finalModel=$CloudModel
    $cloudFallbackUsed=$true
  }else{
    Copy-Item -LiteralPath $backup -Destination $Jobs -Force
    & $Hermes cron pause $JobId | Out-Null
    [ordered]@{
      ok=$false
      classification='RADIOHILAL_CRON_BOTH_ROUTES_FAILED_PAUSED'
      original=Job-Summary $original
      localBase=$localBase
      localSmokeReady=$localReady
      localSmokeSeconds=$localSmokeSeconds
      localSmokeError=$localSmokeError
      primaryCanary=$primaryCanary
      cloudCanary=$cloudCanary
      globalConfigMutation='NONE'
      baseModelMutation='NONE'
      timestamp=(Get-Date -Format o)
    }|ConvertTo-Json -Depth 12 -Compress
    exit 31
  }
}elseif(-not [bool]$primaryCanary.ok){
  Copy-Item -LiteralPath $backup -Destination $Jobs -Force
  & $Hermes cron pause $JobId | Out-Null
  [ordered]@{
    ok=$false
    classification='RADIOHILAL_CRON_PRIMARY_FAILED_NO_CLOUD_PAUSED'
    original=Job-Summary $original
    localBase=$localBase
    localSmokeReady=$localReady
    localSmokeSeconds=$localSmokeSeconds
    localSmokeError=$localSmokeError
    cloudReady=$cloudReady
    primaryCanary=$primaryCanary
    globalConfigMutation='NONE'
    baseModelMutation='NONE'
    timestamp=(Get-Date -Format o)
  }|ConvertTo-Json -Depth 12 -Compress
  exit 32
}

$configHashAfter=(Get-FileHash -LiteralPath $Config -Algorithm SHA256).Hash
$final=Get-Job

[ordered]@{
  ok=$true
  classification='RADIOHILAL_CRON_TIMEOUT_REPAIRED'
  original=Job-Summary $original
  final=Job-Summary $final
  localBase=$localBase
  localAlias=$(if($localReady){$LocalAlias}else{$null})
  localSmokeReady=$localReady
  localSmokeSeconds=$localSmokeSeconds
  localSmokeError=$localSmokeError
  openAICodexAuthReady=$cloudReady
  cloudFallbackUsed=$cloudFallbackUsed
  primaryCanary=$primaryCanary
  cloudCanary=$cloudCanary
  globalConfigHashUnchanged=($configHashBefore -eq $configHashAfter)
  globalConfigMutation='NONE'
  baseModelMutation='NONE'
  backup=$backup
  timestamp=(Get-Date -Format o)
}|ConvertTo-Json -Depth 12 -Compress
'@

$result=Invoke-SshRemote -Remote $remote -TimeoutSeconds 780
Write-Output ('SSH_EXIT='+$result.ExitCode)
if($result.StdOut){Write-Output $result.StdOut.Trim()}
if($result.StdErr){Write-Output ('SSH_STDERR='+($result.StdErr -replace '[\r\n]+',' | '))}
if($result.ExitCode -ne 0){exit $result.ExitCode}
