#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [switch]$Force,
  [string]$ExpectedSha=''
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

# TEMPORARY_QWEN27B_TRANSPORT_RECOVERY_HOOK
# Preserve the exact pre-hook wrapper for every existing source-sync/recovery
# behavior, then run one bounded Qwen27B transport migration. This wrapper is
# intentionally temporary and will be restored after execution is proven.
$canonicalWrapperSha='4972f6abe1f695d9435f2b7d6575a462cbf73fc5'
$canonicalUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$canonicalWrapperSha/afz-openai-agent/Sync-AFZ-AgentFromGitHub.ps1"
$temp=Join-Path $env:TEMP ('AFZ-CanonicalSync-'+[guid]::NewGuid().ToString('n')+'.ps1')
try {
  Invoke-WebRequest -Uri $canonicalUrl -OutFile $temp -UseBasicParsing -Headers @{'User-Agent'='AFZ-Qwen27B-Temporary-Sync-Hook';'Cache-Control'='no-cache';'Pragma'='no-cache'} -TimeoutSec 60
  $tokens=$null;$errors=$null
  [void][Management.Automation.Language.Parser]::ParseFile($temp,[ref]$tokens,[ref]$errors)
  if($errors.Count -gt 0){throw ('Canonical sync wrapper parse failure: '+($errors.Message -join '; '))}

  $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$temp,'-InstallRoot',$InstallRoot)
  if($Force){$args+=@('-Force')}
  if(-not [string]::IsNullOrWhiteSpace($ExpectedSha)){$args+=@('-ExpectedSha',$ExpectedSha)}
  $raw=& powershell.exe @args | Select-Object -Last 1
  $code=$LASTEXITCODE
  if($code -ne 0){throw "Canonical sync wrapper failed exit=$code output=$raw"}
  if(-not $raw){throw 'Canonical sync wrapper returned no result'}
  if($raw -is [string]){try{$base=$raw|ConvertFrom-Json}catch{throw "Canonical sync wrapper returned invalid JSON: $raw"}}else{$base=$raw}

  $qwen27=[ordered]@{ok=$false;status='not-run'}
  try {
    $helper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Qwen27B-TransportRecovery.ps1'
    if(Test-Path -LiteralPath $helper -PathType Leaf){
      $qRaw=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot | Select-Object -Last 1
      $qCode=$LASTEXITCODE
      if($qRaw -is [string]){try{$qParsed=$qRaw|ConvertFrom-Json}catch{$qParsed=[ordered]@{status='invalid-json';raw=[string]$qRaw}}}else{$qParsed=$qRaw}
      $qwen27=[ordered]@{ok=($qCode -eq 0);status=$(if($qCode -eq 0){'completed'}else{'helper-failed'});exit=$qCode;result=$qParsed}
    } else {
      $qwen27=[ordered]@{ok=$false;status='helper-missing';path=$helper}
    }
  } catch {
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
