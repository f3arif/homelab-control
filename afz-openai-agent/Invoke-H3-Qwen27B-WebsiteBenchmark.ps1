#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$JobId,
  [int]$StartIteration=2,
  [int]$MaxIterations=5,
  [Parameter(Mandatory=$true)][string]$ExpectedSha
)

$ErrorActionPreference='Stop'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen27b'
$stateFile=Join-Path $stateRoot 'latest.json'
$logRoot=Join-Path $stateRoot $JobId
$outFile=Join-Path $logRoot 'h3.stdout.log'
$errFile=Join-Path $logRoot 'h3.stderr.log'
$githubLog=Join-Path $logRoot 'github-post.log'
$knownHosts='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$key='C:\Users\Faiz\.ssh\afz_h3_worker'
$h3='Faiz@100.106.186.118'
$projectRoot='C:\Projects\Qwen38-27B-Website-Benchmark-20260826-174739'
$model='qwen3.8:27b'
$controlRepo='f3arif/faiz-homelab'
$controlIssue=12
$utf8=New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot,$logRoot | Out-Null

function Write-State([string]$Status,[string]$Message,$Result=$null){
  $o=[ordered]@{ok=($Status -notin @('failed','error'));jobId=$JobId;status=$Status;message=$Message;worker='H3';host='DESKTOP-H3R6CQN';model=$model;project='qwen38-27b-website-benchmark';relayPid=$PID;startedAt=$script:startedAt;updatedAt=(Get-Date -Format o);expectedSha=$ExpectedSha;startIteration=$StartIteration;maxIterations=$MaxIterations}
  if($Result){$o.result=$Result}
  [IO.File]::WriteAllText($stateFile,($o|ConvertTo-Json -Depth 20 -Compress),$utf8)
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
    $payload="[$Kind] $Body"
    & $gh issue comment $controlIssue --repo $controlRepo --body $payload *> $null
    if($LASTEXITCODE -ne 0){throw "gh issue comment exit=$LASTEXITCODE"}
    Log-Github "POST_OK kind=$Kind issue=$controlRepo#$controlIssue"
    return $true
  }catch{
    Log-Github ("POST_FAIL kind=$Kind error="+$_.Exception.Message)
    return $false
  }
}

$startedAt=(Get-Date -Format o)
try{
  if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid JobId'}
  if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha must be a 40-character commit SHA'}
  $ExpectedSha=$ExpectedSha.ToLowerInvariant()
  if($StartIteration -lt 1 -or $StartIteration -gt 8){throw 'StartIteration out of range'}
  if($MaxIterations -lt $StartIteration -or $MaxIterations -gt 8){throw 'MaxIterations out of range'}
  if(-not(Test-Path $key)){throw "H3 SSH key missing: $key"}
  $ssh=(Get-Command ssh.exe -ErrorAction Stop).Source
  Write-State 'running' 'Preparing exact-SHA H3 benchmark controller.'
  [void](Post-Github 'STATUS' "H3 Qwen27B benchmark job `$JobId=$JobId` started. Model `$model`, repair iterations $StartIteration-$MaxIterations, GitHub source `$ExpectedSha`. Qwen remains the only website code author.")

  $rawUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/Run-H3-Qwen27B-WebsiteBenchmark.ps1"
  $remote=@"
`$ErrorActionPreference='Stop'
`$dir='C:\AFZ\QwenBenchmark'
New-Item -ItemType Directory -Force -Path `$dir | Out-Null
`$script=Join-Path `$dir 'Run-H3-Qwen27B-WebsiteBenchmark.ps1'
Invoke-WebRequest -Uri '$rawUrl' -OutFile `$script -UseBasicParsing -TimeoutSec 60
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$script -ProjectRoot '$projectRoot' -Model '$model' -StartIteration $StartIteration -MaxIterations $MaxIterations
exit `$LASTEXITCODE
"@
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
  $args=@('-i',$key,'-o','BatchMode=yes','-o','ConnectTimeout=12','-o','ServerAliveInterval=30','-o','ServerAliveCountMax=6','-o','StrictHostKeyChecking=accept-new','-o',"UserKnownHostsFile=$knownHosts",$h3,'powershell.exe','-NoProfile','-EncodedCommand',$encoded)
  Write-State 'running' 'Executing bounded Qwen benchmark loop on H3.'
  $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait -PassThru -NoNewWindow
  $stdout='';if(Test-Path $outFile){$stdout=Get-Content $outFile -Raw}
  $marker=@($stdout -split "`r?`n" | Where-Object {$_.StartsWith('AFZ_RESULT_JSON=')} | Select-Object -Last 1)
  if($marker.Count -eq 0){throw "H3 benchmark returned no AFZ_RESULT_JSON marker. sshExit=$($p.ExitCode)"}
  $json=$marker[0].Substring('AFZ_RESULT_JSON='.Length)
  $result=$json|ConvertFrom-Json
  $status=if([bool]$result.ok){'completed'}else{'failed'}
  Write-State $status ("H3 benchmark finished: "+[string]$result.benchmarkStatus) $result
  $resultBody="H3 Qwen27B benchmark job `$JobId=$JobId` finished: status=$([string]$result.benchmarkStatus); last_iteration=$([string]$result.lastIteration); build_exit=$([string]$result.buildExit); build_seconds=$([string]$result.buildSeconds); routes=$([string]$result.routesPassing)/$([string]$result.routesTotal); reason=$([string]$result.reason); completed=$([string]$result.completedAt)."
  [void](Post-Github 'RESULT' $resultBody)
  if([bool]$result.ok){exit 0}else{exit 2}
} catch {
  $msg=$_.Exception.Message
  try{Write-State 'failed' $msg}catch{}
  [void](Post-Github 'BLOCKED' "H3 Qwen27B benchmark job `$JobId=$JobId` stopped before a successful result. Reason: $msg")
  Write-Error $msg
  exit 1
}
