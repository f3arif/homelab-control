#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-agent-install.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Hermes request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid H3 Hermes request identity.'}
if([string]$req.action -ne 'install-and-configure' -or [string]$req.status -ne 'ACTIVE'){throw 'H3 Hermes Desktop refresh request is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'H3 Hermes target mismatch.'}
if([string]$req.provider_name -ne 'ollama' -or [string]$req.base_url -ne 'http://127.0.0.1:11434/v1'){throw 'H3 Hermes provider route mismatch.'}
if([string]$req.base_model -ne 'qwen3.6:35b-a3b' -or [int]$req.context_length -ne 65536){throw 'H3 Hermes model mismatch.'}
if(-not [bool]$req.restart_desktop_backend){throw 'Desktop backend refresh flag missing.'}
if([bool]$req.restart_electron_ui -or [bool]$req.restart_messaging_gateway -or [bool]$req.mutate_ollama -or [bool]$req.run_generation_test){throw 'H3 Hermes refresh safety flags mismatch.'}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-agent'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-DOCKER-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
foreach($required in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "Required H3 SSH path missing: $required"}}

function Save-Result($result){
  $json=$result|ConvertTo-Json -Depth 18 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{
    if(Test-Path -LiteralPath $diagRoot -PathType Container){
      $safe=[ordered]@{
        schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';controlPlane='github';source='windows-main';target='h3'
        host=$(if($result.PSObject.Properties.Name -contains 'host'){[string]$result.host}else{$null})
        jobId=$id;ok=[bool]$result.ok;classification=[string]$result.classification
        retryable=$(if($result.PSObject.Properties.Name -contains 'retryable'){[bool]$result.retryable}else{$false})
        deployment='native';providerName='ollama'
        providerConfigured=$(if($result.PSObject.Properties.Name -contains 'providerConfigured'){[bool]$result.providerConfigured}else{$false})
        selectedModel=$(if($result.PSObject.Properties.Name -contains 'selectedModel'){[string]$result.selectedModel}else{$null})
        modelProvider=$(if($result.PSObject.Properties.Name -contains 'modelProvider'){[string]$result.modelProvider}else{$null})
        desktopBackendCandidates=$(if($result.PSObject.Properties.Name -contains 'desktopBackendCandidates'){[int]$result.desktopBackendCandidates}else{0})
        stoppedPids=$(if($result.PSObject.Properties.Name -contains 'stoppedPids'){@($result.stoppedPids)}else{@()})
        respawnedPid=$(if($result.PSObject.Properties.Name -contains 'respawnedPid'){$result.respawnedPid}else{$null})
        electronUiTouched=$false;messagingGatewayTouched=$false;ollamaMutationStarted=$false;generationTestStarted=$false
        error=$(if($result.PSObject.Properties.Name -contains 'error'){[string]$result.error}else{$null})
        observedAt=(Get-Date -Format o)
      }
      [IO.File]::WriteAllText($diagPath,($safe|ConvertTo-Json -Depth 10),$utf8)
    }
  }catch{}
  Write-Output $json
}

$remote=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
function Emit($o,[int]$code){$o|ConvertTo-Json -Depth 16 -Compress;exit $code}
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=$false;classification='HERMES_WRONG_HOST';host=$env:COMPUTERNAME;retryable=$false}) 30}
$hermesRoot=Join-Path $env:LOCALAPPDATA 'hermes'
$hermesPath=Join-Path $hermesRoot 'bin\hermes.exe'
$marker=Join-Path $hermesRoot 'afz-desktop-backend-refresh-r16.json'
if(-not(Test-Path -LiteralPath $hermesPath -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_NATIVE_RUNTIME_NOT_FOUND';host=$env:COMPUTERNAME;retryable=$false}) 41}
if(Test-Path -LiteralPath $marker -PathType Leaf){
  try{$prior=Get-Content -LiteralPath $marker -Raw -Encoding UTF8|ConvertFrom-Json;$prior.classification='HERMES_DESKTOP_BACKEND_REFRESH_ALREADY_APPLIED';$prior.ok=$true;$prior.retryable=$false;Emit $prior 0}catch{}
}

$priorHome=$env:HERMES_HOME
try{
  $env:HERMES_HOME=$hermesRoot
  $providerRaw=(& $hermesPath config get 'providers.ollama' --json 2>&1|Out-String).Trim()
  if($LASTEXITCODE -ne 0 -or $providerRaw -notmatch '127\.0\.0\.1:11434' -or $providerRaw -notmatch 'qwen3\.6:35b-a3b'){
    Emit ([ordered]@{ok=$false;classification='HERMES_DESKTOP_REFRESH_PROVIDER_NOT_READY';host=$env:COMPUTERNAME;retryable=$true;providerConfigured=$false}) 42
  }
  $modelRaw=(& $hermesPath config get 'model' --json 2>&1|Out-String).Trim()
  $modelProvider=''
  if($LASTEXITCODE -eq 0 -and $modelRaw){try{$modelObject=$modelRaw|ConvertFrom-Json;$modelProvider=[string]$modelObject.provider}catch{}}
  if([string]::IsNullOrWhiteSpace($modelProvider) -or $modelProvider -eq 'auto'){
    Emit ([ordered]@{ok=$false;classification='HERMES_DESKTOP_REFRESH_MAIN_PROVIDER_NOT_READY';host=$env:COMPUTERNAME;retryable=$true;providerConfigured=$true;modelProvider=$modelProvider}) 43
  }
}finally{if($null -eq $priorHome){Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue}else{$env:HERMES_HOME=$priorHome}}

$all=@(Get-CimInstance Win32_Process -ErrorAction Stop)
$byId=@{};foreach($p in $all){$byId[[int]$p.ProcessId]=$p}
function Has-HermesElectronAncestor([int]$ProcessId){
  $seen=New-Object Collections.Generic.HashSet[int]
  $current=$ProcessId
  for($depth=0;$depth -lt 8;$depth++){
    if(-not $byId.ContainsKey($current)){return $false}
    $p=$byId[$current]
    $parent=[int]$p.ParentProcessId
    if($parent -le 0 -or $seen.Contains($parent)){return $false}
    [void]$seen.Add($parent)
    if(-not $byId.ContainsKey($parent)){return $false}
    $pp=$byId[$parent]
    if([string]$pp.Name -ieq 'Hermes.exe'){return $true}
    $current=$parent
  }
  return $false
}
function Is-DesktopBackend($p){
  $cl=[string]$p.CommandLine
  if([string]::IsNullOrWhiteSpace($cl)){return $false}
  $subcommand=($cl -match '(?i)(?:hermes(?:\.exe)?|hermes_cli(?:[\\/]|\.)main(?:\.py)?)\s+(?:serve|dashboard)')
  $ephemeral=($cl -match '(?i)(?:--port\s+0(?:\s|$)|--port=0(?:\s|$))')
  if(-not($subcommand -and $ephemeral)){return $false}
  return (Has-HermesElectronAncestor ([int]$p.ProcessId))
}
$candidates=@($all|Where-Object{Is-DesktopBackend $_})
if($candidates.Count -eq 0){
  Emit ([ordered]@{ok=$false;classification='HERMES_DESKTOP_EPHEMERAL_BACKEND_NOT_FOUND';host=$env:COMPUTERNAME;retryable=$false;providerConfigured=$true;selectedModel='qwen3.6:35b-a3b';modelProvider=$modelProvider;desktopBackendCandidates=0;stoppedPids=@()}) 44
}
if($candidates.Count -ne 1){
  Emit ([ordered]@{ok=$false;classification='HERMES_DESKTOP_EPHEMERAL_BACKEND_AMBIGUOUS';host=$env:COMPUTERNAME;retryable=$false;providerConfigured=$true;selectedModel='qwen3.6:35b-a3b';modelProvider=$modelProvider;desktopBackendCandidates=$candidates.Count;stoppedPids=@()}) 45
}
$oldPids=@([int]$candidates[0].ProcessId)
Stop-Process -Id $oldPids[0] -Force -ErrorAction Stop
Start-Sleep -Milliseconds 750
$newPid=$null
$deadline=(Get-Date).AddSeconds(25)
do{
  Start-Sleep -Milliseconds 500
  try{
    $scan=@(Get-CimInstance Win32_Process -ErrorAction Stop)
    $new=@($scan|Where-Object{
      $cl=[string]$_.CommandLine
      $cl -and ([int]$_.ProcessId -notin $oldPids) -and
      $cl -match '(?i)(?:hermes(?:\.exe)?|hermes_cli(?:[\\/]|\.)main(?:\.py)?)\s+(?:serve|dashboard)' -and
      $cl -match '(?i)(?:--port\s+0(?:\s|$)|--port=0(?:\s|$))'
    }|Select-Object -First 1)
    if($new.Count -gt 0){$newPid=[int]$new[0].ProcessId;break}
  }catch{}
}while((Get-Date) -lt $deadline)
$result=[ordered]@{
  ok=$true
  classification=$(if($newPid){'HERMES_DESKTOP_BACKEND_REFRESHED'}else{'HERMES_DESKTOP_BACKEND_RECYCLE_TRIGGERED'})
  host=$env:COMPUTERNAME;retryable=$false;providerConfigured=$true;selectedModel='qwen3.6:35b-a3b';modelProvider=$modelProvider
  desktopBackendCandidates=1;stoppedPids=$oldPids;respawnedPid=$newPid
  electronUiTouched=$false;messagingGatewayTouched=$false;ollamaMutationStarted=$false;generationTestStarted=$false;finishedAt=(Get-Date -Format o)
}
$result|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $marker -Encoding UTF8
Emit $result 0
'@

$bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 Hermes stdin empty.''};Invoke-Expression $script'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
$inFile=Join-Path $env:TEMP ('afz-h3-hermes-refresh-'+[guid]::NewGuid().ToString('n')+'.ps1')
$outFile=Join-Path $env:TEMP ('afz-h3-hermes-refresh-'+[guid]::NewGuid().ToString('n')+'.out')
$errFile=Join-Path $env:TEMP ('afz-h3-hermes-refresh-'+[guid]::NewGuid().ToString('n')+'.err')
$args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
try{
  [IO.File]::WriteAllText($inFile,$remote,$utf8)
  $proc=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
  if(-not $proc.WaitForExit(60000)){try{$proc.Kill()}catch{};Save-Result ([pscustomobject]@{ok=$false;classification='HERMES_DESKTOP_REFRESH_REMOTE_TIMEOUT';host='DESKTOP-H3R6CQN';retryable=$true;error='Desktop backend refresh exceeded 60 seconds.'});exit 75}
  $stdout=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
  $stderr=$(if(Test-Path -LiteralPath $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
  $result=$null;foreach($line in @($stdout -split "`r?`n"|Where-Object{$_})){try{$result=$line|ConvertFrom-Json}catch{}}
  if($null -eq $result){$result=[pscustomobject]@{ok=$false;classification='HERMES_DESKTOP_REFRESH_REMOTE_NO_JSON';host='DESKTOP-H3R6CQN';retryable=$true;error=$(if($stderr){$stderr}else{"SSH exit=$($proc.ExitCode)"})}}
  $result|Add-Member -NotePropertyName jobId -NotePropertyValue $id -Force
  Save-Result $result
  if([bool]$result.ok){exit 0};exit 75
}catch{Save-Result ([pscustomobject]@{ok=$false;classification='HERMES_DESKTOP_REFRESH_WRAPPER_EXCEPTION';host='DESKTOP-H3R6CQN';retryable=$true;error=$_.Exception.Message});exit 75
}finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
