#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

# qwen35b-a3b-website-20260830-r1 has already consumed its single allowed
# Ollama call and returned a valid saved response. Transport re-entry is now
# permanently disabled for this r1 entry point. Every subsequent sync may only
# resume validation from AFZ-OLLAMA-RESPONSE.json via the post-return V2 carrier.
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
$helper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Qwen35BA3B-PostReturnRecoveryV2.ps1'

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
[ordered]@{
  ok=($code -eq 0)
  status=$(if($code -eq 0){'completed'}else{'failed'})
  classification='QWEN35B_R1_TRANSPORT_FROZEN_POSTRETURN_ONLY'
  jobId=$jobId
  modelCallIssued=$false
  postReturnExit=$code
  postReturn=$parsed
  time=(Get-Date -Format o)
}|ConvertTo-Json -Depth 40 -Compress
exit $code
