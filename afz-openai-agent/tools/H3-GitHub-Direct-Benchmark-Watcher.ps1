#Requires -Version 5.1
[CmdletBinding()]
param(
  [int]$IntervalSeconds = 10,
  [string]$ProjectRoot = 'C:\Projects\Qwen38-27B-Website-Benchmark-20260826-174739',
  [string]$Model = 'qwen3.8:27b'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$IntervalSeconds = [Math]::Max(5,[Math]::Min($IntervalSeconds,60))
$repo = 'f3arif/homelab-control'
$requestPath = 'afz-openai-agent/requests/h3-qwen27b-benchmark.json'
$controllerPath = 'afz-openai-agent/tools/Run-H3-Qwen27B-WebsiteBenchmark.ps1'
$resultBranch = 'h3-direct-results'
$resultPath = 'afz-openai-agent/results/h3-qwen27b-benchmark-latest.json'
$controlRepo = 'f3arif/faiz-homelab'
$controlIssue = 12
$stateRoot = 'C:\ProgramData\AFZ\H3GitHubDirect'
$stateFile = Join-Path $stateRoot 'state.json'
$logFile = Join-Path $stateRoot 'watcher.log'
$controllerFile = Join-Path $stateRoot 'Run-H3-Qwen27B-WebsiteBenchmark.ps1'
$gitRoot = 'C:\AFZ\homelab-control-direct'
$utf8 = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Log([string]$Message){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8}
function Write-Json([string]$Path,$Object){$parent=Split-Path $Path -Parent;if($parent -and -not(Test-Path $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null};[IO.File]::WriteAllText($Path,($Object|ConvertTo-Json -Depth 20 -Compress),$utf8)}
function Read-Json([string]$Path){if(-not(Test-Path $Path)){return $null};try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return $null}}
function Get-MainSha{
  $h=@{'User-Agent'='AFZ-H3-GitHub-Direct';'Cache-Control'='no-cache'}
  $r=Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/commits/main" -Headers $h -TimeoutSec 30
  $sha=[string]$r.sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Could not resolve GitHub main SHA'}
  return $sha
}
function Get-Request([string]$Sha){
  $n=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $u="https://raw.githubusercontent.com/$repo/$Sha/$requestPath?nocache=$n"
  $raw=(Invoke-WebRequest -Uri $u -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-GitHub-Direct';'Cache-Control'='no-cache'} -TimeoutSec 30).Content
  $r=$raw|ConvertFrom-Json
  if([int]$r.schema -ne 1 -or [string]$r.project -ne 'qwen38-27b-website-benchmark'){throw 'Typed request schema/project mismatch'}
  if(([string]$r.job_id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid job_id'}
  $s=[int]$r.start_iteration;$m=[int]$r.max_iterations
  if($s -lt 1 -or $s -gt 8 -or $m -lt $s -or $m -gt 8){throw 'Invalid iteration bounds'}
  return $r
}
function Download-Controller([string]$Sha){
  $u="https://raw.githubusercontent.com/$repo/$Sha/$controllerPath"
  Invoke-WebRequest -Uri $u -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-GitHub-Direct'} -OutFile $controllerFile -TimeoutSec 60
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($controllerFile,[ref]$tokens,[ref]$errors)
  if($errors.Count -gt 0){throw ('Downloaded controller parse failure: '+($errors.Message -join '; '))}
}
function Get-Gh{
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path $p){return $p}}
  return $null
}
function Try-GhComment([string]$Kind,[string]$Body){
  try{
    $gh=Get-Gh;if(-not $gh){throw 'gh not installed'}
    & $gh auth status --hostname github.com *> $null
    if($LASTEXITCODE -ne 0){throw 'gh not authenticated'}
    & $gh issue comment $controlIssue --repo $controlRepo --body "[$Kind][H3-DIRECT] $Body" *> $null
    if($LASTEXITCODE -ne 0){throw "gh comment exit=$LASTEXITCODE"}
    Log "GITHUB_COMMENT_OK kind=$Kind"
    return $true
  }catch{Log ("GITHUB_COMMENT_FAIL "+$_.Exception.Message);return $false}
}
function Try-PushResult($Result,[string]$JobId,[string]$SourceSha){
  try{
    $git=(Get-Command git.exe -ErrorAction Stop).Source
    $gh=Get-Gh
    if($gh){try{& $gh auth setup-git *> $null}catch{}}
    if(-not(Test-Path (Join-Path $gitRoot '.git'))){
      if(Test-Path $gitRoot){Remove-Item -LiteralPath $gitRoot -Recurse -Force}
      & $git clone --quiet "https://github.com/$repo.git" $gitRoot
      if($LASTEXITCODE -ne 0){throw 'git clone failed'}
    }
    & $git -C $gitRoot fetch origin $resultBranch --quiet
    if($LASTEXITCODE -ne 0){throw 'git fetch result branch failed'}
    & $git -C $gitRoot checkout -B $resultBranch "origin/$resultBranch" --quiet
    if($LASTEXITCODE -ne 0){throw 'git checkout result branch failed'}
    $dest=Join-Path $gitRoot ($resultPath.Replace('/','\'))
    $summary=[ordered]@{schema=1;transport='h3-direct-github';job_id=$JobId;source_sha=$SourceSha;worker='H3';host=$env:COMPUTERNAME;result=$Result;published_at=(Get-Date -Format o)}
    Write-Json $dest $summary
    & $git -C $gitRoot config user.name 'AFZ H3 Direct Worker'
    & $git -C $gitRoot config user.email 'h3-direct@afz.local'
    & $git -C $gitRoot add $resultPath
    & $git -C $gitRoot diff --cached --quiet
    if($LASTEXITCODE -eq 0){Log 'GIT_RESULT_ALREADY_CURRENT';return $true}
    & $git -C $gitRoot commit -m "H3 direct benchmark result $JobId" --quiet
    if($LASTEXITCODE -ne 0){throw 'git commit failed'}
    & $git -C $gitRoot push origin $resultBranch --quiet
    if($LASTEXITCODE -ne 0){throw 'git push failed'}
    Log "GIT_RESULT_PUSH_OK job=$JobId"
    return $true
  }catch{Log ("GIT_RESULT_PUSH_FAIL "+$_.Exception.Message);return $false}
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZH3GitHubDirectBenchmarkWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "This watcher is H3-only; host=$env:COMPUTERNAME"}
  Log "START interval=${IntervalSeconds}s project=$ProjectRoot model=$Model"
  while($true){
    try{
      $sha=Get-MainSha
      $req=Get-Request $sha
      $job=[string]$req.job_id
      $state=Read-Json $stateFile
      if($state -and [string]$state.job_id -eq $job -and [string]$state.status -in @('completed','failed')){Start-Sleep -Seconds $IntervalSeconds;continue}

      Write-Json $stateFile ([ordered]@{job_id=$job;status='running';source_sha=$sha;start_iteration=[int]$req.start_iteration;max_iterations=[int]$req.max_iterations;started_at=(Get-Date -Format o)})
      [void](Try-GhComment 'STATUS' "Job $job started directly on H3 from GitHub. Iterations $($req.start_iteration)-$($req.max_iterations). No AFZ queue/claim path is used.")
      Download-Controller $sha

      $out=Join-Path $stateRoot "$job.stdout.log";$err=Join-Path $stateRoot "$job.stderr.log"
      Remove-Item $out,$err -Force -ErrorAction SilentlyContinue
      $p=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$controllerFile,'-ProjectRoot',$ProjectRoot,'-Model',$Model,'-StartIteration',[string][int]$req.start_iteration,'-MaxIterations',[string][int]$req.max_iterations) -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -Wait -PassThru -NoNewWindow
      $stdout=if(Test-Path $out){Get-Content $out -Raw}else{''}
      $marker=@($stdout -split "`r?`n"|Where-Object {$_.StartsWith('AFZ_RESULT_JSON=')}|Select-Object -Last 1)
      if($marker.Count -eq 0){throw "Benchmark controller returned no AFZ_RESULT_JSON marker; exit=$($p.ExitCode)"}
      $result=$marker[0].Substring('AFZ_RESULT_JSON='.Length)|ConvertFrom-Json
      $status=if([bool]$result.ok){'completed'}else{'failed'}
      Write-Json $stateFile ([ordered]@{job_id=$job;status=$status;source_sha=$sha;result=$result;finished_at=(Get-Date -Format o)})
      $pushed=Try-PushResult $result $job $sha
      $commented=Try-GhComment 'RESULT' "Job $job finished: status=$($result.benchmarkStatus); iteration=$($result.lastIteration); build_exit=$($result.buildExit); routes=$($result.routesPassing)/$($result.routesTotal); reason=$($result.reason). ResultBranchPush=$pushed"
      Log "FINISH job=$job status=$status pushed=$pushed commented=$commented"
    }catch{
      $msg=$_.Exception.Message
      Log "ERROR $msg"
      try{Write-Json $stateFile ([ordered]@{job_id=$(if($job){$job}else{''});status='failed';error=$msg;finished_at=(Get-Date -Format o)})}catch{}
      try{[void](Try-GhComment 'BLOCKED' $msg)}catch{}
    }
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
