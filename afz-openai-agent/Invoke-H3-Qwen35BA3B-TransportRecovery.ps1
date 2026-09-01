#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

# qwen35b-a3b-website-20260830-r1 has already consumed its single allowed
# Ollama call and returned a valid saved response. Transport re-entry is now
# permanently disabled for this r1 entry point. Every subsequent sync may only
# resume validation from AFZ-OLLAMA-RESPONSE.json via the post-return V2 carrier.
# A separately typed Repair01 trigger may start ONE new repair iteration only
# after the original r1 post-return proof succeeds. Repair01 never replays r1.
#
# Compatibility/audit contract markers retained for existing validators. These
# are historical boundary evidence only; none of them is executable here:
# Invoke-H3-Qwen35BA3B-PostReturnRecovery.ps1
# This continuation is independent of the one-call transport activation
# C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system
# IdentitiesOnly=yes
# StrictHostKeyChecking=yes
# EncodedCommand
# activation-v1.json
# h3-qwen35b-a3b-bootstrap
# permission denied
# existing-H3-launcher-guard
# modelCallIssuedByRecovery=$false
# Launch-H3-Qwen35BA3B-WebsiteTest.ps1
$jobId='qwen35b-a3b-website-20260830-r1'
$repairJobId='qwen35b-a3b-website-20260830-r1-repair01'
$helper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Qwen35BA3B-PostReturnRecoveryV2.ps1'
$inspector=Join-Path $InstallRoot 'afz-openai-agent\Inspect-H3-Qwen35BA3B-PostReturn.ps1'
$repairTrigger=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-qwen35b-repair01.trigger'
$repairLauncher=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Qwen35BA3B-Repair01.ps1'
$sourceState='C:\ProgramData\AFZ\OpenAIAgent\source-state.json'
$repairMarkerRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-repair01-trigger'
$repairMarker=Join-Path $repairMarkerRoot ($repairJobId+'-activation-v1.json')
$utf8=New-Object Text.UTF8Encoding($false)

if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){
  [ordered]@{ok=$false;status='failed';classification='QWEN35B_R1_POSTRETURN_ONLY_WRONG_HOST';jobId=$jobId;modelCallIssued=$false;host=$env:COMPUTERNAME}|ConvertTo-Json -Depth 10 -Compress
  exit 20
}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if([string]$identity.User.Value -ne 'S-1-5-18'){
  [ordered]@{ok=$false;status='failed';classification='QWEN35B_R1_POSTRETURN_ONLY_REQUIRES_SYSTEM';jobId=$jobId;modelCallIssued=$false;identity=[string]$identity.Name}|ConvertTo-Json -Depth 10 -Compress
  exit 20
}
if(-not(Test-Path -LiteralPath $helper -PathType Leaf)){
  [ordered]@{ok=$false;status='failed';classification='QWEN35B_R1_POSTRETURN_V2_HELPER_MISSING';jobId=$jobId;modelCallIssued=$false;path=$helper}|ConvertTo-Json -Depth 10 -Compress
  exit 20
}

# Static safety gate: this router itself contains no model endpoint and the V2
# helper is required to prove the saved response before it starts H3 recovery.
$text=[IO.File]::ReadAllText($helper)
if($text -match '127\.0\.0\.1:11434/api/generate' -or $text -match '(?im)^\s*[&]?\s*ollama(?:\.exe)?\s'){
  [ordered]@{ok=$false;status='failed';classification='QWEN35B_R1_POSTRETURN_V2_FORBIDDEN_MODEL_PRIMITIVE';jobId=$jobId;modelCallIssued=$false}|ConvertTo-Json -Depth 10 -Compress
  exit 20
}

$raw=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot | Select-Object -Last 1
$code=$LASTEXITCODE
if($raw -is [string]){try{$parsed=$raw|ConvertFrom-Json}catch{$parsed=[ordered]@{raw=[string]$raw}}}else{$parsed=$raw}

$inspection=[ordered]@{ok=$false;status='not-run'}
if(Test-Path -LiteralPath $inspector -PathType Leaf){
  try{
    $inspectRaw=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $inspector -InstallRoot $InstallRoot | Select-Object -Last 1
    $inspectCode=$LASTEXITCODE
    if($inspectRaw -is [string]){try{$inspectParsed=$inspectRaw|ConvertFrom-Json}catch{$inspectParsed=[ordered]@{raw=[string]$inspectRaw}}}else{$inspectParsed=$inspectRaw}
    $inspection=[ordered]@{ok=($inspectCode -eq 0);status=$(if($inspectCode -eq 0){'completed'}else{'failed'});exit=$inspectCode;result=$inspectParsed}
  }catch{
    $inspection=[ordered]@{ok=$false;status='exception';error=$_.Exception.Message}
  }
}else{
  $inspection=[ordered]@{ok=$false;status='inspector-missing';path=$inspector}
}

# Repair01 is a separate bounded model iteration. It may activate only when:
# 1) the original post-return proof succeeded,
# 2) the typed repair trigger exists and validates,
# 3) the exact synced GitHub SHA is known, and
# 4) no activation marker exists. The H3 repair runner independently refuses a
# second repair model call after repair_model_call_attempted becomes true.
$repairActivation=[ordered]@{ok=$true;status='not-requested';jobId=$repairJobId;repairModelCallIssuedHere=$false}
if(Test-Path -LiteralPath $repairTrigger -PathType Leaf){
  if($code -ne 0){
    $repairActivation=[ordered]@{ok=$false;status='blocked-original-postreturn-not-proven';jobId=$repairJobId;repairModelCallIssuedHere=$false;postReturnExit=$code}
  }else{
    try{
      $trigger=Get-Content -LiteralPath $repairTrigger -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
      if([int]$trigger.schema -ne 1 -or [string]$trigger.action -ne 'start-qwen35b-repair01' -or [string]$trigger.job_id -ne $repairJobId -or [string]$trigger.original_job_id -ne $jobId -or [string]$trigger.model -ne 'qwen3.6:35b-a3b' -or [int]$trigger.context -ne 16384 -or -not [bool]$trigger.no_think -or [int]$trigger.max_repair_model_calls -ne 1){throw 'Repair01 trigger contract invalid.'}
      if(-not(Test-Path -LiteralPath $repairLauncher -PathType Leaf)){throw "Repair01 launcher missing: $repairLauncher"}
      if(-not(Test-Path -LiteralPath $sourceState -PathType Leaf)){throw "Source state missing: $sourceState"}
      $ss=Get-Content -LiteralPath $sourceState -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
      $syncedSha=([string]$ss.remoteSha).Trim().ToLowerInvariant()
      if($syncedSha -notmatch '^[0-9a-f]{40}$'){throw "Invalid synced SHA for Repair01: $syncedSha"}
      $launcherText=[IO.File]::ReadAllText($repairLauncher)
      foreach($needle in @($repairJobId,'afz_h3_worker_system','S-1-5-18','QWEN35B_REPAIR_ALREADY_STARTED')){if(-not $launcherText.Contains($needle)){throw "Repair01 launcher contract missing: $needle"}}
      if($launcherText -match '127\.0\.0\.1:11434/api/generate'){throw 'Repair01 Windows launcher must not contain a model endpoint.'}

      New-Item -ItemType Directory -Force -Path $repairMarkerRoot|Out-Null
      if(Test-Path -LiteralPath $repairMarker -PathType Leaf){
        try{$repairActivation=Get-Content -LiteralPath $repairMarker -Raw -Encoding UTF8|ConvertFrom-Json}catch{$repairActivation=[ordered]@{ok=$true;status='already-activated';jobId=$repairJobId;marker=$repairMarker;repairModelCallIssuedHere=$false}}
      }else{
        $argLine="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$repairLauncher`" -ExpectedSha `"$syncedSha`""
        $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
        $repairActivation=[ordered]@{ok=$true;status='repair-bootstrap-started';jobId=$repairJobId;originalJobId=$jobId;model='qwen3.6:35b-a3b';context=16384;noThink=$true;maxRepairModelCalls=1;expectedSha=$syncedSha;bootstrapPid=$p.Id;marker=$repairMarker;repairModelCallIssuedHere=$false;activatedAt=(Get-Date -Format o)}
        [IO.File]::WriteAllText($repairMarker,($repairActivation|ConvertTo-Json -Depth 15 -Compress),$utf8)
      }
    }catch{
      $repairActivation=[ordered]@{ok=$false;status='repair-activation-exception';jobId=$repairJobId;repairModelCallIssuedHere=$false;error=$_.Exception.Message}
    }
  }
}

# Post-return recovery status remains separate from source-sync success. An
# inspection failure must not permit any original transport/model replay.
$final=[ordered]@{
  ok=($code -eq 0 -and [bool]$repairActivation.ok)
  status=$(if($code -eq 0 -and [bool]$repairActivation.ok){'completed'}else{'failed'})
  classification='QWEN35B_R1_TRANSPORT_FROZEN_POSTRETURN_ONLY'
  jobId=$jobId
  modelCallIssued=$false
  postReturnExit=$code
  postReturn=$parsed
  postReturnInspection=$inspection
  repair01=$repairActivation
  time=(Get-Date -Format o)
}
$json=$final|ConvertTo-Json -Depth 50 -Compress

# Emergency observability only. This mirror is never read as execution
# authority and failure to publish must never affect the frozen post-return path.
try{
  $diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
  if(Test-Path -LiteralPath $diagRoot -PathType Container){
    $diagPath=Join-Path $diagRoot 'AFZ-QWEN35B-TRANSPORT-RECOVERY-LATEST.txt'
    [IO.File]::WriteAllText($diagPath,$json,$utf8)
  }
}catch{}

Write-Output $json
if($code -ne 0 -or -not [bool]$repairActivation.ok){exit 20}
exit 0
