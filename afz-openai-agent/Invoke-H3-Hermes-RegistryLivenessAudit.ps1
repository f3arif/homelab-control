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
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-registry-liveness-audit.json'
}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Hermes registry liveness request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid H3 Hermes registry liveness request identity.'}
if(-not [bool]$req.enabled -or [string]$req.action -ne 'audit-registry-liveness'){throw 'H3 Hermes registry liveness request is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'H3 Hermes registry liveness target mismatch.'}
if(-not [bool]$req.read_only -or [string]$req.mutation -ne 'none'){throw 'H3 Hermes registry liveness read-only contract mismatch.'}
if([bool]$req.restart_gateway -or [bool]$req.change_provider -or [bool]$req.run_model_generation -or [bool]$req.mutate_ollama -or [bool]$req.change_network){throw 'H3 Hermes registry liveness forbidden mutation requested.'}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$remoteScript=Join-Path $InstallRoot 'afz-openai-agent\Read-H3-Hermes-RegistryLiveness.ps1'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-registry-liveness'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-REGISTRY-LIVENESS-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
foreach($required in @($key,$known,$ssh,$remoteScript)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "Required H3 registry liveness path missing: $required"}}

function Save-Result($result,[string]$transport){
  $safeEntries=@()
  if($result.PSObject.Properties.Name -contains 'entries'){
    foreach($e in @($result.entries)){
      $safeEntries += [ordered]@{
        surface=$(if($e.PSObject.Properties.Name -contains 'surface'){[string]$e.surface}else{$null})
        pid=$(if($e.PSObject.Properties.Name -contains 'pid'){$e.pid}else{$null})
        trackLiveness=$(if($e.PSObject.Properties.Name -contains 'trackLiveness'){[bool]$e.trackLiveness}else{$false})
        processAlive=$(if($e.PSObject.Properties.Name -contains 'processAlive'){[bool]$e.processAlive}else{$false})
        processName=$(if($e.PSObject.Properties.Name -contains 'processName'){[string]$e.processName}else{$null})
        expectedProcessStart=$(if($e.PSObject.Properties.Name -contains 'expectedProcessStart'){$e.expectedProcessStart}else{$null})
        actualProcessStart=$(if($e.PSObject.Properties.Name -contains 'actualProcessStart'){$e.actualProcessStart}else{$null})
        processStartMatches=$(if($e.PSObject.Properties.Name -contains 'processStartMatches'){$e.processStartMatches}else{$null})
        provenLive=$(if($e.PSObject.Properties.Name -contains 'provenLive'){[bool]$e.provenLive}else{$false})
        provenStaleCandidate=$(if($e.PSObject.Properties.Name -contains 'provenStaleCandidate'){[bool]$e.provenStaleCandidate}else{$false})
        liveSessionIdPresent=$(if($e.PSObject.Properties.Name -contains 'liveSessionIdPresent'){[bool]$e.liveSessionIdPresent}else{$false})
      }
    }
  }
  $safeGateway=@()
  if($result.PSObject.Properties.Name -contains 'gatewayProcesses'){
    foreach($p in @($result.gatewayProcesses)){
      $safeGateway += [ordered]@{
        pid=$(if($p.PSObject.Properties.Name -contains 'pid'){$p.pid}else{$null})
        name=$(if($p.PSObject.Properties.Name -contains 'name'){[string]$p.name}else{$null})
        parentPid=$(if($p.PSObject.Properties.Name -contains 'parentPid'){$p.parentPid}else{$null})
      }
    }
  }
  $safe=[ordered]@{
    schema=1;controlPlane='github';source='windows-main';target='h3';host='DESKTOP-H3R6CQN';jobId=$id
    ok=[bool]$result.ok;classification=[string]$result.classification;transport=$transport;mutation='NONE'
    registryEntryCount=$(if($result.PSObject.Properties.Name -contains 'registryEntryCount'){$result.registryEntryCount}else{$null})
    liveOwnerCount=$(if($result.PSObject.Properties.Name -contains 'liveOwnerCount'){$result.liveOwnerCount}else{$null})
    staleCandidateCount=$(if($result.PSObject.Properties.Name -contains 'staleCandidateCount'){$result.staleCandidateCount}else{$null})
    indeterminateCount=$(if($result.PSObject.Properties.Name -contains 'indeterminateCount'){$result.indeterminateCount}else{$null})
    registryLastWriteUtc=$(if($result.PSObject.Properties.Name -contains 'registryLastWriteUtc'){[string]$result.registryLastWriteUtc}else{$null})
    entries=$safeEntries;gatewayProcesses=$safeGateway
    providerTouched=$false;modelGenerationStarted=$false;ollamaMutationStarted=$false;networkChanged=$false;gatewayRestarted=$false;registryMutated=$false
    error=$(if($result.PSObject.Properties.Name -contains 'error'){[string]$result.error}else{$null})
    observedAt=(Get-Date -Format o)
  }
  $json=$safe|ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$json,$utf8)}}catch{}
  Write-Output ($safe|ConvertTo-Json -Depth 12 -Compress)
}

$remote=[IO.File]::ReadAllText($remoteScript)
$bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 Hermes registry liveness stdin empty.''};Invoke-Expression $script'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))

function Invoke-Remote([string]$target,[string]$transport,[string[]]$extraOptions){
  $inFile=Join-Path $env:TEMP ('afz-h3-hermes-live-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('afz-h3-hermes-live-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('afz-h3-hermes-live-'+[guid]::NewGuid().ToString('n')+'.err')
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known))
  if($extraOptions){$args+=@($extraOptions)}
  $args+=@($target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  try{
    [IO.File]::WriteAllText($inFile,$remote,$utf8)
    $proc=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $proc.WaitForExit(45000)){try{$proc.Kill()}catch{};return [pscustomobject]@{ok=$false;classification='HERMES_REGISTRY_LIVENESS_REMOTE_TIMEOUT';transport=$transport;error='remote timeout'}}
    $stdout=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
    $stderr=$(if(Test-Path -LiteralPath $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
    $parsed=$null
    foreach($line in @($stdout -split "`r?`n"|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})){try{$parsed=$line|ConvertFrom-Json}catch{}}
    if($null -ne $parsed){$parsed|Add-Member -NotePropertyName transport -NotePropertyValue $transport -Force;return $parsed}
    return [pscustomobject]@{ok=$false;classification='HERMES_REGISTRY_LIVENESS_INVALID_REMOTE_RESULT';transport=$transport;error=$(if($stderr){$stderr}else{$stdout})}
  }finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}

$result=Invoke-Remote 'Faiz@100.106.186.118' 'tailscale' @()
if(-not [bool]$result.ok -and [string]$result.classification -in @('HERMES_REGISTRY_LIVENESS_REMOTE_TIMEOUT','HERMES_REGISTRY_LIVENESS_INVALID_REMOTE_RESULT')){
  $result=Invoke-Remote 'Faiz@192.168.50.185' 'lan-hostkey-alias' @('-o','HostKeyAlias=100.106.186.118')
}
Save-Result $result ([string]$result.transport)
exit $(if([bool]$result.ok){0}else{1})
