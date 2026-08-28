#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [switch]$Force,
  [string]$ExpectedSha=''
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repoRef='https://api.github.com/repos/f3arif/homelab-control/git/ref/heads/main'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent'
$stateFile=Join-Path $stateRoot 'source-state.json'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
function Emit($o){$o|ConvertTo-Json -Depth 8 -Compress; exit 0}
function Publish-SiteDeployAck {
  # Emergency observability only. This helper is read-only except for its own ACK file,
  # and failure to publish must never affect the GitHub source-sync control path.
  try {
    $publisher=Join-Path $InstallRoot 'afz-openai-agent\Publish-AFZ-WebsiteDeployAck.ps1'
    if(Test-Path -LiteralPath $publisher -PathType Leaf){
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $publisher -InstallRoot $InstallRoot *> $null
    }
  } catch {}
}
$headers=@{
  'User-Agent'='AFZ-OpenAI-Agent-Updater'
  'Cache-Control'='no-cache'
  'Pragma'='no-cache'
  'Accept'='application/vnd.github+json'
}

if(-not [string]::IsNullOrWhiteSpace($ExpectedSha)){
  $ExpectedSha=$ExpectedSha.Trim().ToLowerInvariant()
  if($ExpectedSha -notmatch '^[0-9a-f]{40}$'){throw 'ExpectedSha must be a 40-character Git commit SHA'}
  $remoteSha=$ExpectedSha
  $refTransport='push-exact-sha+codeload'
}else{
  $nonce=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $remote=Invoke-RestMethod -Uri ($repoRef+'?nocache='+$nonce) -Headers $headers -TimeoutSec 30
  $remoteSha=[string]$remote.object.sha
  if([string]::IsNullOrWhiteSpace($remoteSha)){throw 'GitHub main branch SHA unavailable'}
  $remoteSha=$remoteSha.ToLowerInvariant()
  $refTransport='git-ref-no-cache+sha-pinned-codeload'
}

$repoZip="https://codeload.github.com/f3arif/homelab-control/zip/$remoteSha"
$localSha=$null
if(Test-Path $stateFile){try{$localSha=[string]((Get-Content $stateFile -Raw|ConvertFrom-Json).remoteSha)}catch{}}
if((-not $Force) -and $localSha -eq $remoteSha -and (Test-Path (Join-Path $InstallRoot 'afz-openai-agent\AFZ-OpenAI-Agent-v2.ps1'))){
  Publish-SiteDeployAck
  Emit ([ordered]@{ok=$true;changed=$false;remoteSha=$remoteSha;localSha=$localSha;installRoot=$InstallRoot;refTransport=$refTransport})
}
$temp=Join-Path $env:TEMP ('AFZ-AgentSync-'+[guid]::NewGuid().ToString('n'))
$zip=Join-Path $temp 'source.zip'
$extract=Join-Path $temp 'extract'
New-Item -ItemType Directory -Force -Path $temp,$extract | Out-Null
try{
  Invoke-WebRequest -Uri $repoZip -Headers $headers -OutFile $zip -UseBasicParsing -TimeoutSec 120
  Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
  $repoRoot=Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
  if(-not $repoRoot){throw 'Downloaded archive has no repository root directory'}
  $src=Join-Path $repoRoot.FullName 'afz-openai-agent'
  if(-not(Test-Path $src)){throw "Downloaded archive missing afz-openai-agent: $src"}
  $dst=Join-Path $InstallRoot 'afz-openai-agent'
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  $copied=@()
  foreach($f in @(Get-ChildItem -LiteralPath $src -Recurse -File)){
    $rel=$f.FullName.Substring($src.Length).TrimStart('\')
    $target=Join-Path $dst $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
    $needs=$true
    if(Test-Path $target){try{$needs=((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash)}catch{$needs=$true}}
    if($needs){Copy-Item -LiteralPath $f.FullName -Destination $target -Force; $copied+=$rel}
  }

  # Compatibility normalization for Windows PowerShell 5.1 and current Responses API schemas.
  foreach($ps1 in @(Get-ChildItem -LiteralPath $dst -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue)){
    try{
      $text=Get-Content -LiteralPath $ps1.FullName -Raw
      $fixed=$text.Replace('[Security.Cryptography.ProtectedData]','[System.Security.Cryptography.ProtectedData]').Replace('[Security.Cryptography.DataProtectionScope]','[System.Security.Cryptography.DataProtectionScope]')
      $fixed=$fixed.Replace('Send-Json $ctx 200 [ordered]@{','Send-Json $ctx 200 @{')
      $fixed=$fixed.Replace('properties=[ordered]@{};required=@();additionalProperties=$false','properties=[ordered]@{};additionalProperties=$false')
      $fixed=$fixed.Replace("Get-Content -LiteralPath `$file -Raw","Get-Content -LiteralPath `$file -Encoding UTF8 -Raw")
      # PowerShell's automatic $args variable is case-insensitive. The canonical agent historically used
      # $Args as a named tool parameter, causing JSON tool arguments such as root/path to arrive blank.
      # Normalize only the agent runtime source so ordinary scripts that intentionally use $args are untouched.
      if($ps1.Name -eq 'AFZ-OpenAI-Agent-v2.ps1'){
        $fixed=$fixed.Replace('$Args','$ToolArgs')
      }
      if($fixed -match '\[System\.Security\.Cryptography\.ProtectedData\]' -and $fixed -notmatch '(?im)^\s*Add-Type\s+-AssemblyName\s+System\.Security'){
        $load='Add-Type -AssemblyName System.Security -ErrorAction Stop'
        if($fixed -match '(?m)^\$ErrorActionPreference\s*=\s*[''\"]Stop[''\"]\s*$'){
          $fixed=[regex]::Replace($fixed,'(?m)^(\$ErrorActionPreference\s*=\s*[''\"]Stop[''\"]\s*)$',('$1'+"`r`n"+$load),1)
        }else{$fixed=$load+"`r`n"+$fixed}
      }
      if($fixed -ne $text){
        Set-Content -LiteralPath $ps1.FullName -Value $fixed -Encoding UTF8
        $relFixed=$ps1.FullName.Substring($dst.Length).TrimStart('\')
        if($copied -notcontains $relFixed){$copied+=$relFixed}
      }
    }catch{throw "Compatibility patch failed for $($ps1.FullName): $($_.Exception.Message)"}
  }

  # One-shot transport-state migration for the Ridge16K job. The model job id is
  # intentionally unchanged. A recovery generation may clear only a terminal
  # pre-launch watcher failure once; the marker prevents replay on later syncs.
  $ridgeRecoveryReset=$false
  $ridgeRequest=Join-Path $dst 'requests\h3-qwenridge16k-website-test.json'
  if(Test-Path -LiteralPath $ridgeRequest -PathType Leaf){
    try{
      $rr=Get-Content -LiteralPath $ridgeRequest -Raw|ConvertFrom-Json
      $generation=0
      if($rr.PSObject.Properties.Name -contains 'recovery_generation'){$generation=[int]$rr.recovery_generation}
      if($generation -gt 0 -and ([string]$rr.job_id) -match '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){
        $ridgeStateRoot=Join-Path $stateRoot 'jobs\h3-qwenridge16k-request'
        New-Item -ItemType Directory -Force -Path $ridgeStateRoot|Out-Null
        $ridgeWatch=Join-Path $ridgeStateRoot 'request-watcher.json'
        $marker=Join-Path $ridgeStateRoot ("transport-recovery-g$generation-"+[string]$rr.job_id+'.applied')
        if(-not(Test-Path -LiteralPath $marker)){
          $prior=$null
          if(Test-Path -LiteralPath $ridgeWatch){try{$prior=Get-Content -LiteralPath $ridgeWatch -Raw|ConvertFrom-Json}catch{}}
          if($prior -and [string]$prior.jobId -eq [string]$rr.job_id -and [string]$prior.status -in @('failed','error')){
            Remove-Item -LiteralPath $ridgeWatch -Force
            $ridgeRecoveryReset=$true
          }
          if(-not $prior -or [string]$prior.jobId -eq [string]$rr.job_id){
            Set-Content -LiteralPath $marker -Value ("job="+[string]$rr.job_id+" generation=$generation source=$remoteSha reset=$ridgeRecoveryReset time="+(Get-Date -Format o)) -Encoding ASCII
          }
        }
      }
    }catch{throw "Ridge16K transport recovery migration failed: $($_.Exception.Message)"}
  }

  $state=[ordered]@{remoteSha=$remoteSha;syncedAt=(Get-Date -Format o);installRoot=$InstallRoot;copied=$copied;compatibility='windows-powershell-5.1-dpapi-health-json-responses-zeroarg-utf8-ui-fast-signal-toolargs';ridge16kTransportRecoveryReset=$ridgeRecoveryReset;refTransport=$refTransport}
  $state|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $stateFile -Encoding UTF8
  Publish-SiteDeployAck
  # Only agent-tree file changes require a service restart. A branch-head-only signal commit must not restart services.
  Emit ([ordered]@{ok=$true;changed=($copied.Count -gt 0);remoteSha=$remoteSha;localSha=$localSha;copied=$copied;ridge16kTransportRecoveryReset=$ridgeRecoveryReset;installRoot=$InstallRoot;refTransport=$refTransport})
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
