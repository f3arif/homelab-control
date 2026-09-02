#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0

if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-gateway-reload.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Hermes gateway reload request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid H3 Hermes gateway reload request identity.'}
if([string]$req.action -ne 'reload-gateway-native' -or [string]$req.status -ne 'ACTIVE'){throw 'H3 Hermes gateway reload request is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'H3 Hermes gateway reload target mismatch.'}
if(-not [bool]$req.require_empty_active_registry -or -not [bool]$req.use_native_restart){throw 'H3 Hermes gateway reload guard mismatch.'}
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
foreach($required in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "Required H3 gateway reload path missing: $required"}}

$remote=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
function Emit($o,[int]$code){$o|ConvertTo-Json -Depth 20 -Compress;exit $code}
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=$false;classification='HERMES_GATEWAY_RELOAD_WRONG_HOST';host=$env:COMPUTERNAME;mutation='NONE'}) 30}
$root=Join-Path $env:LOCALAPPDATA 'hermes'
$hermes=Join-Path $root 'bin\hermes.exe'
$python=Join-Path $root 'hermes-agent\venv\Scripts\python.exe'
if(-not(Test-Path -LiteralPath $hermes -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_GATEWAY_RELOAD_CLI_MISSING';mutation='NONE'}) 41}
if(-not(Test-Path -LiteralPath $python -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_GATEWAY_RELOAD_PYTHON_MISSING';mutation='NONE'}) 42}

# Fail closed unless Hermes itself can strictly read an empty ownership registry.
$py='from pathlib import Path; from hermes_constants import get_hermes_home; from hermes_cli.active_sessions import _read_entries; p=Path(get_hermes_home())/"runtime"/"active_sessions.json"; e=_read_entries(p, strict=True); print(len(e)); raise SystemExit(0 if len(e)==0 else 9)'
$priorHome=$env:HERMES_HOME
try{
  $env:HERMES_HOME=$root
  $registryRaw=(& $python -c $py 2>&1|Out-String).Trim()
  $registryExit=$LASTEXITCODE
  if($registryExit -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_GATEWAY_RELOAD_REGISTRY_NOT_EMPTY_OR_INVALID';mutation='NONE';registryProbeExit=$registryExit}) 43}

  function Get-GatewayProcs {
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      ([string]$_.Name) -match '(?i)python|hermes' -and ([string]$_.CommandLine) -match '(?i)-m\s+hermes_cli[.]main\s+gateway\s+run|hermes(?:[.]exe)?\s+gateway\s+run'
    } | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CreationDate)
  }
  $before=@(Get-GatewayProcs)
  if($before.Count -eq 0){Emit ([ordered]@{ok=$false;classification='HERMES_GATEWAY_RELOAD_NO_RUNNING_GATEWAY';mutation='NONE';registryEntryCount=0}) 44}
  $beforePids=@($before|ForEach-Object{[int]$_.ProcessId})

  $restartOut=(& $hermes gateway restart 2>&1|Out-String).Trim()
  $restartExit=$LASTEXITCODE
  if($restartExit -ne 0){
    Emit ([ordered]@{ok=$false;classification='HERMES_GATEWAY_NATIVE_RESTART_FAILED';mutation='NATIVE_RESTART_ATTEMPTED';registryEntryCount=0;beforePids=$beforePids;restartExit=$restartExit}) 45
  }

  $after=@();$changed=$false
  $deadline=(Get-Date).AddSeconds(20)
  do{
    Start-Sleep -Milliseconds 750
    $after=@(Get-GatewayProcs)
    $afterPids=@($after|ForEach-Object{[int]$_.ProcessId})
    $changed=($after.Count -gt 0 -and @($afterPids|Where-Object{$beforePids -notcontains $_}).Count -gt 0)
  }while((Get-Date) -lt $deadline -and -not $changed)
  $afterPids=@($after|ForEach-Object{[int]$_.ProcessId})
  if($after.Count -eq 0){
    Emit ([ordered]@{ok=$false;classification='HERMES_GATEWAY_RELOAD_NO_POST_PROCESS';mutation='NATIVE_GATEWAY_RESTART';registryEntryCount=0;beforePids=$beforePids;afterPids=$afterPids;restartExit=0}) 46
  }
  if(-not $changed){
    Emit ([ordered]@{ok=$false;classification='HERMES_GATEWAY_RELOAD_PID_NOT_CHANGED';mutation='NATIVE_GATEWAY_RESTART';registryEntryCount=0;beforePids=$beforePids;afterPids=$afterPids;restartExit=0}) 47
  }
  Emit ([ordered]@{
    ok=$true;classification='HERMES_GATEWAY_NATIVE_RELOAD_VERIFIED';mutation='NATIVE_GATEWAY_RESTART'
    registryEntryCount=0;beforePids=$beforePids;afterPids=$afterPids;restartExit=0
    providerTouched=$false;ollamaMutationStarted=$false;networkChanged=$false;modelGenerationStarted=$false
    verifiedAt=(Get-Date -Format o)
  }) 0
}finally{
  if($null -eq $priorHome){Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue}else{$env:HERMES_HOME=$priorHome}
}
'@

$bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 Hermes gateway reload stdin empty.''};Invoke-Expression $script'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
function Invoke-H3([string]$target,[string]$transport,[string[]]$extra){
  $in=Join-Path $env:TEMP ('h3-hermes-reload-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $out=Join-Path $env:TEMP ('h3-hermes-reload-'+[guid]::NewGuid().ToString('n')+'.out')
  $err=Join-Path $env:TEMP ('h3-hermes-reload-'+[guid]::NewGuid().ToString('n')+'.err')
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known))
  if($extra){$args+=@($extra)}
  $args+=@($target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  try{
    [IO.File]::WriteAllText($in,$remote,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $in -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(50000)){try{$p.Kill()}catch{};return [pscustomobject]@{ok=$false;classification='HERMES_GATEWAY_RELOAD_REMOTE_TIMEOUT';transport=$transport;mutation='UNKNOWN'}}
    $stdout=$(if(Test-Path $out){[IO.File]::ReadAllText($out).Trim()}else{''})
    $stderr=$(if(Test-Path $err){[IO.File]::ReadAllText($err).Trim()}else{''})
    $parsed=$null
    foreach($line in @($stdout -split "`r?`n"|Where-Object{$_})){try{$parsed=$line|ConvertFrom-Json}catch{}}
    if($parsed){$parsed|Add-Member transport $transport -Force;return $parsed}
    return [pscustomobject]@{ok=$false;classification='HERMES_GATEWAY_RELOAD_INVALID_REMOTE_RESULT';transport=$transport;mutation='UNKNOWN';errorType=$(if($stderr){'SSH_OR_REMOTE_ERROR'}else{'INVALID_JSON'})}
  }finally{Remove-Item $in,$out,$err -Force -ErrorAction SilentlyContinue}
}
$result=Invoke-H3 'Faiz@100.106.186.118' 'tailscale' @()
if(-not [bool]$result.ok -and [string]$result.classification -in @('HERMES_GATEWAY_RELOAD_REMOTE_TIMEOUT','HERMES_GATEWAY_RELOAD_INVALID_REMOTE_RESULT')){
  $result=Invoke-H3 'Faiz@192.168.50.185' 'lan-hostkey-alias' @('-o','HostKeyAlias=100.106.186.118')
}
$json=$result|ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($statePath,$json,$utf8)
try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$json,$utf8)}}catch{}
Write-Output ($result|ConvertTo-Json -Depth 20 -Compress)
exit $(if([bool]$result.ok){0}else{1})
