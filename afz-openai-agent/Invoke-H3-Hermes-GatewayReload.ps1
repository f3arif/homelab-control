#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0

if([string]::IsNullOrWhiteSpace($RequestPath)){
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-gateway-reload.json'
}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Hermes gateway reload request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid H3 Hermes gateway reload request identity.'}
if([string]$req.action -ne 'reload-gateway-native' -or [string]$req.status -ne 'ACTIVE'){throw 'H3 Hermes gateway reload request is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'H3 Hermes gateway reload target mismatch.'}
$startIfMissing=($req.PSObject.Properties.Name -contains 'start_if_missing' -and [bool]$req.start_if_missing)
if(-not [bool]$req.require_empty_active_registry -or -not [bool]$req.use_native_restart -or -not $startIfMissing){throw 'H3 Hermes gateway reload/start guard mismatch.'}
if([bool]$req.change_provider -or [bool]$req.mutate_ollama -or [bool]$req.change_network -or [bool]$req.run_model_generation){throw 'H3 Hermes gateway reload forbidden mutation requested.'}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-gateway-reload'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-GATEWAY-RELOAD-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required H3 reload path missing: $p"}}

function Save-Result($o){
  $j=$o|ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($statePath,$j,$utf8)
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$j,$utf8)}}catch{}
  Write-Output ($o|ConvertTo-Json -Depth 20 -Compress)
}
function Invoke-RemoteScript([string]$Target,[string[]]$Extra,[string]$Script,[int]$TimeoutMs,[string]$Transport){
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''stdin empty''};Invoke-Expression $script'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $inFile=Join-Path $env:TEMP ('h3-gw-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('h3-gw-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('h3-gw-'+[guid]::NewGuid().ToString('n')+'.err')
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=7','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known))
  if($Extra){$args+=@($Extra)}
  $args+=@($Target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  try{
    [IO.File]::WriteAllText($inFile,$Script,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    $timedOut=(-not $p.WaitForExit($TimeoutMs))
    if($timedOut){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{}}
    $stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
    $stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
    return [pscustomobject]@{transport=$Transport;timedOut=$timedOut;exit=$(if($timedOut){$null}else{[int]$p.ExitCode});stdout=$stdout;stdoutBytes=[Text.Encoding]::UTF8.GetByteCount($stdout);stderrPresent=(-not [string]::IsNullOrWhiteSpace($stderr));stderrBytes=[Text.Encoding]::UTF8.GetByteCount($stderr)}
  }finally{Remove-Item $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}
function Parse-JsonResult($r){
  $parsed=$null
  foreach($line in @(([string]$r.stdout)-split "`r?`n"|Where-Object{$_})){try{$parsed=$line|ConvertFrom-Json}catch{}}
  return $parsed
}

$preflight=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
function Emit($o,[int]$code){$o|ConvertTo-Json -Depth 10 -Compress;exit $code}
try{
  if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=$false;classification='WRONG_HOST'}) 30}
  $root=Join-Path $env:LOCALAPPDATA 'hermes'
  $hermes=Join-Path $root 'bin\hermes.exe'
  $registry=Join-Path $root 'runtime\active_sessions.json'
  if(-not(Test-Path -LiteralPath $hermes -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_CLI_MISSING'}) 41}
  if(-not(Test-Path -LiteralPath $registry -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='REGISTRY_MISSING'}) 42}
  try{$reg=Get-Content -LiteralPath $registry -Raw -Encoding UTF8|ConvertFrom-Json}catch{Emit ([ordered]@{ok=$false;classification='REGISTRY_INVALID_JSON'}) 43}
  if(-not($reg.PSObject.Properties.Name -contains 'entries')){Emit ([ordered]@{ok=$false;classification='REGISTRY_SCHEMA_NOT_CANONICAL'}) 44}
  $entries=@($reg.entries)
  if($entries.Count -ne 0){Emit ([ordered]@{ok=$false;classification='REGISTRY_NOT_EMPTY';entryCount=$entries.Count}) 45}
  $procs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{([string]$_.Name)-match '(?i)python|hermes' -and ([string]$_.CommandLine)-match '(?i)hermes_cli[.]main' -and ([string]$_.CommandLine)-match '(?i)gateway\s+run'})
  $lifecycle=$(if($procs.Count -eq 0){'start'}else{'restart'})
  Emit ([ordered]@{ok=$true;classification=$(if($lifecycle -eq 'start'){'PREFLIGHT_START_NEEDED'}else{'PREFLIGHT_RESTART_READY'});registryEntryCount=0;lifecycle=$lifecycle;beforePids=@($procs|ForEach-Object{[int]$_.ProcessId})}) 0
}catch{Emit ([ordered]@{ok=$false;classification='PREFLIGHT_EXCEPTION';errorType=$_.Exception.GetType().Name}) 49}
'@

$routes=@(
  [pscustomobject]@{target='Faiz@100.106.186.118';transport='tailscale';extra=@()},
  [pscustomobject]@{target='Faiz@192.168.50.185';transport='lan-hostkey-alias';extra=@('-o','HostKeyAlias=100.106.186.118')}
)
$route=$null;$pre=$null;$routeDiagnostics=@()
foreach($r in $routes){
  $rr=Invoke-RemoteScript $r.target $r.extra $preflight 20000 $r.transport
  $pp=Parse-JsonResult $rr
  $routeDiagnostics+=[ordered]@{transport=$r.transport;timedOut=[bool]$rr.timedOut;exit=$rr.exit;stdoutBytes=[int]$rr.stdoutBytes;stderrPresent=[bool]$rr.stderrPresent;stderrBytes=[int]$rr.stderrBytes;parsed=[bool]($null -ne $pp)}
  if($pp){$route=$r;$pre=$pp;break}
}
if(-not $pre -or -not [bool]$pre.ok){
  Save-Result ([ordered]@{ok=$false;classification=$(if($pre){[string]$pre.classification}else{'HERMES_GATEWAY_RELOAD_PREFLIGHT_UNREACHABLE'});mutation='NONE';transport=$(if($route){$route.transport}else{$null});routeDiagnostics=$routeDiagnostics})
  exit 1
}
$beforePids=@($pre.beforePids|ForEach-Object{[int]$_})
$lifecycle=([string]$pre.lifecycle).ToLowerInvariant()
if($lifecycle -notin @('start','restart')){Save-Result ([ordered]@{ok=$false;classification='HERMES_GATEWAY_LIFECYCLE_INVALID';mutation='NONE'});exit 1}

# Native Windows Hermes lifecycle only. Existing gateways use `hermes gateway restart`;
# a missing gateway uses `hermes gateway start` so an unresponsive Telegram bot can recover.
$lifecycleScript=@'
$ErrorActionPreference='Continue'
$root=Join-Path $env:LOCALAPPDATA 'hermes'
$env:HERMES_HOME=$root
$hermes=Join-Path $root 'bin\hermes.exe'
& $hermes gateway __LIFECYCLE__ *> $null
exit $LASTEXITCODE
'@
$lifecycleScript=$lifecycleScript.Replace('__LIFECYCLE__',$lifecycle)
$lifecycleTransport=Invoke-RemoteScript $route.target $route.extra $lifecycleScript 35000 $route.transport

$post=@'
$ErrorActionPreference='Stop'
$procs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{([string]$_.Name)-match '(?i)python|hermes' -and ([string]$_.CommandLine)-match '(?i)hermes_cli[.]main' -and ([string]$_.CommandLine)-match '(?i)gateway\s+run'})
[ordered]@{ok=($procs.Count -gt 0);afterPids=@($procs|ForEach-Object{[int]$_.ProcessId});count=$procs.Count}|ConvertTo-Json -Compress
'@
$postParsed=$null
for($i=0;$i -lt 15 -and -not $postParsed;$i++){
  Start-Sleep -Seconds 2
  $pr=Invoke-RemoteScript $route.target $route.extra $post 15000 $route.transport
  $candidate=Parse-JsonResult $pr
  if($candidate -and [bool]$candidate.ok){$postParsed=$candidate}
}
if(-not $postParsed){
  Save-Result ([ordered]@{ok=$false;classification=$(if($lifecycle -eq 'start'){'HERMES_GATEWAY_START_POST_VERIFY_UNREACHABLE'}else{'HERMES_GATEWAY_RELOAD_POST_VERIFY_UNREACHABLE'});mutation=$(if($lifecycle -eq 'start'){'NATIVE_GATEWAY_START_ATTEMPTED'}else{'NATIVE_GATEWAY_RESTART_ATTEMPTED'});transport=$route.transport;registryEntryCount=0;beforePids=$beforePids;lifecycle=$lifecycle;lifecycleTransportExit=$lifecycleTransport.exit;lifecycleTransportTimedOut=[bool]$lifecycleTransport.timedOut})
  exit 1
}
$afterPids=@($postParsed.afterPids|ForEach-Object{[int]$_})
$newPids=@($afterPids|Where-Object{$beforePids -notcontains $_})
$ok=$(if($lifecycle -eq 'start'){$afterPids.Count -gt 0}else{$newPids.Count -gt 0})
$o=[ordered]@{
  ok=$ok
  classification=$(if($ok){if($lifecycle -eq 'start'){'HERMES_GATEWAY_NATIVE_START_VERIFIED'}else{'HERMES_GATEWAY_NATIVE_RELOAD_VERIFIED'}}else{if($lifecycle -eq 'start'){'HERMES_GATEWAY_START_FAILED'}else{'HERMES_GATEWAY_RELOAD_PID_NOT_CHANGED'}})
  mutation=$(if($lifecycle -eq 'start'){'NATIVE_GATEWAY_START'}else{'NATIVE_GATEWAY_RESTART'})
  lifecycle=$lifecycle
  transport=$route.transport
  registryEntryCount=0
  beforePids=$beforePids
  afterPids=$afterPids
  newPids=$newPids
  lifecycleTransportExit=$lifecycleTransport.exit
  lifecycleTransportTimedOut=[bool]$lifecycleTransport.timedOut
  providerTouched=$false
  ollamaMutationStarted=$false
  networkChanged=$false
  modelGenerationStarted=$false
  verifiedAt=(Get-Date -Format o)
}
Save-Result $o
exit $(if($ok){0}else{1})
