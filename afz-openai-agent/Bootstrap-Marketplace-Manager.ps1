#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$ExpectedSha='',
  [string]$JobId='marketplace-manager-install'
)
$ErrorActionPreference='Stop'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\marketplace-manager'
$appRoot='C:\AFZ\MarketplaceManager'
$src=Join-Path $InstallRoot 'afz-openai-agent\marketplace\marketplace_manager.py'
$dst=Join-Path $appRoot 'marketplace_manager.py'
$status=Join-Path $stateRoot 'latest.json'
$githubLog=Join-Path $stateRoot 'github-post.log'
$controlRepo='f3arif/faiz-homelab'
$controlIssue=15
$emergencyDir='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$emergencyAck=Join-Path $emergencyDir 'AFZ-MARKETPLACE-WORKER-ACK-LATEST.txt'
New-Item -ItemType Directory -Force -Path $stateRoot,$appRoot | Out-Null

function Save([string]$State,[string]$Message,[hashtable]$Extra=@{}){
  $o=[ordered]@{schema=1;project='marketplace-manager';jobId=$JobId;status=$State;message=$Message;expectedSha=$ExpectedSha;host=$env:COMPUTERNAME;updatedAt=(Get-Date -Format o)}
  foreach($k in $Extra.Keys){$o[$k]=$Extra[$k]}
  $o|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $status -Encoding UTF8
  return $o
}
function Log-Github([string]$Message){Add-Content -LiteralPath $githubLog -Value "$(Get-Date -Format o) $Message" -Encoding UTF8}
function Get-Gh{
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path $p){return $p}}
  return $null
}
function Prepare-GhConfig{
  foreach($dir in @('C:\Users\Faiz\AppData\Roaming\GitHub CLI','C:\Users\Faiz\AppData\Local\GitHub CLI')){
    if(Test-Path (Join-Path $dir 'hosts.yml')){$env:GH_CONFIG_DIR=$dir;return}
  }
}
function Post-Github([string]$Kind,[string]$Body){
  try{
    $gh=Get-Gh;if(-not $gh){throw 'GitHub CLI not installed'}
    Prepare-GhConfig
    & $gh auth status --hostname github.com *> $null
    if($LASTEXITCODE -ne 0){throw 'GitHub CLI is not authenticated for the worker context'}
    & $gh issue comment $controlIssue --repo $controlRepo --body "[$Kind] $Body" *> $null
    if($LASTEXITCODE -ne 0){throw "gh issue comment exit=$LASTEXITCODE"}
    Log-Github "POST_OK kind=$Kind issue=$controlRepo#$controlIssue"
    return $true
  }catch{
    Log-Github ("POST_FAIL kind=$Kind error="+$_.Exception.Message)
    return $false
  }
}
function Write-EmergencyAck([string]$State,[bool]$GithubPosted,[string]$Message){
  # Emergency observability only. Never read as request, authority, approval, or listing state.
  try{
    if(-not(Test-Path -LiteralPath $emergencyDir -PathType Container)){return}
    $safeMessage=($Message -replace '[\r\n]+',' ')
    $lines=@(
      'AFZ_MARKETPLACE_EMERGENCY_OBSERVABILITY_ONLY',
      'PROJECT=marketplace-manager',
      "JOB_ID=$JobId",
      "STATUS=$State",
      "EXPECTED_SHA=$ExpectedSha",
      "HOST=$env:COMPUTERNAME",
      "GITHUB_POST_OK=$($GithubPosted.ToString().ToLowerInvariant())",
      "MESSAGE=$safeMessage",
      "UPDATED_AT=$(Get-Date -Format o)"
    )
    [IO.File]::WriteAllText($emergencyAck,($lines -join "`r`n"),(New-Object Text.UTF8Encoding($false)))
  }catch{}
}

try{
  if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid JobId'}
  if($ExpectedSha -and $ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha must be a 40-character Git SHA'}
  if(-not(Test-Path -LiteralPath $src)){throw "Marketplace source missing: $src"}
  $py=(Get-Command python.exe -ErrorAction SilentlyContinue)
  if(-not $py){$py=(Get-Command py.exe -ErrorAction SilentlyContinue)}
  if(-not $py){throw 'Python is not available on this worker'}
  Copy-Item -LiteralPath $src -Destination $dst -Force
  $pythonExe=$py.Source
  if($py.Name -ieq 'py.exe'){
    & $pythonExe -3 -m py_compile $dst
    if($LASTEXITCODE -ne 0){throw 'Python compile validation failed'}
    & $pythonExe -3 $dst init | Out-Null
    $raw=& $pythonExe -3 $dst status
  }else{
    & $pythonExe -m py_compile $dst
    if($LASTEXITCODE -ne 0){throw 'Python compile validation failed'}
    & $pythonExe $dst init | Out-Null
    $raw=& $pythonExe $dst status
  }
  if($LASTEXITCODE -ne 0){throw 'Marketplace Manager status smoke test failed'}
  $parsed=$raw|ConvertFrom-Json
  $message='Marketplace Manager installed and dry-run core validated; no Facebook listing was changed.'
  $result=Save 'completed' $message @{appRoot=$appRoot;activeListings=[int]$parsed.active_listings;pendingActions=[int]$parsed.pending_actions;mode='install-validate-dryrun'}
  $posted=[bool](Post-Github 'RESULT' "Marketplace Manager job $JobId completed on $($result.host): install/validate PASS; active_listings=$($result.activeListings); pending_actions=$($result.pendingActions); mode=$($result.mode); source=$ExpectedSha. No Facebook listing was changed.")
  Write-EmergencyAck 'completed' $posted $message
}catch{
  $msg=$_.Exception.Message
  try{[void](Save 'failed' $msg)}catch{}
  $posted=[bool](Post-Github 'BLOCKED' "Marketplace Manager job $JobId failed during install/validate on $env:COMPUTERNAME. Reason: $msg. No Facebook listing was changed.")
  Write-EmergencyAck 'failed' $posted $msg
  throw
}
