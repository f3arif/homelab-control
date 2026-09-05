#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$Port=8797,
  [string]$BindHost='100.70.25.8'
)
$ErrorActionPreference='Stop'
$allowFile=Join-Path $InstallRoot 'afz-openai-agent\allowed-clients.txt'
$logRoot='C:\ProgramData\AFZ\OpenAIAgent\logs'
$sourceState='C:\ProgramData\AFZ\OpenAIAgent\source-state.json'
$updateState='C:\ProgramData\AFZ\OpenAIAgent\last-update.json'
$watchState='C:\ProgramData\AFZ\OpenAIAgent\push-watcher.json'
$benchmarkState='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen27b\latest.json'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

function Log([string]$m){Add-Content -LiteralPath (Join-Path $logRoot 'control.log') -Value "$(Get-Date -Format o) $m" -Encoding UTF8}
function Get-AllowedClients{$ips=@('127.0.0.1','::1');if(Test-Path $allowFile){$ips+=@(Get-Content -LiteralPath $allowFile|ForEach-Object {$_.Trim()}|Where-Object {$_ -and -not $_.StartsWith('#') -and $_ -match '^100\.(?:\d{1,3}\.){2}\d{1,3}$'})};return @($ips|Sort-Object -Unique)}
function Get-RemoteIp($ctx){$a=$ctx.Request.RemoteEndPoint.Address;try{if($a.IsIPv4MappedToIPv6){return $a.MapToIPv4().ToString()}}catch{};return $a.ToString()}
function Send-Json($ctx,[int]$status,$obj){$json=$obj|ConvertTo-Json -Depth 30 -Compress;$b=[Text.Encoding]::UTF8.GetBytes($json);$ctx.Response.StatusCode=$status;$ctx.Response.ContentType='application/json; charset=utf-8';$ctx.Response.Headers['Cache-Control']='no-store';$ctx.Response.Headers['Access-Control-Allow-Origin']='*';$ctx.Response.Headers['Access-Control-Allow-Headers']='Content-Type';$ctx.Response.Headers['Access-Control-Allow-Methods']='GET,POST,OPTIONS';$ctx.Response.ContentLength64=$b.Length;$ctx.Response.OutputStream.Write($b,0,$b.Length);$ctx.Response.Close()}
function Send-Html($ctx,[string]$html){$b=[Text.Encoding]::UTF8.GetBytes($html);$ctx.Response.StatusCode=200;$ctx.Response.ContentType='text/html; charset=utf-8';$ctx.Response.Headers['Cache-Control']='no-store';$ctx.Response.ContentLength64=$b.Length;$ctx.Response.OutputStream.Write($b,0,$b.Length);$ctx.Response.Close()}
function Read-Json($ctx){$r=New-Object IO.StreamReader($ctx.Request.InputStream,$ctx.Request.ContentEncoding);try{$raw=$r.ReadToEnd()}finally{$r.Dispose()};if([string]::IsNullOrWhiteSpace($raw)){return [pscustomobject]@{}};return $raw|ConvertFrom-Json}
function Start-Update{$task='AFZ OpenAI Agent Updater';$t=Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue;if(-not $t){throw "Scheduled task missing: $task"};Start-ScheduledTask -TaskName $task;return [ordered]@{ok=$true;state='UPDATE_STARTED';task=$task;startedAt=(Get-Date -Format o)}}
function Start-ExactShaUpdate([string]$sha){
  $updater=Join-Path $InstallRoot 'afz-openai-agent\Update-AFZ-OpenAI-Agent.ps1'
  if(-not(Test-Path $updater)){throw "Updater missing: $updater"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$updater`" -InstallRoot `"$InstallRoot`" -ExpectedSha `"$sha`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  return [ordered]@{ok=$true;state='PUSH_DEPLOY_STARTED';sha=$sha;pid=$p.Id;startedAt=(Get-Date -Format o)}
}
function Get-Commit{if(Test-Path $sourceState){try{return [string]((Get-Content $sourceState -Raw|ConvertFrom-Json).remoteSha)}catch{}};return $null}
function Get-LastUpdate{if(Test-Path $updateState){try{return Get-Content $updateState -Raw|ConvertFrom-Json}catch{}};return $null}
function Get-WatcherState{if(Test-Path $watchState){try{return Get-Content $watchState -Raw|ConvertFrom-Json}catch{}};return $null}
function Get-BenchmarkState{if(Test-Path $benchmarkState){try{return Get-Content $benchmarkState -Raw|ConvertFrom-Json}catch{}};return $null}
function Get-ProspectEngineHealth{
  try{
    $health=Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:8796/health' -TimeoutSec 8
    $ui=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8796/prospects' -TimeoutSec 8
    $store=Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:8796/api/prospects' -TimeoutSec 8
    return [ordered]@{
      ok=([bool]$health.ok -and [string]$health.version -eq '2.0.0' -and [int]$ui.StatusCode -eq 200 -and [bool]$store.ok)
      version=[string]$health.version;route=[string]$health.prospectEngine;uiStatus=[int]$ui.StatusCode
      serverStore=[string]$health.prospectPersistence;outlookSendEnabled=[bool]$health.outlookSendEnabled
      leadCount=$(if($store.store -and $store.store.leads){@($store.store.leads).Count}else{0})
    }
  }catch{return [ordered]@{ok=$false;error=$_.Exception.Message}}
}
function Get-TailscaleCli{
  $c=Get-Command tailscale.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  $p='C:\Program Files\Tailscale\tailscale.exe';if(Test-Path $p){return $p};return $null
}
function Test-DeployPeer([string]$ip){
  if($ip -in @('127.0.0.1','::1')){return $true}
  if($ip -notmatch '^100\.(?:\d{1,3}\.){2}\d{1,3}$'){return $false}
  $ts=Get-TailscaleCli;if(-not $ts){return $false}
  try{$raw=(& $ts whois --json $ip 2>$null|Out-String);if($LASTEXITCODE -ne 0){return $false};return [bool]($raw -match '"tag:afz-deploy"')}catch{return $false}
}
function Start-H3QwenBenchmark([string]$jobId,[int]$startIteration,[int]$maxIterations,[string]$sha){
  if($jobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'invalid benchmark jobId'}
  if($sha -notmatch '^[0-9a-fA-F]{40}$'){throw 'invalid benchmark sha'}
  if($startIteration -lt 1 -or $startIteration -gt 8){throw 'invalid startIteration'}
  if($maxIterations -lt $startIteration -or $maxIterations -gt 8){throw 'invalid maxIterations'}
  $existing=Get-BenchmarkState
  if($existing -and [string]$existing.status -eq 'running'){
    $pidValue=0;try{$pidValue=[int]$existing.relayPid}catch{}
    if($pidValue -gt 0 -and (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)){
      if([string]$existing.jobId -eq $jobId){return [ordered]@{ok=$true;state='ALREADY_RUNNING';job=$existing}}
      throw "another H3 Qwen benchmark is already running: $($existing.jobId)"
    }
  }
  $relay=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Qwen27B-WebsiteBenchmark.ps1'
  if(-not(Test-Path $relay)){throw "benchmark relay missing: $relay"}
  $stateDir=Split-Path $benchmarkState -Parent;New-Item -ItemType Directory -Force -Path $stateDir|Out-Null
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$relay`" -InstallRoot `"$InstallRoot`" -JobId `"$jobId`" -StartIteration $startIteration -MaxIterations $maxIterations -ExpectedSha `"$sha`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  $queued=[ordered]@{ok=$true;jobId=$jobId;status='running';message='H3 Qwen benchmark relay started.';worker='H3';host='DESKTOP-H3R6CQN';model='qwen3.8:27b';project='qwen38-27b-website-benchmark';relayPid=$p.Id;startedAt=(Get-Date -Format o);updatedAt=(Get-Date -Format o);expectedSha=$sha;startIteration=$startIteration;maxIterations=$maxIterations}
  $queued|ConvertTo-Json -Depth 10 -Compress|Set-Content -LiteralPath $benchmarkState -Encoding UTF8
  return [ordered]@{ok=$true;state='STARTED';job=$queued}
}
function Invoke-QueueOrphanRemediation([string]$action,[string]$taskId){
  if($action -notin @('audit','apply')){throw 'unsupported queue remediation action'}
  if($taskId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,180}$'){throw 'invalid queue taskId'}
  $script=Join-Path $InstallRoot 'afz-openai-agent\Invoke-AFZ-Queue-Orphan-Remediation.ps1'
  if(-not(Test-Path -LiteralPath $script -PathType Leaf)){throw "queue remediation runner missing: $script"}
  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -Action $action -TaskId $taskId 2>&1 | Out-String).Trim()
  $code=$LASTEXITCODE
  if($code -ne 0){throw "queue remediation failed exit=$code output=$raw"}
  if([string]::IsNullOrWhiteSpace($raw)){throw 'queue remediation returned empty output'}
  try{return ($raw|ConvertFrom-Json)}catch{throw "queue remediation returned invalid JSON: $raw"}
}
function Invoke-WindowsWslMemoryAudit {
  $script=Join-Path $InstallRoot 'afz-openai-agent\Invoke-Windows-Wsl-Memory-Audit.ps1'
  if(-not(Test-Path -LiteralPath $script -PathType Leaf)){throw "WSL memory audit runner missing: $script"}
  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script 2>&1 | Out-String).Trim()
  $code=$LASTEXITCODE
  if($code -ne 0){throw "WSL memory audit failed exit=$code output=$raw"}
  if([string]::IsNullOrWhiteSpace($raw)){throw 'WSL memory audit returned empty output'}
  try{return ($raw|ConvertFrom-Json)}catch{throw "WSL memory audit returned invalid JSON: $raw"}
}
function Invoke-JellyfinVisibilityRepair([string]$Action){
  if($Action -notin @('audit','repair-exact-screenshot-user')){throw 'unsupported Jellyfin visibility action'}
  $script=Join-Path $InstallRoot 'afz-openai-agent\tools\Jellyfin-Visibility-Repair.ps1'
  if(-not(Test-Path -LiteralPath $script -PathType Leaf)){throw "Jellyfin visibility runner missing: $script"}
  $mode=$(if($Action -eq 'audit'){'audit'}else{'repair'})
  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -Action $mode 2>&1 | Out-String).Trim()
  $code=$LASTEXITCODE
  if($code -ne 0){throw "Jellyfin visibility runner failed exit=$code output=$raw"}
  if([string]::IsNullOrWhiteSpace($raw)){throw 'Jellyfin visibility runner returned empty output'}
  try{return ($raw|ConvertFrom-Json)}catch{throw "Jellyfin visibility runner returned invalid JSON: $raw"}
}
function Invoke-MovieRecommenderCatalogDirect([string]$Action){
  if($Action -ne 'audit'){throw 'unsupported MovieRecommender catalog action'}
  $runner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-MovieRecommender-Catalog-Direct.ps1'
  if(-not(Test-Path -LiteralPath $runner -PathType Leaf)){throw "MovieRecommender catalog runner missing: $runner"}
  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -Action $Action 2>&1 | Out-String).Trim()
  $code=$LASTEXITCODE
  if($code -ne 0){throw "MovieRecommender catalog runner failed exit=$code output=$raw"}
  if([string]::IsNullOrWhiteSpace($raw)){throw 'MovieRecommender catalog runner returned empty output'}
  try{return ($raw|ConvertFrom-Json)}catch{throw "MovieRecommender catalog runner returned invalid JSON: $raw"}
}

function Invoke-StremioOrganize([string]$Action){
  if($Action -notin @('audit','apply')){throw 'unsupported Stremio organize action'}
  $runner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-Stremio-Organize.ps1'
  if(-not(Test-Path -LiteralPath $runner -PathType Leaf)){throw "Stremio organizer runner missing: $runner"}
  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -Action $Action -InstallRoot $InstallRoot 2>&1 | Out-String).Trim()
  $code=$LASTEXITCODE
  if($code -ne 0){throw "Stremio organizer failed exit=$code output=$raw"}
  if([string]::IsNullOrWhiteSpace($raw)){throw 'Stremio organizer returned empty output'}
  try{return ($raw|ConvertFrom-Json)}catch{throw "Stremio organizer returned invalid JSON: $raw"}
}

function Invoke-HermesRadioHilalCronAudit {
  $runner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-Hermes-RadioHilalCronAudit.ps1'
  if(-not(Test-Path -LiteralPath $runner -PathType Leaf)){throw "Hermes RadioHilal cron audit runner missing: $runner"}
  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -JobId '9d9eea1b7618' 2>&1 | Out-String).Trim()
  $code=$LASTEXITCODE
  if([string]::IsNullOrWhiteSpace($raw)){throw 'Hermes RadioHilal cron audit returned empty output'}
  $parsed=$null
  try{$parsed=$raw|ConvertFrom-Json}catch{throw "Hermes RadioHilal cron audit returned invalid JSON: $raw"}
  if($code -notin @(0,20,21)){throw "Hermes RadioHilal cron audit failed exit=$code output=$raw"}
  return $parsed
}

function Invoke-HPEnvySurfsharkExitNode([string]$Action){
  if($Action -notin @('audit','apply')){throw 'unsupported HP Envy Surfshark action'}
  $runner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-HPEnvy-Surfshark-ExitNode.ps1'
  $request=Join-Path $InstallRoot 'afz-openai-agent\requests\hpenvy-surfshark-exitnode.json'
  if(-not(Test-Path -LiteralPath $runner -PathType Leaf)){throw "HP Envy Surfshark runner missing: $runner"}
  if(-not(Test-Path -LiteralPath $request -PathType Leaf)){throw "HP Envy Surfshark request missing: $request"}
  $contract=Get-Content -LiteralPath $request -Raw -Encoding UTF8|ConvertFrom-Json
  if([string]$contract.taskName -ne 'HP Envy Surfshark Exit Node'){throw 'HP Envy Surfshark request task mismatch'}
  if([string]$contract.target -ne 'coolyo@100.71.26.69'){throw 'HP Envy Surfshark request target mismatch'}
  if(([string]$contract.mode).Trim().ToLowerInvariant() -ne $Action){throw 'HP Envy Surfshark request mode mismatch'}
  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -InstallRoot $InstallRoot -RequestPath $request 2>&1 | Out-String).Trim()
  if([string]::IsNullOrWhiteSpace($raw)){throw 'HP Envy Surfshark runner returned empty output'}
  try{return ($raw|ConvertFrom-Json)}catch{throw "HP Envy Surfshark runner returned invalid JSON: $raw"}
}

function Invoke-H3OllamaRepair0332 {
  $runner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Ollama-AppRepair0332.ps1'
  if(-not(Test-Path -LiteralPath $runner -PathType Leaf)){throw "H3 Ollama repair runner missing: $runner"}
  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -InstallRoot $InstallRoot 2>&1|Out-String).Trim()
  $code=$LASTEXITCODE
  if([string]::IsNullOrWhiteSpace($raw)){throw 'H3 Ollama repair returned empty output'}
  $parsed=$null
  try{$parsed=$raw|ConvertFrom-Json}catch{throw "H3 Ollama repair returned invalid JSON: $raw"}
  if($code -ne 0 -or -not [bool]$parsed.ok){throw "H3 Ollama repair failed exit=$code classification=$([string]$parsed.classification)"}
  return $parsed
}

$listener=New-Object Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
if($BindHost -and $BindHost -ne '127.0.0.1'){$listener.Prefixes.Add("http://$BindHost`:$Port/")}
$listener.Start()
Log "START version=1.10.2 port=$Port bind=$BindHost deploy=github-fast-signal interval=3s h3QwenBenchmark=typed queueOrphanRemediation=typed windowsWslMemoryAudit=typed-readonly jellyfinVisibilityRepair=typed hpEnvySurfsharkExitNode=typed-fixed-target prospectEngineProbe=enabled"
try{
  while($listener.IsListening){$ctx=$listener.GetContext();try{
    $ip=Get-RemoteIp $ctx;$path=$ctx.Request.Url.AbsolutePath.TrimEnd('/')

    if($path -eq '/api/push-deploy' -and $ctx.Request.HttpMethod -eq 'POST'){
      if(-not(Test-DeployPeer $ip)){Send-Json $ctx 403 @{ok=$false;error='deploy peer not authorized';client=$ip};continue}
      $req=Read-Json $ctx;$repo=[string]$req.repository;$ref=[string]$req.ref;$sha=([string]$req.sha).Trim().ToLowerInvariant()
      if($repo -ne 'f3arif/homelab-control' -or $ref -ne 'refs/heads/main' -or $sha -notmatch '^[0-9a-f]{40}$'){Send-Json $ctx 400 @{ok=$false;error='invalid push deploy payload'};continue}
      $r=Start-ExactShaUpdate $sha;Log "optional push deploy sha=$sha requested by $ip";Send-Json $ctx 202 $r;continue
    }

    if($path -eq '/api/h3-qwen27b-benchmark' -and $ctx.Request.HttpMethod -eq 'POST'){
      if(-not(Test-DeployPeer $ip)){Send-Json $ctx 403 @{ok=$false;error='benchmark peer not authorized';client=$ip};continue}
      $req=Read-Json $ctx;$action=([string]$req.action).Trim().ToLowerInvariant()
      if($action -eq 'status'){
        $s=Get-BenchmarkState;if(-not $s){Send-Json $ctx 404 @{ok=$false;error='no benchmark state'};continue}
        $requested=[string]$req.jobId;if($requested -and $requested -ne [string]$s.jobId){Send-Json $ctx 404 @{ok=$false;error='benchmark job not found';jobId=$requested};continue}
        Send-Json $ctx 200 $s;continue
      }
      if($action -ne 'start'){Send-Json $ctx 400 @{ok=$false;error='unsupported benchmark action'};continue}
      $repo=[string]$req.repository;$ref=[string]$req.ref;$sha=([string]$req.sha).Trim().ToLowerInvariant();$jobId=[string]$req.jobId
      $startIteration=2;$maxIterations=5;try{if($null -ne $req.startIteration){$startIteration=[int]$req.startIteration}}catch{};try{if($null -ne $req.maxIterations){$maxIterations=[int]$req.maxIterations}}catch{}
      if($repo -ne 'f3arif/homelab-control' -or $ref -ne 'refs/heads/main' -or $sha -notmatch '^[0-9a-f]{40}$'){Send-Json $ctx 400 @{ok=$false;error='invalid benchmark source payload'};continue}
      $r=Start-H3QwenBenchmark $jobId $startIteration $maxIterations $sha;Log "h3 qwen benchmark action=start job=$jobId sha=$sha requested by $ip";Send-Json $ctx 202 $r;continue
    }

    if($path -eq '/api/h3-ollama-repair0332' -and $ctx.Request.HttpMethod -eq 'POST'){
      if(-not(Test-DeployPeer $ip)){Send-Json $ctx 403 @{ok=$false;error='H3 Ollama repair peer not authorized';client=$ip};continue}
      $req=Read-Json $ctx;$action=([string]$req.action).Trim().ToLowerInvariant()
      $repo=[string]$req.repository;$ref=[string]$req.ref;$sha=([string]$req.sha).Trim().ToLowerInvariant();$current=([string](Get-Commit)).Trim().ToLowerInvariant()
      if($action -ne 'apply'){Send-Json $ctx 400 @{ok=$false;error='unsupported H3 Ollama repair action'};continue}
      if($repo -ne 'f3arif/homelab-control' -or $ref -ne 'refs/heads/main' -or $sha -notmatch '^[0-9a-f]{40}$' -or $sha -ne $current){Send-Json $ctx 409 @{ok=$false;error='H3 Ollama repair source mismatch';current=$current;requested=$sha};continue}
      $r=Invoke-H3OllamaRepair0332
      Log "H3 Ollama repair action=apply classification=$([string]$r.classification) sha=$sha requested by $ip"
      Send-Json $ctx 200 $r
      continue
    }

    if($path -eq '/api/queue-orphan-remediation' -and $ctx.Request.HttpMethod -eq 'POST'){
      if(-not(Test-DeployPeer $ip)){Send-Json $ctx 403 @{ok=$false;error='queue remediation peer not authorized';client=$ip};continue}
      $req=Read-Json $ctx;$action=([string]$req.action).Trim().ToLowerInvariant();$taskId=[string]$req.taskId
      $repo=[string]$req.repository;$ref=[string]$req.ref;$sha=([string]$req.sha).Trim().ToLowerInvariant();$current=([string](Get-Commit)).Trim().ToLowerInvariant()
      if($repo -ne 'f3arif/homelab-control' -or $ref -ne 'refs/heads/main' -or $sha -notmatch '^[0-9a-f]{40}$' -or $sha -ne $current){Send-Json $ctx 409 @{ok=$false;error='queue remediation source mismatch';current=$current;requested=$sha};continue}
      $r=Invoke-QueueOrphanRemediation $action $taskId;Log "queue orphan remediation action=$action task=$taskId sha=$sha requested by $ip";Send-Json $ctx 200 $r;continue
    }

    if($path -eq '/api/windows-wsl-memory-audit' -and $ctx.Request.HttpMethod -eq 'POST'){
      if(-not((Test-DeployPeer $ip) -or ((Get-AllowedClients) -contains $ip))){Send-Json $ctx 403 @{ok=$false;error='WSL memory audit peer not authorized';client=$ip};continue}
      $req=Read-Json $ctx;$action=([string]$req.action).Trim().ToLowerInvariant()
      $repo=[string]$req.repository;$ref=[string]$req.ref;$sha=([string]$req.sha).Trim().ToLowerInvariant();$current=([string](Get-Commit)).Trim().ToLowerInvariant()
      if($action -ne 'audit'){Send-Json $ctx 400 @{ok=$false;error='unsupported WSL memory audit action'};continue}
      if($repo -ne 'f3arif/homelab-control' -or $ref -ne 'refs/heads/main' -or $sha -notmatch '^[0-9a-f]{40}$' -or $sha -ne $current){Send-Json $ctx 409 @{ok=$false;error='WSL memory audit source mismatch';current=$current;requested=$sha};continue}
      $r=Invoke-WindowsWslMemoryAudit;Log "windows WSL memory audit action=audit sha=$sha requested by $ip";Send-Json $ctx 200 $r;continue
    }

    if($path -eq '/api/jellyfin-visibility-repair' -and $ctx.Request.HttpMethod -eq 'POST'){
      if(-not(Test-DeployPeer $ip)){Send-Json $ctx 403 @{ok=$false;error='Jellyfin visibility peer not authorized';client=$ip};continue}
      $req=Read-Json $ctx;$action=([string]$req.action).Trim().ToLowerInvariant()
      $repo=[string]$req.repository;$ref=[string]$req.ref;$sha=([string]$req.sha).Trim().ToLowerInvariant();$current=([string](Get-Commit)).Trim().ToLowerInvariant()
      if($action -notin @('audit','repair-exact-screenshot-user')){Send-Json $ctx 400 @{ok=$false;error='unsupported Jellyfin visibility action'};continue}
      if($repo -ne 'f3arif/homelab-control' -or $ref -ne 'refs/heads/main' -or $sha -notmatch '^[0-9a-f]{40}$' -or $sha -ne $current){Send-Json $ctx 409 @{ok=$false;error='Jellyfin visibility source mismatch';current=$current;requested=$sha};continue}
      $r=Invoke-JellyfinVisibilityRepair $action;Log "Jellyfin visibility action=$action sha=$sha requested by $ip";Send-Json $ctx 200 $r;continue
    }

    if($path -eq '/api/movierecommender-catalog' -and $ctx.Request.HttpMethod -eq 'POST'){
      if(-not(Test-DeployPeer $ip)){Send-Json $ctx 403 @{ok=$false;error='MovieRecommender catalog peer not authorized';client=$ip};continue}
      $req=Read-Json $ctx
      $action=([string]$req.action).Trim().ToLowerInvariant()
      $repo=[string]$req.repository
      $ref=[string]$req.ref
      $sha=([string]$req.sha).Trim().ToLowerInvariant()
      $current=([string](Get-Commit)).Trim().ToLowerInvariant()
      if($action -ne 'audit'){Send-Json $ctx 400 @{ok=$false;error='unsupported MovieRecommender catalog action'};continue}
      if($repo -ne 'f3arif/homelab-control' -or $ref -ne 'refs/heads/main' -or $sha -notmatch '^[0-9a-f]{40}$' -or $sha -ne $current){Send-Json $ctx 409 @{ok=$false;error='MovieRecommender catalog source mismatch';current=$current;requested=$sha};continue}
      $r=Invoke-MovieRecommenderCatalogDirect $action
      Log "MovieRecommender catalog action=$action sha=$sha requested by $ip"
      Send-Json $ctx 200 $r
      continue
    }

    if($path -eq '/api/stremio-organize' -and $ctx.Request.HttpMethod -eq 'POST'){
      if(-not(Test-DeployPeer $ip)){Send-Json $ctx 403 @{ok=$false;error='Stremio organizer peer not authorized';client=$ip};continue}
      $req=Read-Json $ctx
      $action=([string]$req.action).Trim().ToLowerInvariant()
      $repo=[string]$req.repository
      $ref=[string]$req.ref
      $sha=([string]$req.sha).Trim().ToLowerInvariant()
      $current=([string](Get-Commit)).Trim().ToLowerInvariant()
      if($action -notin @('audit','apply')){Send-Json $ctx 400 @{ok=$false;error='unsupported Stremio organize action'};continue}
      if($repo -ne 'f3arif/homelab-control' -or $ref -ne 'refs/heads/main' -or $sha -notmatch '^[0-9a-f]{40}$' -or $sha -ne $current){Send-Json $ctx 409 @{ok=$false;error='Stremio organizer source mismatch';current=$current;requested=$sha};continue}
      $r=Invoke-StremioOrganize $action
      Log "Stremio organize action=$action changed=$([string]$r.changed) sha=$sha requested by $ip"
      Send-Json $ctx 200 $r
      continue
    }

    if($path -eq '/api/hermes-radiohilal-cron' -and $ctx.Request.HttpMethod -eq 'POST'){
      if(-not(Test-DeployPeer $ip)){Send-Json $ctx 403 @{ok=$false;error='Hermes RadioHilal cron audit peer not authorized';client=$ip};continue}
      $req=Read-Json $ctx
      $action=([string]$req.action).Trim().ToLowerInvariant()
      $repo=[string]$req.repository
      $ref=[string]$req.ref
      $sha=([string]$req.sha).Trim().ToLowerInvariant()
      $current=([string](Get-Commit)).Trim().ToLowerInvariant()
      if($action -ne 'audit'){Send-Json $ctx 400 @{ok=$false;error='unsupported Hermes RadioHilal cron action'};continue}
      if($repo -ne 'f3arif/homelab-control' -or $ref -ne 'refs/heads/main' -or $sha -notmatch '^[0-9a-f]{40}$' -or $sha -ne $current){Send-Json $ctx 409 @{ok=$false;error='Hermes RadioHilal cron audit source mismatch';current=$current;requested=$sha};continue}
      $r=Invoke-HermesRadioHilalCronAudit
      Log "Hermes RadioHilal cron action=audit classification=$([string]$r.classification) sha=$sha requested by $ip"
      Send-Json $ctx 200 $r
      continue
    }

    if($path -eq '/api/hpenvy-surfshark-exitnode' -and $ctx.Request.HttpMethod -eq 'POST'){
      if(-not(Test-DeployPeer $ip)){Send-Json $ctx 403 @{ok=$false;error='HP Envy Surfshark peer not authorized';client=$ip};continue}
      $req=Read-Json $ctx;$action=([string]$req.action).Trim().ToLowerInvariant()
      $repo=[string]$req.repository;$ref=[string]$req.ref;$sha=([string]$req.sha).Trim().ToLowerInvariant();$current=([string](Get-Commit)).Trim().ToLowerInvariant()
      if($action -notin @('audit','apply')){Send-Json $ctx 400 @{ok=$false;error='unsupported HP Envy Surfshark action'};continue}
      if($repo -ne 'f3arif/homelab-control' -or $ref -ne 'refs/heads/main' -or $sha -notmatch '^[0-9a-f]{40}$' -or $sha -ne $current){Send-Json $ctx 409 @{ok=$false;error='HP Envy Surfshark source mismatch';current=$current;requested=$sha};continue}
      $r=Invoke-HPEnvySurfsharkExitNode $action;Log "HP Envy Surfshark action=$action classification=$([string]$r.classification) sha=$sha requested by $ip";Send-Json $ctx 200 $r;continue
    }

    $fixedClient=((Get-AllowedClients) -contains $ip)
    $deployHealthPeer=($path -eq '/health' -and $ctx.Request.HttpMethod -eq 'GET' -and (Test-DeployPeer $ip))
    if(-not($fixedClient -or $deployHealthPeer)){Send-Json $ctx 403 @{ok=$false;error='client not allowlisted';client=$ip};continue}
    if($ctx.Request.HttpMethod -eq 'OPTIONS'){Send-Json $ctx 200 @{ok=$true};continue}
    if($path -eq ''){$html=@'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AFZ Agent Control</title><style>body{font:16px system-ui;background:#0b1220;color:#e6edf7;margin:0;padding:32px}.card{max-width:760px;background:#111b2e;border:1px solid #26344d;border-radius:14px;padding:20px}.good{color:#79e2a8}.muted{color:#95a8c7}pre{white-space:pre-wrap;background:#08101d;padding:16px;border-radius:10px;overflow:auto}</style></head><body><div class="card"><h2>AFZ Agent Control</h2><p><span class="good">FAST AUTO DEPLOY ENABLED</span> ┬╖ GitHub publishes the exact pushed SHA and Windows-main watches it every 3 seconds.</p><p class="muted">Typed H3 Qwen benchmark, guarded queue-orphan remediation, read-only Windows WSL audit, guarded Jellyfin visibility recovery, and fixed-target HP Envy Surfshark exit-node control are available to the authorized GitHub/Tailscale deploy identity. No arbitrary shell is exposed.</p><pre id="o">Loading statusΓÇª</pre></div><script>const o=document.getElementById('o');async function refresh(){try{const r=await fetch('/health',{cache:'no-store'});const j=await r.json();o.textContent=JSON.stringify(j,null,2)}catch(e){o.textContent=e.message}}refresh();setInterval(refresh,3000)</script></body></html>
'@;Send-Html $ctx $html;continue}
    if($path -eq '/health' -and $ctx.Request.HttpMethod -eq 'GET'){
      $u=Get-LastUpdate;$w=Get-WatcherState;$b=Get-BenchmarkState;$p=Get-ProspectEngineHealth;$task=Get-ScheduledTask -TaskName 'AFZ OpenAI Agent Updater' -ErrorAction SilentlyContinue
      Send-Json $ctx 200 @{ok=$true;service='AFZ-Agent-Control';version='1.10.2';commit=(Get-Commit);transport='github-fast-signal+exact-sha+codeload';fastAutoDeploy=$true;fastSignalIntervalSeconds=3;watcherStatus=$(if($w){$w.status}else{'starting'});watcherSignalSha=$(if($w){$w.signalSha}else{$null});watcherTime=$(if($w){$w.time}else{$null});fallbackCadenceSeconds=60;updateTask=$(if($task){[string]$task.State}else{'Missing'});lastUpdate=$(if($u){$u.finishedAt}else{$null});lastUpdateOk=$(if($u){[bool]$u.ok}else{$null});lastTrigger=$(if($u){$u.trigger}else{$null});prospectEngine=$p;h3QwenBenchmark=$(if($b){$b}else{$null});queueOrphanRemediation=@{typed=$true;route='/api/queue-orphan-remediation';actions=@('audit','apply');arbitraryShell=$false};hermesRadioHilalCron=@{typed=$true;route='/api/hermes-radiohilal-cron';actions=@('audit');jobId='9d9eea1b7618';readOnly=$true;arbitraryShell=$false};windowsWslMemoryAudit=@{typed=$true;route='/api/windows-wsl-memory-audit';actions=@('audit');readOnly=$true;arbitraryShell=$false};jellyfinVisibilityRepair=@{typed=$true;route='/api/jellyfin-visibility-repair';actions=@('audit','repair-exact-screenshot-user');exactScreenshotMatchRequired=$true;arbitraryShell=$false};stremioOrganize=@{typed=$true;route='/api/stremio-organize';actions=@('audit','apply');arbitraryShell=$false};hpEnvySurfsharkExitNode=@{typed=$true;route='/api/hpenvy-surfshark-exitnode';actions=@('audit','apply');fixedTarget='coolyo@100.71.26.69';localAuthorizationSentinelRequired=$true;arbitraryShell=$false};time=(Get-Date -Format o)};continue
    }
    if($path -eq '/api/update-now' -and $ctx.Request.HttpMethod -eq 'POST'){$r=Start-Update;Log "fallback update requested by $ip";Send-Json $ctx 202 $r;continue}
    if($path -eq '/api/control' -and $ctx.Request.HttpMethod -eq 'POST'){$req=Read-Json $ctx;$action=[string]$req.action;if($action -notin @('update-agent','update-openai-agent','pull-agent-now')){Send-Json $ctx 400 @{ok=$false;error='unsupported action'};continue};$r=Start-Update;Log "control action=$action requested by $ip";Send-Json $ctx 202 $r;continue}
    Send-Json $ctx 404 @{ok=$false;error='not found'}
  }catch{try{Send-Json $ctx 500 @{ok=$false;error=$_.Exception.Message}}catch{}}}
}finally{try{$listener.Stop()}catch{};try{$listener.Close()}catch{};Log 'STOP'}
