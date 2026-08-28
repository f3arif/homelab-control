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
New-Item -ItemType Directory -Force -Path $stateRoot,$appRoot | Out-Null

function Save([string]$State,[string]$Message,[hashtable]$Extra=@{}){
  $o=[ordered]@{schema=1;project='marketplace-manager';jobId=$JobId;status=$State;message=$Message;expectedSha=$ExpectedSha;host=$env:COMPUTERNAME;updatedAt=(Get-Date -Format o)}
  foreach($k in $Extra.Keys){$o[$k]=$Extra[$k]}
  $o|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $status -Encoding UTF8
  $o|ConvertTo-Json -Depth 8 -Compress
}
try{
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
  Save 'completed' 'Marketplace Manager installed and dry-run core validated; no Facebook listing was changed.' @{appRoot=$appRoot;activeListings=[int]$parsed.active_listings;pendingActions=[int]$parsed.pending_actions;mode='install-validate-dryrun'} | Out-Null
}catch{
  Save 'failed' $_.Exception.Message | Out-Null
  throw
}
