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
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-tool-dispatch-repair.json'
}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){
  throw "H3 Hermes tool-dispatch request missing: $RequestPath"
}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){
  throw 'Invalid H3 Hermes tool-dispatch request identity.'
}
if([string]$req.action -ne 'repair-local-tool-dispatch' -or [string]$req.status -ne 'ACTIVE'){
  throw 'H3 Hermes tool-dispatch request is not active.'
}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){
  throw 'H3 Hermes tool-dispatch target mismatch.'
}
if([string]$req.provider -ne 'custom' -or [string]$req.model -ne 'qwen3.6:35b-a3b'){
  throw 'H3 Hermes tool-dispatch provider/model mismatch.'
}
if([bool]$req.tool_use_enforcement -or [bool]$req.task_completion_guidance -or [bool]$req.parallel_tool_call_guidance){
  throw 'H3 Hermes tool-dispatch desired guidance values must all be false.'
}
if(-not [bool]$req.require_telegram_toolset_not_explicitly_empty -or -not [bool]$req.restart_gateway){
  throw 'H3 Hermes tool-dispatch guard mismatch.'
}
if([bool]$req.change_provider -or [bool]$req.mutate_ollama -or [bool]$req.change_network -or [bool]$req.run_model_generation){
  throw 'H3 Hermes tool-dispatch forbidden mutation requested.'
}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-tool-dispatch'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-TOOL-DISPATCH-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
foreach($p in @($key,$known,$ssh)){
  if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required H3 tool-dispatch path missing: $p"}
}

function Save-Result($o){
  $j=$o | ConvertTo-Json -Depth 30
  [IO.File]::WriteAllText($statePath,$j,$utf8)
  try{
    if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$j,$utf8)}
  }catch{}
  Write-Output ($o | ConvertTo-Json -Depth 30 -Compress)
}

function Invoke-RemoteScript([string]$Target,[string[]]$Extra,[string]$Script,[int]$TimeoutMs,[string]$Transport){
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''stdin empty''};Invoke-Expression $script'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $inFile=Join-Path $env:TEMP ('h3-tool-dispatch-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('h3-tool-dispatch-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('h3-tool-dispatch-'+[guid]::NewGuid().ToString('n')+'.err')
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
    $parsed=$null
    foreach($line in @($stdout -split "`r?`n" | Where-Object{$_})){
      try{$parsed=$line | ConvertFrom-Json}catch{}
    }
    if($parsed){$parsed | Add-Member transport $Transport -Force;return $parsed}
    return [pscustomobject]@{
      ok=$false
      classification=$(if($timedOut){'HERMES_TOOL_DISPATCH_REMOTE_TIMEOUT'}else{'HERMES_TOOL_DISPATCH_INVALID_REMOTE_RESULT'})
      transport=$Transport
      timedOut=$timedOut
      exit=$(if($timedOut){$null}else{[int]$p.ExitCode})
      stderrPresent=(-not [string]::IsNullOrWhiteSpace($stderr))
    }
  }finally{
    Remove-Item $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue
  }
}

$remote=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
function Emit($o,[int]$code){$o | ConvertTo-Json -Depth 20 -Compress;exit $code}
function Read-JsonConfig([string]$Hermes,[string]$Key){
  $raw=(& $Hermes config get $Key --json 2>&1 | Out-String).Trim()
  if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)){return $null}
  try{return $raw | ConvertFrom-Json}catch{return $null}
}
function Bool-State($Object,[string]$Name,[bool]$DefaultValue){
  if($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name){
    return [ordered]@{present=$true;value=[bool]$Object.$Name}
  }
  return [ordered]@{present=$false;value=$DefaultValue}
}
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){
  Emit ([ordered]@{ok=$false;classification='HERMES_TOOL_DISPATCH_WRONG_HOST';host=$env:COMPUTERNAME;mutation='NONE'}) 30
}
$root=Join-Path $env:LOCALAPPDATA 'hermes'
$hermes=Join-Path $root 'bin\hermes.exe'
$config=Join-Path $root 'config.yaml'
if(-not(Test-Path -LiteralPath $hermes -PathType Leaf)){
  Emit ([ordered]@{ok=$false;classification='HERMES_TOOL_DISPATCH_CLI_MISSING';mutation='NONE'}) 41
}
if(-not(Test-Path -LiteralPath $config -PathType Leaf)){
  Emit ([ordered]@{ok=$false;classification='HERMES_TOOL_DISPATCH_CONFIG_MISSING';mutation='NONE'}) 42
}
$priorHome=$env:HERMES_HOME
$env:HERMES_HOME=$root
try{
  $agentBefore=Read-JsonConfig $hermes 'agent'
  $platformToolsets=Read-JsonConfig $hermes 'platform_toolsets'
  $telegramExplicit=$false
  $telegramCount=$null
  if($null -ne $platformToolsets -and $platformToolsets.PSObject.Properties.Name -contains 'telegram'){
    $telegramExplicit=$true
    $telegramCount=@($platformToolsets.telegram).Count
  }
  if($telegramExplicit -and [int]$telegramCount -eq 0){
    Emit ([ordered]@{
      ok=$false;classification='HERMES_TELEGRAM_TOOLSET_EXPLICITLY_EMPTY';mutation='NONE';
      telegramToolsetExplicit=$true;telegramToolsetCount=0;
      before=[ordered]@{
        tool_use_enforcement=(Bool-State $agentBefore 'tool_use_enforcement' $true)
        task_completion_guidance=(Bool-State $agentBefore 'task_completion_guidance' $true)
        parallel_tool_call_guidance=(Bool-State $agentBefore 'parallel_tool_call_guidance' $true)
      }
    }) 43
  }

  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup="$config.afz-pre-tool-dispatch-$stamp.bak"
  Copy-Item -LiteralPath $config -Destination $backup -Force
  try{
    & $hermes config set agent.tool_use_enforcement 'false' | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Failed to set agent.tool_use_enforcement=false'}
    & $hermes config set agent.task_completion_guidance 'false' | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Failed to set agent.task_completion_guidance=false'}
    & $hermes config set agent.parallel_tool_call_guidance 'false' | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Failed to set agent.parallel_tool_call_guidance=false'}

    $agentAfter=Read-JsonConfig $hermes 'agent'
    $toolUseOk=($null -ne $agentAfter -and $agentAfter.PSObject.Properties.Name -contains 'tool_use_enforcement' -and $agentAfter.tool_use_enforcement -eq $false)
    $taskOk=($null -ne $agentAfter -and $agentAfter.PSObject.Properties.Name -contains 'task_completion_guidance' -and $agentAfter.task_completion_guidance -eq $false)
    $parallelOk=($null -ne $agentAfter -and $agentAfter.PSObject.Properties.Name -contains 'parallel_tool_call_guidance' -and $agentAfter.parallel_tool_call_guidance -eq $false)
    if(-not($toolUseOk -and $taskOk -and $parallelOk)){
      throw 'Hermes tool-dispatch guidance verification failed after config set.'
    }

    Emit ([ordered]@{
      ok=$true
      classification='HERMES_LOCAL_TOOL_DISPATCH_GUIDANCE_DISABLED'
      mutation='CONFIG_AGENT_GUIDANCE_ONLY'
      configBackup=$backup
      telegramToolsetExplicit=$telegramExplicit
      telegramToolsetCount=$telegramCount
      before=[ordered]@{
        tool_use_enforcement=(Bool-State $agentBefore 'tool_use_enforcement' $true)
        task_completion_guidance=(Bool-State $agentBefore 'task_completion_guidance' $true)
        parallel_tool_call_guidance=(Bool-State $agentBefore 'parallel_tool_call_guidance' $true)
      }
      after=[ordered]@{
        tool_use_enforcement=$false
        task_completion_guidance=$false
        parallel_tool_call_guidance=$false
      }
      providerTouched=$false
      ollamaMutationStarted=$false
      networkChanged=$false
      modelGenerationStarted=$false
      changedAt=(Get-Date -Format o)
    }) 0
  }catch{
    try{Copy-Item -LiteralPath $backup -Destination $config -Force}catch{}
    Emit ([ordered]@{
      ok=$false;classification='HERMES_LOCAL_TOOL_DISPATCH_GUIDANCE_REPAIR_FAILED';
      mutation='CONFIG_AGENT_GUIDANCE_ROLLED_BACK';configBackup=$backup;errorType=$_.Exception.GetType().Name
    }) 44
  }
}finally{
  if($null -eq $priorHome){Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue}else{$env:HERMES_HOME=$priorHome}
}
'@

$routes=@(
  [pscustomobject]@{target='Faiz@100.106.186.118';transport='tailscale';extra=@()},
  [pscustomobject]@{target='Faiz@192.168.50.185';transport='lan-hostkey-alias';extra=@('-o','HostKeyAlias=100.106.186.118')}
)
$configResult=$null
foreach($r in $routes){
  $candidate=Invoke-RemoteScript -Target $r.target -Extra $r.extra -Script $remote -TimeoutMs 30000 -Transport $r.transport
  $configResult=$candidate
  if([bool]$candidate.ok){break}
  if([string]$candidate.classification -notin @('HERMES_TOOL_DISPATCH_REMOTE_TIMEOUT','HERMES_TOOL_DISPATCH_INVALID_REMOTE_RESULT')){break}
}
if(-not $configResult -or -not [bool]$configResult.ok){
  $o=[ordered]@{
    ok=$false
    classification=$(if($configResult){[string]$configResult.classification}else{'HERMES_TOOL_DISPATCH_CONFIG_UNREACHABLE'})
    configRepair=$configResult
    gatewayReload=$null
    providerTouched=$false
    ollamaMutationStarted=$false
    networkChanged=$false
    modelGenerationStarted=$false
    observedAt=(Get-Date -Format o)
  }
  Save-Result $o
  exit 1
}

$reloadHelper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Hermes-GatewayReload.ps1'
$reloadRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-gateway-reload.json'
$reloadResult=$null
if((Test-Path -LiteralPath $reloadHelper -PathType Leaf) -and (Test-Path -LiteralPath $reloadRequest -PathType Leaf)){
  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $reloadHelper -InstallRoot $InstallRoot -RequestPath $reloadRequest 2>&1 | Out-String).Trim()
  $reloadCode=$LASTEXITCODE
  foreach($line in @($raw -split "`r?`n" | Where-Object{$_})){
    try{$reloadResult=$line | ConvertFrom-Json}catch{}
  }
  if($null -eq $reloadResult){$reloadResult=[pscustomobject]@{ok=$false;classification='HERMES_TOOL_DISPATCH_GATEWAY_RELOAD_UNPARSEABLE';exit=$reloadCode}}
}else{
  $reloadResult=[pscustomobject]@{ok=$false;classification='HERMES_TOOL_DISPATCH_GATEWAY_RELOAD_HELPER_MISSING'}
}

$ok=([bool]$configResult.ok -and $reloadResult -and [bool]$reloadResult.ok)
$o=[ordered]@{
  ok=$ok
  classification=$(if($ok){'HERMES_LOCAL_TOOL_DISPATCH_REPAIR_VERIFIED'}else{[string]$reloadResult.classification})
  configRepair=$configResult
  gatewayReload=$reloadResult
  providerTouched=$false
  ollamaMutationStarted=$false
  networkChanged=$false
  modelGenerationStarted=$false
  observedAt=(Get-Date -Format o)
}
Save-Result $o
exit $(if($ok){0}else{1})
