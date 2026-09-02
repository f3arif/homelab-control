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
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-session-registry-repair.json'
}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Hermes session registry request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid H3 Hermes session registry request identity.'}
if(-not [bool]$req.enabled -or [string]$req.action -ne 'repair-exact-empty-legacy-registry'){throw 'H3 Hermes session registry repair request is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'H3 Hermes session registry target mismatch.'}
if(-not [bool]$req.backup_before_mutation -or -not [bool]$req.only_exact_empty_legacy_schema){throw 'H3 Hermes session registry repair safety contract mismatch.'}
if([bool]$req.stop_gateway -or [bool]$req.change_provider -or [bool]$req.run_model_generation -or [bool]$req.mutate_ollama -or [bool]$req.change_network){throw 'H3 Hermes session registry forbidden mutation requested.'}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$remoteScript=Join-Path $InstallRoot 'afz-openai-agent\Repair-H3-Hermes-SessionRegistry.ps1'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-session-registry'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-SESSION-REGISTRY-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
foreach($required in @($key,$known,$ssh,$remoteScript)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "Required H3 registry repair path missing: $required"}}

function Save-Result($result,[string]$transport){
  $safe=[ordered]@{
    schema=1;controlPlane='github';source='windows-main';target='h3';host='DESKTOP-H3R6CQN';jobId=$id
    ok=[bool]$result.ok;classification=[string]$result.classification;transport=$transport
    mutation=$(if($result.PSObject.Properties.Name -contains 'mutation'){[string]$result.mutation}else{'NONE'})
    statePath=$(if($result.PSObject.Properties.Name -contains 'statePath'){[string]$result.statePath}else{$null})
    backupPath=$(if($result.PSObject.Properties.Name -contains 'backupPath'){[string]$result.backupPath}else{$null})
    entryCount=$(if($result.PSObject.Properties.Name -contains 'entryCount'){$result.entryCount}else{$null})
    strictValidation=$(if($result.PSObject.Properties.Name -contains 'strictValidation'){[string]$result.strictValidation}else{$null})
    gatewayProcessStopped=$false;providerTouched=$false;modelGenerationStarted=$false;ollamaMutationStarted=$false;networkChanged=$false
    observedAt=(Get-Date -Format o)
  }
  $json=$safe|ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$json,$utf8)}}catch{}
  Write-Output ($safe|ConvertTo-Json -Depth 8 -Compress)
}

$remote=[IO.File]::ReadAllText($remoteScript)
$bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 Hermes registry repair stdin empty.''};Invoke-Expression $script'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))

function Invoke-Remote([string]$target,[string]$transport,[string[]]$extraOptions){
  $inFile=Join-Path $env:TEMP ('afz-h3-hermes-reg-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('afz-h3-hermes-reg-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('afz-h3-hermes-reg-'+[guid]::NewGuid().ToString('n')+'.err')
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known))
  if($extraOptions){$args+=@($extraOptions)}
  $args+=@($target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  try{
    [IO.File]::WriteAllText($inFile,$remote,$utf8)
    $proc=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $proc.WaitForExit(45000)){try{$proc.Kill()}catch{};return [pscustomobject]@{ok=$false;classification='HERMES_SESSION_REGISTRY_REMOTE_TIMEOUT';transport=$transport;error='remote timeout'}}
    $stdout=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
    $stderr=$(if(Test-Path -LiteralPath $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
    $parsed=$null
    foreach($line in @($stdout -split "`r?`n"|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})){try{$parsed=$line|ConvertFrom-Json}catch{}}
    if($null -ne $parsed){$parsed|Add-Member -NotePropertyName transport -NotePropertyValue $transport -Force;return $parsed}
    return [pscustomobject]@{ok=$false;classification='HERMES_SESSION_REGISTRY_INVALID_REMOTE_RESULT';transport=$transport;error=$(if($stderr){$stderr}else{$stdout})}
  }finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}

$result=Invoke-Remote 'Faiz@100.106.186.118' 'tailscale' @()
if(-not [bool]$result.ok -and [string]$result.classification -in @('HERMES_SESSION_REGISTRY_REMOTE_TIMEOUT','HERMES_SESSION_REGISTRY_INVALID_REMOTE_RESULT')){
  $result=Invoke-Remote 'Faiz@192.168.50.185' 'lan-hostkey-alias' @('-o','HostKeyAlias=100.106.186.118')
}
Save-Result $result ([string]$result.transport)
exit $(if([bool]$result.ok){0}else{1})
