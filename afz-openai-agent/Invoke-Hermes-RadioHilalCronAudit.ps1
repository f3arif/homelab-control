#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$JobId='9d9eea1b7618'
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

function Unquote([string]$v){
  if($null -eq $v){return $null}
  $s=$v.Trim()
  if(($s.StartsWith('"') -and $s.EndsWith('"')) -or ($s.StartsWith("'") -and $s.EndsWith("'"))){
    if($s.Length -ge 2){$s=$s.Substring(1,$s.Length-2)}
  }
  return $s
}

function Find-HermesHome {
  $candidates = New-Object System.Collections.Generic.List[string]
  if($env:HERMES_HOME){$candidates.Add([string]$env:HERMES_HOME)}
  if($env:USERPROFILE){$candidates.Add((Join-Path $env:USERPROFILE '.hermes'))}
  $candidates.Add('C:\Users\Faiz\.hermes')
  try{
    Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction Stop | ForEach-Object {
      $candidates.Add((Join-Path $_.FullName '.hermes'))
    }
  }catch{}
  foreach($p in ($candidates | Select-Object -Unique)){
    if(Test-Path -LiteralPath (Join-Path $p 'cron\jobs.json') -PathType Leaf){return $p}
  }
  return $null
}

function Read-SafeHermesConfig([string]$Path){
  $result=[ordered]@{
    present=$false
    modelProvider=$null
    modelDefault=$null
    fallbacks=@()
  }
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return [pscustomobject]$result}
  $result.present=$true
  $lines=@(Get-Content -LiteralPath $Path -Encoding UTF8)
  $section=''
  $fallbacks=New-Object System.Collections.Generic.List[object]
  $currentFallback=$null

  foreach($rawLine in $lines){
    $line=[string]$rawLine
    if([string]::IsNullOrWhiteSpace($line)){continue}
    $trim=$line.Trim()
    if($trim.StartsWith('#')){continue}
    $indent=$line.Length-$line.TrimStart().Length

    if($indent -eq 0 -and $trim -match '^([A-Za-z0-9_]+)\s*:\s*(.*)$'){
      if($null -ne $currentFallback){
        if($currentFallback.provider -and $currentFallback.model){$fallbacks.Add([pscustomobject]$currentFallback)}
        $currentFallback=$null
      }
      $section=$matches[1]
      continue
    }

    if($section -eq 'model' -and $indent -gt 0){
      if($trim -match '^provider\s*:\s*(.+)$'){$result.modelProvider=Unquote $matches[1];continue}
      if($trim -match '^default\s*:\s*(.+)$'){$result.modelDefault=Unquote $matches[1];continue}
    }

    if($section -eq 'fallback_providers' -and $indent -gt 0){
      if($trim -match '^-\s*provider\s*:\s*(.+)$'){
        if($null -ne $currentFallback -and $currentFallback.provider -and $currentFallback.model){$fallbacks.Add([pscustomobject]$currentFallback)}
        $currentFallback=[ordered]@{provider=(Unquote $matches[1]);model=$null;source='fallback_providers'}
        continue
      }
      if($null -ne $currentFallback -and $trim -match '^model\s*:\s*(.+)$'){
        $currentFallback.model=Unquote $matches[1]
        continue
      }
    }

    if($section -eq 'fallback_model' -and $indent -gt 0){
      if($null -eq $currentFallback){$currentFallback=[ordered]@{provider=$null;model=$null;source='fallback_model'}}
      if($trim -match '^provider\s*:\s*(.+)$'){$currentFallback.provider=Unquote $matches[1];continue}
      if($trim -match '^model\s*:\s*(.+)$'){$currentFallback.model=Unquote $matches[1];continue}
    }
  }

  if($null -ne $currentFallback -and $currentFallback.provider -and $currentFallback.model){$fallbacks.Add([pscustomobject]$currentFallback)}
  $result.fallbacks=@($fallbacks)
  return [pscustomobject]$result
}

$hermesHome=Find-HermesHome
if(-not $hermesHome){
  [ordered]@{
    schema=1
    ok=$false
    classification='HERMES_HOME_NOT_FOUND'
    jobId=$JobId
    secretValuesEmitted=$false
    time=(Get-Date -Format o)
  } | ConvertTo-Json -Depth 8 -Compress
  exit 20
}

$jobsPath=Join-Path $hermesHome 'cron\jobs.json'
$configPath=Join-Path $hermesHome 'config.yaml'
$jobsRaw=Get-Content -LiteralPath $jobsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$jobList=@()
if($jobsRaw -is [System.Array]){$jobList=@($jobsRaw)}
elseif($jobsRaw.PSObject.Properties.Name -contains 'jobs'){$jobList=@($jobsRaw.jobs)}
else{$jobList=@($jobsRaw)}

$job=$jobList | Where-Object {[string]$_.id -eq $JobId} | Select-Object -First 1
if(-not $job){
  [ordered]@{
    schema=1
    ok=$false
    classification='RADIOHILAL_CRON_NOT_FOUND'
    jobId=$JobId
    hermesHome=$hermesHome
    jobsPresent=$true
    secretValuesEmitted=$false
    time=(Get-Date -Format o)
  } | ConvertTo-Json -Depth 8 -Compress
  exit 21
}

function Prop($obj,[string]$name){
  if($obj.PSObject.Properties.Name -contains $name){return $obj.$name}
  return $null
}

$cfg=Read-SafeHermesConfig $configPath
$provider=[string](Prop $job 'provider')
$model=[string](Prop $job 'model')
$providerSnapshot=[string](Prop $job 'provider_snapshot')
$modelSnapshot=[string](Prop $job 'model_snapshot')
$fallbackMatch=@($cfg.fallbacks | Where-Object {
  ([string]$_.provider -eq 'openai-codex') -and ([string]$_.model -eq 'gpt-5.6-sol')
}).Count -gt 0

$primaryPinned=($provider -eq 'custom' -and $model -eq 'qwen3.8-ridge:27b-16k')
$snapshotsPinned=($providerSnapshot -eq 'custom' -and $modelSnapshot -eq 'qwen3.8-ridge:27b-16k')
$telegramModelPreserved=([string]$cfg.modelDefault -eq 'qwen3.6:35b-a3b')

$latestOutput=$null
$outputRoot=Join-Path $hermesHome ('cron\output\'+$JobId)
if(Test-Path -LiteralPath $outputRoot -PathType Container){
  $latest=Get-ChildItem -LiteralPath $outputRoot -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  if($latest){$latestOutput=[ordered]@{name=$latest.Name;lastWriteTimeUtc=$latest.LastWriteTimeUtc.ToString('o');length=$latest.Length}}
}

$ok=($primaryPinned -and $snapshotsPinned -and $fallbackMatch -and $telegramModelPreserved)
$classification=$(if($ok){'RADIOHILAL_CRON_ROUTE_VERIFIED'}else{'RADIOHILAL_CRON_ROUTE_NOT_VERIFIED'})

[ordered]@{
  schema=1
  ok=$ok
  classification=$classification
  jobId=$JobId
  hermesHome=$hermesHome
  job=[ordered]@{
    name=[string](Prop $job 'name')
    provider=$provider
    model=$model
    providerSnapshot=$providerSnapshot
    modelSnapshot=$modelSnapshot
    state=[string](Prop $job 'state')
    enabled=(Prop $job 'enabled')
    lastStatus=[string](Prop $job 'last_status')
    lastRunAt=[string](Prop $job 'last_run_at')
    nextRunAt=[string](Prop $job 'next_run_at')
  }
  mainModel=[ordered]@{
    provider=[string]$cfg.modelProvider
    model=[string]$cfg.modelDefault
    expectedTelegramModel='qwen3.6:35b-a3b'
    preserved=$telegramModelPreserved
  }
  fallback=[ordered]@{
    expectedProvider='openai-codex'
    expectedModel='gpt-5.6-sol'
    present=$fallbackMatch
    configured=@($cfg.fallbacks)
  }
  acceptance=[ordered]@{
    primaryPinned=$primaryPinned
    snapshotsPinned=$snapshotsPinned
    fallbackPresent=$fallbackMatch
    telegramModelPreserved=$telegramModelPreserved
  }
  latestOutput=$latestOutput
  configPresent=[bool]$cfg.present
  jobsPresent=$true
  readOnly=$true
  arbitraryShell=$false
  secretValuesEmitted=$false
  time=(Get-Date -Format o)
} | ConvertTo-Json -Depth 12 -Compress
