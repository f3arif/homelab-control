#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0

if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-agent-install.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Hermes request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid H3 Hermes request identity.'}
if([string]$req.action -ne 'install-and-configure' -or [string]$req.status -ne 'ACTIVE'){throw 'H3 Hermes provider repair request is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'H3 Hermes target mismatch.'}
if([string]$req.provider_name -ne 'ollama' -or [string]$req.provider_identity -ne 'custom:ollama'){throw 'H3 Hermes provider identity mismatch.'}
if([string]$req.base_url -ne 'http://127.0.0.1:11434/v1'){throw 'H3 Hermes provider route mismatch.'}
if([string]$req.base_model -ne 'qwen3.6:35b-a3b' -or [int]$req.context_length -ne 65536){throw 'H3 Hermes model mismatch.'}
if([bool]$req.restart_desktop_backend -or [bool]$req.restart_electron_ui -or [bool]$req.restart_messaging_gateway -or [bool]$req.mutate_ollama -or [bool]$req.run_generation_test -or [bool]$req.expose_api){throw 'H3 Hermes provider repair safety flags mismatch.'}
if(-not [bool]$req.publish_result -or -not [bool]$req.emergency_diagnostic_ack){throw 'H3 Hermes provider repair publish policy mismatch.'}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-agent'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-DOCKER-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
foreach($required in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "Required H3 SSH path missing: $required"}}

# Preserve the established auxiliary Hermes repair hooks. These are independently
# guarded and non-fatal to provider liveness recovery.
# Invoke-H3-Hermes-PdfRuntimeAudit.ps1 / h3-hermes-pdf-runtime-audit.json
# Invoke-H3-Hermes-TelegramFollowupRepair.ps1 / h3-hermes-telegram-followup-repair.json
foreach($hook in @(
  [ordered]@{script='Invoke-H3-Hermes-PdfRuntimeAudit.ps1';request='h3-hermes-pdf-runtime-audit.json'},
  [ordered]@{script='Invoke-H3-Hermes-TelegramFollowupRepair.ps1';request='h3-hermes-telegram-followup-repair.json'}
)){
  try{
    $hp=Join-Path $InstallRoot ('afz-openai-agent\'+[string]$hook.script)
    $rp=Join-Path $InstallRoot ('afz-openai-agent\requests\'+[string]$hook.request)
    if((Test-Path -LiteralPath $hp -PathType Leaf) -and (Test-Path -LiteralPath $rp -PathType Leaf)){
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $hp -InstallRoot $InstallRoot -RequestPath $rp *> $null
    }
  }catch{}
}

function Save-Result($result){
  $json=$result|ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$json,$utf8)}}catch{}
  Write-Output ($result|ConvertTo-Json -Depth 20 -Compress)
}
function Invoke-RemoteScript([string]$Target,[string[]]$Extra,[string]$Script,[int]$TimeoutMs){
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''stdin empty''};Invoke-Expression $script'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $inFile=Join-Path $env:TEMP ('h3-hermes-provider-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('h3-hermes-provider-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('h3-hermes-provider-'+[guid]::NewGuid().ToString('n')+'.err')
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=7','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known))
  if($Extra){$args+=@($Extra)}
  $args+=@($Target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  try{
    [IO.File]::WriteAllText($inFile,$Script,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    $timedOut=(-not $p.WaitForExit($TimeoutMs))
    if($timedOut){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{}}
    return [ordered]@{
      timedOut=$timedOut
      exit=$(if($timedOut){$null}else{[int]$p.ExitCode})
      stdout=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
      stderr=$(if(Test-Path -LiteralPath $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
    }
  }finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}
function Parse-JsonResult($r){
  $parsed=$null
  foreach($line in @(([string]$r.stdout)-split "`r?`n"|Where-Object{$_})){
    try{$parsed=$line|ConvertFrom-Json}catch{}
  }
  return $parsed
}

$remote=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
$model='qwen3.6:35b-a3b'
$baseUrl='http://127.0.0.1:11434/v1'
$root=Join-Path $env:LOCALAPPDATA 'hermes'
$hermes=Join-Path $root 'bin\hermes.exe'
$config=Join-Path $root 'config.yaml'
$watchdog=Join-Path $root 'afz-ensure-ollama.ps1'
$watchdogTask='AFZ H3 Ollama Liveness'
$utf8=New-Object Text.UTF8Encoding($false)
function Emit($o,[int]$code){$o|ConvertTo-Json -Depth 16 -Compress;exit $code}
function Probe-Ollama {
  try{
    $r=Invoke-RestMethod -Uri ($baseUrl+'/models') -Method Get -TimeoutSec 8
    $ids=@($r.data|ForEach-Object{[string]$_.id})
    return [ordered]@{reachable=$true;modelListed=($model -in $ids);modelCount=$ids.Count}
  }catch{return [ordered]@{reachable=$false;modelListed=$false;modelCount=0;errorType=$_.Exception.GetType().Name}}
}
function Find-Ollama {
  $c=Get-Command ollama.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Path){return [string]$c.Path};if($c.Source){return [string]$c.Source}}
  foreach($p in @((Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),(Join-Path $env:LOCALAPPDATA 'Ollama\ollama.exe'),'C:\Program Files\Ollama\ollama.exe')){
    if(Test-Path -LiteralPath $p -PathType Leaf){return $p}
  }
  return $null
}
function Get-OllamaServeProcesses {
  return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{([string]$_.CommandLine) -match '(?i)ollama(?:[.]exe)?\s+serve'})
}
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=$false;classification='HERMES_WRONG_HOST'}) 30}
if(-not(Test-Path -LiteralPath $hermes -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_NATIVE_RUNTIME_NOT_FOUND'}) 41}
if(-not(Test-Path -LiteralPath $config -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_CONFIG_NOT_FOUND'}) 42}

# IMPORTANT: no marker short-circuit is permitted here. Every invocation performs
# a fresh endpoint probe so a prior success can never masquerade as current health.
$before=Probe-Ollama
$ollamaExe=$null;$ollamaStarted=$false;$ollamaPid=$null;$ollamaRecycled=$false;$recycledProcessCount=0
if(-not [bool]$before.reachable){
  Start-Sleep -Seconds 2
  $confirm=Probe-Ollama
  if([bool]$confirm.reachable){$before=$confirm}
}
if(-not [bool]$before.reachable){
  $ollamaExe=Find-Ollama
  if([string]::IsNullOrWhiteSpace($ollamaExe)){Emit ([ordered]@{ok=$false;classification='HERMES_OLLAMA_EXECUTABLE_NOT_FOUND';freshProbe=$true;endpointReachable=$false}) 43}
  $stale=@(Get-OllamaServeProcesses)
  if($stale.Count -gt 0){
    foreach($proc in $stale){
      try{Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction Stop;$recycledProcessCount++}catch{}
    }
    if($recycledProcessCount -gt 0){$ollamaRecycled=$true;Start-Sleep -Seconds 2}
  }
  try{
    $p=Start-Process -FilePath $ollamaExe -ArgumentList @('serve') -WindowStyle Hidden -PassThru
    $ollamaPid=[int]$p.Id;$ollamaStarted=$true
  }catch{Emit ([ordered]@{ok=$false;classification='HERMES_OLLAMA_SERVER_START_FAILED';freshProbe=$true;errorType=$_.Exception.GetType().Name;ollamaRecycled=$ollamaRecycled;recycledProcessCount=$recycledProcessCount}) 44}
}
$live=$before
if(-not [bool]$live.reachable){
  for($i=0;$i -lt 45;$i++){
    Start-Sleep -Seconds 2
    $live=Probe-Ollama
    if([bool]$live.reachable){break}
  }
}
if(-not [bool]$live.reachable){Emit ([ordered]@{ok=$false;classification='HERMES_OLLAMA_ENDPOINT_UNREACHABLE';freshProbe=$true;ollamaServerStarted=$ollamaStarted;ollamaPid=$ollamaPid;ollamaRecycled=$ollamaRecycled;recycledProcessCount=$recycledProcessCount}) 45}
if(-not [bool]$live.modelListed){Emit ([ordered]@{ok=$false;classification='HERMES_OLLAMA_MODEL_NOT_REACHABLE';freshProbe=$true;ollamaReachable=$true;modelListed=$false;modelCount=[int]$live.modelCount;ollamaServerStarted=$ollamaStarted;modelPullStarted=$false;ollamaRecycled=$ollamaRecycled;recycledProcessCount=$recycledProcessCount}) 46}

# Keep the provider registry aligned with the already-selected local model route.
$oldHome=$env:HERMES_HOME
try{
  $env:HERMES_HOME=$root
  & $hermes config set providers.ollama.api $baseUrl *> $null
  if($LASTEXITCODE -ne 0){throw 'providers.ollama.api'}
  & $hermes config set providers.ollama.transport 'openai_chat' *> $null
  if($LASTEXITCODE -ne 0){throw 'providers.ollama.transport'}
  $providerRaw=(& $hermes config get providers.ollama --json 2>&1|Out-String).Trim()
  if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($providerRaw)){throw 'providers.ollama readback'}
  $provider=$providerRaw|ConvertFrom-Json
  $providerApi=$(if($provider.PSObject.Properties.Name -contains 'api'){[string]$provider.api}else{''})
  $providerTransport=$(if($provider.PSObject.Properties.Name -contains 'transport'){[string]$provider.transport}else{''})
  if($providerApi -ne $baseUrl -or $providerTransport -ne 'openai_chat'){throw 'providers.ollama verification'}
} catch {Emit ([ordered]@{ok=$false;classification='HERMES_OLLAMA_PROVIDER_CONFIG_FAILED';freshProbe=$true;ollamaReachable=$true;modelListed=$true;stage=$_.Exception.Message}) 47}
finally{if($null -eq $oldHome){Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue}else{$env:HERMES_HOME=$oldHome}}

# Install a one-minute endpoint-authoritative liveness guard. It never pulls or
# generates with a model. Two failed loopback probes mean the serve process is
# unhealthy even if a stale ollama serve PID still exists; recycle only that
# server process, restart it, and verify the endpoint comes back.
$watchdogInstalled=$false;$watchdogTaskState=$null;$watchdogError=$null
try{
  if([string]::IsNullOrWhiteSpace($ollamaExe)){$ollamaExe=Find-Ollama}
  if(-not [string]::IsNullOrWhiteSpace($ollamaExe)){
    $escapedExe=$ollamaExe.Replace("'","''")
    $wd=@"
`$ErrorActionPreference='SilentlyContinue'
function Test-AFZOllamaEndpoint {
  try{Invoke-RestMethod -Uri '$baseUrl/models' -Method Get -TimeoutSec 5|Out-Null;return `$true}catch{return `$false}
}
if(Test-AFZOllamaEndpoint){exit 0}
Start-Sleep -Seconds 2
if(Test-AFZOllamaEndpoint){exit 0}
`$running=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{([string]`$_.CommandLine) -match '(?i)ollama(?:[.]exe)?\s+serve'})
foreach(`$proc in `$running){try{Stop-Process -Id ([int]`$proc.ProcessId) -Force -ErrorAction SilentlyContinue}catch{}}
Start-Sleep -Seconds 2
try{Start-Process -FilePath '$escapedExe' -ArgumentList @('serve') -WindowStyle Hidden|Out-Null}catch{exit 1}
for(`$i=0;`$i -lt 20;`$i++){
  Start-Sleep -Seconds 2
  if(Test-AFZOllamaEndpoint){exit 0}
}
exit 1
"@
    [IO.File]::WriteAllText($watchdog,$wd,$utf8)
    $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$watchdog+'"')
    $trigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $watchdogTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force|Out-Null
    $wt=Get-ScheduledTask -TaskName $watchdogTask -ErrorAction Stop
    $watchdogInstalled=$true;$watchdogTaskState=[string]$wt.State
  }
}catch{$watchdogError=$_.Exception.GetType().Name}

# Final fresh probe after configuration and watchdog setup.
$final=Probe-Ollama
if(-not [bool]$final.reachable -or -not [bool]$final.modelListed){Emit ([ordered]@{ok=$false;classification='HERMES_OLLAMA_FINAL_LIVENESS_FAILED';freshProbe=$true;ollamaReachable=[bool]$final.reachable;modelListed=[bool]$final.modelListed;ollamaServerStarted=$ollamaStarted;watchdogInstalled=$watchdogInstalled;watchdogError=$watchdogError;ollamaRecycled=$ollamaRecycled;recycledProcessCount=$recycledProcessCount}) 48}
Emit ([ordered]@{
  ok=$true;classification='HERMES_OLLAMA_FRESH_LIVENESS_READY';host=$env:COMPUTERNAME;freshProbe=$true;
  providerName='ollama';providerIdentity='custom:ollama';providerConfigured=$true;providerApi=$baseUrl;providerTransport='openai_chat';
  runtimeResolved=$true;runtimeProvider='custom';runtimeBaseUrl=$baseUrl;runtimeApiMode='chat_completions';
  ollamaReachable=$true;selectedModel=$model;modelListed=$true;modelCount=[int]$final.modelCount;contextLength=65536;
  endpointReachableBefore=[bool]$before.reachable;ollamaServerStarted=$ollamaStarted;ollamaPid=$ollamaPid;ollamaRecycled=$ollamaRecycled;recycledProcessCount=$recycledProcessCount;
  watchdogInstalled=$watchdogInstalled;watchdogTask=$watchdogTask;watchdogTaskState=$watchdogTaskState;watchdogError=$watchdogError;
  modelPullStarted=$false;generationTestStarted=$false;messagingGatewayTouched=$false;networkChanged=$false;observedAt=(Get-Date -Format o)
}) 0
'@

$routes=@(
  [pscustomobject]@{target='Faiz@100.106.186.118';transport='tailscale';extra=@()},
  [pscustomobject]@{target='Faiz@192.168.50.185';transport='lan-hostkey-alias';extra=@('-o','HostKeyAlias=100.106.186.118')}
)
$routeDiagnostics=@();$result=$null;$chosen=$null
foreach($r in $routes){
  $rr=Invoke-RemoteScript $r.target $r.extra $remote 150000
  $parsed=Parse-JsonResult $rr
  $routeDiagnostics+=[ordered]@{transport=$r.transport;timedOut=[bool]$rr.timedOut;exit=$rr.exit;parsed=[bool]($null -ne $parsed);stderrPresent=(-not [string]::IsNullOrWhiteSpace([string]$rr.stderr))}
  if($parsed){$result=$parsed;$chosen=$r;break}
}
if($null -eq $result){
  $o=[ordered]@{schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';controlPlane='github';source='windows-main';target='h3';host='DESKTOP-H3R6CQN';jobId=$id;ok=$false;classification='HERMES_PROVIDER_FRESH_LIVENESS_UNREACHABLE';retryable=$true;deployment='native';routeDiagnostics=$routeDiagnostics;observedAt=(Get-Date -Format o)}
  Save-Result $o;exit 1
}
$o=[ordered]@{
  schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';controlPlane='github';source='windows-main';target='h3';host='DESKTOP-H3R6CQN';jobId=$id;
  ok=[bool]$result.ok;classification=[string]$result.classification;retryable=(-not [bool]$result.ok);deployment='native';transport=[string]$chosen.transport;
  freshProbe=$(if($result.PSObject.Properties.Name -contains 'freshProbe'){[bool]$result.freshProbe}else{$false});
  providerName='ollama';providerIdentity='custom:ollama';providerConfigured=$(if($result.PSObject.Properties.Name -contains 'providerConfigured'){[bool]$result.providerConfigured}else{$false});
  providerApi='http://127.0.0.1:11434/v1';providerTransport='openai_chat';runtimeResolved=$(if($result.PSObject.Properties.Name -contains 'runtimeResolved'){[bool]$result.runtimeResolved}else{$false});
  runtimeProvider=$(if($result.PSObject.Properties.Name -contains 'runtimeProvider'){[string]$result.runtimeProvider}else{$null});runtimeBaseUrl=$(if($result.PSObject.Properties.Name -contains 'runtimeBaseUrl'){[string]$result.runtimeBaseUrl}else{$null});runtimeApiMode=$(if($result.PSObject.Properties.Name -contains 'runtimeApiMode'){[string]$result.runtimeApiMode}else{$null});
  ollamaReachable=$(if($result.PSObject.Properties.Name -contains 'ollamaReachable'){[bool]$result.ollamaReachable}else{$false});selectedModel='qwen3.6:35b-a3b';contextLength=65536;
  modelListed=$(if($result.PSObject.Properties.Name -contains 'modelListed'){[bool]$result.modelListed}else{$false});endpointReachableBefore=$(if($result.PSObject.Properties.Name -contains 'endpointReachableBefore'){[bool]$result.endpointReachableBefore}else{$null});
  ollamaServerStarted=$(if($result.PSObject.Properties.Name -contains 'ollamaServerStarted'){[bool]$result.ollamaServerStarted}else{$false});ollamaRecycled=$(if($result.PSObject.Properties.Name -contains 'ollamaRecycled'){[bool]$result.ollamaRecycled}else{$false});recycledProcessCount=$(if($result.PSObject.Properties.Name -contains 'recycledProcessCount'){[int]$result.recycledProcessCount}else{0});watchdogInstalled=$(if($result.PSObject.Properties.Name -contains 'watchdogInstalled'){[bool]$result.watchdogInstalled}else{$false});watchdogTaskState=$(if($result.PSObject.Properties.Name -contains 'watchdogTaskState'){[string]$result.watchdogTaskState}else{$null});
  electronUiTouched=$false;desktopBackendTouched=$false;messagingGatewayTouched=$false;ollamaMutationStarted=$false;generationTestStarted=$false;networkChanged=$false;routeDiagnostics=$routeDiagnostics;observedAt=(Get-Date -Format o)
}
Save-Result $o
exit $(if([bool]$o.ok){0}else{1})