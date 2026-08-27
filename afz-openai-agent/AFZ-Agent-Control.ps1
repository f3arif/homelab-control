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
function Send-Json($ctx,[int]$status,$obj){$json=$obj|ConvertTo-Json -Depth 20 -Compress;$b=[Text.Encoding]::UTF8.GetBytes($json);$ctx.Response.StatusCode=$status;$ctx.Response.ContentType='application/json; charset=utf-8';$ctx.Response.Headers['Cache-Control']='no-store';$ctx.Response.Headers['Access-Control-Allow-Origin']='*';$ctx.Response.Headers['Access-Control-Allow-Headers']='Content-Type';$ctx.Response.Headers['Access-Control-Allow-Methods']='GET,POST,OPTIONS';$ctx.Response.ContentLength64=$b.Length;$ctx.Response.OutputStream.Write($b,0,$b.Length);$ctx.Response.Close()}
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

$listener=New-Object Net.HttpListener;$listener.Prefixes.Add("http://127.0.0.1:$Port/");if($BindHost -and $BindHost -ne '127.0.0.1'){$listener.Prefixes.Add("http://$BindHost`:$Port/")};$listener.Start();Log "START version=1.5.0 port=$Port bind=$BindHost deploy=github-fast-signal interval=3s h3QwenBenchmark=typed"
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

    if(-not ((Get-AllowedClients) -contains $ip)){Send-Json $ctx 403 @{ok=$false;error='client not allowlisted';client=$ip};continue}
    if($ctx.Request.HttpMethod -eq 'OPTIONS'){Send-Json $ctx 200 @{ok=$true};continue}
    if($path -eq ''){$html=@'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AFZ Agent Control</title><style>body{font:16px system-ui;background:#0b1220;color:#e6edf7;margin:0;padding:32px}.card{max-width:760px;background:#111b2e;border:1px solid #26344d;border-radius:14px;padding:20px}.good{color:#79e2a8}.muted{color:#95a8c7}pre{white-space:pre-wrap;background:#08101d;padding:16px;border-radius:10px;overflow:auto}</style></head><body><div class="card"><h2>AFZ Agent Control</h2><p><span class="good">FAST AUTO DEPLOY ENABLED</span> · GitHub publishes the exact pushed SHA and Windows-main watches it every 3 seconds.</p><p class="muted">Typed H3 Qwen benchmark execution is available to the authorized GitHub/Tailscale deploy identity. No arbitrary shell is exposed.</p><pre id="o">Loading status…</pre></div><script>const o=document.getElementById('o');async function refresh(){try{const r=await fetch('/health',{cache:'no-store'});const j=await r.json();o.textContent=JSON.stringify(j,null,2)}catch(e){o.textContent=e.message}}refresh();setInterval(refresh,3000)</script></body></html>
'@;Send-Html $ctx $html;continue}
    if($path -eq '/health' -and $ctx.Request.HttpMethod -eq 'GET'){
      $u=Get-LastUpdate;$w=Get-WatcherState;$b=Get-BenchmarkState;$task=Get-ScheduledTask -TaskName 'AFZ OpenAI Agent Updater' -ErrorAction SilentlyContinue
      Send-Json $ctx 200 @{ok=$true;service='AFZ-Agent-Control';version='1.5.0';commit=(Get-Commit);transport='github-fast-signal+exact-sha+codeload';fastAutoDeploy=$true;fastSignalIntervalSeconds=3;watcherStatus=$(if($w){$w.status}else{'starting'});watcherSignalSha=$(if($w){$w.signalSha}else{$null});watcherTime=$(if($w){$w.time}else{$null});fallbackCadenceSeconds=60;updateTask=$(if($task){[string]$task.State}else{'Missing'});lastUpdate=$(if($u){$u.finishedAt}else{$null});lastUpdateOk=$(if($u){[bool]$u.ok}else{$null});lastTrigger=$(if($u){$u.trigger}else{$null});h3QwenBenchmark=$(if($b){$b}else{$null});time=(Get-Date -Format o)};continue
    }
    if($path -eq '/api/update-now' -and $ctx.Request.HttpMethod -eq 'POST'){$r=Start-Update;Log "fallback update requested by $ip";Send-Json $ctx 202 $r;continue}
    if($path -eq '/api/control' -and $ctx.Request.HttpMethod -eq 'POST'){$req=Read-Json $ctx;$action=[string]$req.action;if($action -notin @('update-agent','update-openai-agent','pull-agent-now')){Send-Json $ctx 400 @{ok=$false;error='unsupported action'};continue};$r=Start-Update;Log "control action=$action requested by $ip";Send-Json $ctx 202 $r;continue}
    Send-Json $ctx 404 @{ok=$false;error='not found'}
  }catch{try{Send-Json $ctx 500 @{ok=$false;error=$_.Exception.Message}}catch{}}}
}finally{try{$listener.Stop()}catch{};try{$listener.Close()}catch{};Log 'STOP'}
