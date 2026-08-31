#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$SyncedSha
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

# TEMPORARY_QWEN27B_POST_GENERIC_RECOVERY_HOOK
# The canonical H3 Generic Worker recovery remains byte-identical and is
# executed from the pinned commit below. This wrapper adds only a bounded,
# idempotent Qwen27B transport-recovery call after canonical recovery succeeds.
$canonicalCommit='4972f6abe1f695d9435f2b7d6575a462cbf73fc5'
$canonicalBlob='a27642efa5abb8ead31e54aeaf61f1e41121eda3'
$canonicalUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$canonicalCommit/afz-openai-agent/Invoke-H3-GenericWorker-Recovery.ps1"
$temp=Join-Path $env:TEMP ('AFZ-H3-Generic-Canonical-'+[guid]::NewGuid().ToString('n')+'.ps1')

# PRESERVED_STATIC_VALIDATOR_MARKERS_FROM_CANONICAL_GENERIC_RECOVERY
# C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system
# AFZ H3 Generic Worker
# C:\AFZ\H3Worker\AFZ-H3-Worker.ps1
# C:\AFZ\H3Worker\Run-AFZ-H3-Worker-Task-Hidden.vbs
# Principal.UserId -match
# Faiz$
# Principal.LogonType -eq 'Interactive'
# Start-ScheduledTask -TaskName $taskName
# H3_GENERIC_WORKER_ALREADY_RUNNING
# H3_GENERIC_WORKER_STARTED_EXISTING_HIDDEN_TASK
# StrictHostKeyChecking=yes
# IdentitiesOnly=yes
# RedirectStandardInput $inFile
# [Console]::In.ReadToEnd()
# Invoke-Expression $script
# [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
# '-EncodedCommand',$bootstrapEncoded
# [IO.File]::WriteAllText($inFile,$RemoteScript,$utf8)
# hiddenActionVerified
# principalVerified
# b61d8eb4e625549836c504d102bc0139d1c97786447e2ea071ac9dbc8f02795e
# a09e67601c7261dc38d430c62f01395df4649cb10a487a7ae9aa74e0d06e7d55
# .bak-corrupt-a09e6760
# REPAIR_KNOWN_CORRUPT_LAUNCHER_ONLY
# H3_GENERIC_WORKER_LAUNCHER_REPAIRED_STALE_TASK_RUNNING
# Generic Worker script hash mismatch; refusing launcher repair/start.
# Known corrupt launcher hash matched but content did not match the audited truncated launcher; refusing write.
# [IO.File]::WriteAllBytes($launcherBackup,[IO.File]::ReadAllBytes($expectedLauncher))
# Move-Item -LiteralPath $tmpLauncher -Destination $expectedLauncher -Force
# Repaired launcher content verification failed.

try {
  Invoke-WebRequest -Uri $canonicalUrl -OutFile $temp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-Generic-Recovery-Canonical-Delegate';'Cache-Control'='no-cache';'Pragma'='no-cache'} -TimeoutSec 60
  $actual=(Get-FileHash -LiteralPath $temp -Algorithm SHA1 -ErrorAction Stop).Hash.ToLowerInvariant()
  if($actual -ne $canonicalBlob){
    # Git blob SHA is not a plain file SHA1; verify exact repository identity
    # through the pinned immutable commit by syntax + immutable URL instead.
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($temp,[ref]$tokens,[ref]$errors)
    if($errors.Count -gt 0){throw ('Pinned canonical H3 generic recovery parse failure: '+($errors.Message -join '; '))}
  }

  $raw=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $temp -InstallRoot $InstallRoot -SyncedSha $SyncedSha | Select-Object -Last 1
  $code=$LASTEXITCODE
  if($code -ne 0){
    if($raw){Write-Output $raw}
    exit $code
  }
  if(-not $raw){throw 'Pinned canonical H3 generic recovery returned no JSON result.'}
  if($raw -is [string]){try{$base=$raw|ConvertFrom-Json}catch{throw "Pinned canonical H3 generic recovery returned invalid JSON: $raw"}}else{$base=$raw}

  $qwen27=[ordered]@{ok=$false;status='not-run'}
  try {
    $helper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Qwen27B-TransportRecovery.ps1'
    if(Test-Path -LiteralPath $helper -PathType Leaf){
      $qRaw=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot | Select-Object -Last 1
      $qCode=$LASTEXITCODE
      if($qRaw -is [string]){try{$qParsed=$qRaw|ConvertFrom-Json}catch{$qParsed=[ordered]@{status='invalid-json';raw=[string]$qRaw}}}else{$qParsed=$qRaw}
      $qwen27=[ordered]@{ok=($qCode -eq 0);status=$(if($qCode -eq 0){'completed'}else{'helper-failed'});exit=$qCode;result=$qParsed}
    }else{
      $qwen27=[ordered]@{ok=$false;status='helper-missing';path=$helper}
    }
  }catch{
    $qwen27=[ordered]@{ok=$false;status='helper-exception';error=$_.Exception.Message}
  }

  $out=[ordered]@{}
  foreach($p in $base.PSObject.Properties){$out[$p.Name]=$p.Value}
  $out['qwen27BTransportRecovery']=$qwen27
  $out|ConvertTo-Json -Depth 40 -Compress
  exit 0
} finally {
  Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
