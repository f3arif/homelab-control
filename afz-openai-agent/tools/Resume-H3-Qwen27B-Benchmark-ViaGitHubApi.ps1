#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$ProjectRoot = 'C:\Projects\Qwen38-27B-Website-Benchmark-20260826-174739',
  [string]$Model = 'qwen3.8:27b'
)

$ErrorActionPreference='Stop'
$repo='f3arif/homelab-control'
$controlRepo='f3arif/faiz-homelab'
$controlIssue=12
$alertIssue=7
$requestPath='afz-openai-agent/requests/h3-qwen27b-benchmark.json'
$controllerPath='afz-openai-agent/tools/Run-H3-Qwen27B-WebsiteBenchmark.ps1'
$resultBranch='h3-direct-results'
$resultPath='afz-openai-agent/results/h3-qwen27b-benchmark-latest.json'
$statusPath='afz-openai-agent/results/h3-qwen27b-benchmark-status.json'
$stateRoot='C:\ProgramData\AFZ\H3GitHubDirect'
$stateFile=Join-Path $stateRoot 'state.json'
$controllerFile=Join-Path $stateRoot 'Run-H3-Qwen27B-WebsiteBenchmark.ps1'
$stdoutFile=Join-Path $stateRoot 'direct-resume.stdout.log'
$stderrFile=Join-Path $stateRoot 'direct-resume.stderr.log'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Find-Gh {
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path $p){return $p}}
  return $null
}
$gh=Find-Gh
if(-not $gh){throw 'GitHub CLI not found on H3.'}
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only resume path; host=$env:COMPUTERNAME"}

function Invoke-Gh([string[]]$Arguments,[switch]$AllowFailure){
  $old=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    $out=@(& $gh @Arguments 2>$null)
    $code=$LASTEXITCODE
  }finally{$ErrorActionPreference=$old}
  if(-not $AllowFailure -and $code -ne 0){throw "gh failed exit=$code args=$($Arguments -join ' ')"}
  return [pscustomobject]@{ExitCode=$code;Output=$out}
}
function Write-Json([string]$Path,$Object){[IO.File]::WriteAllText($Path,($Object|ConvertTo-Json -Depth 30 -Compress),$utf8)}
function Comment([string]$Repo,[int]$Issue,[string]$Body){
  $r=Invoke-Gh -Arguments @('issue','comment',[string]$Issue,'--repo',$Repo,'--body',$Body) -AllowFailure
  return ($r.ExitCode -eq 0)
}
function Get-ContentAt([string]$Path,[string]$Ref){
  $r=Invoke-Gh -Arguments @('api',"repos/$repo/contents/$Path?ref=$Ref")
  $j=($r.Output -join "`n")|ConvertFrom-Json
  if([string]$j.encoding -ne 'base64' -or [string]::IsNullOrWhiteSpace([string]$j.content)){throw "GitHub content response invalid for $Path@$Ref"}
  $b64=([string]$j.content) -replace '\s',''
  return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}
function Publish-Json([string]$Path,$Object,[string]$Message){
  $json=$Object|ConvertTo-Json -Depth 30 -Compress
  $payload=[ordered]@{message=$Message;content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json));branch=$resultBranch}
  $existing=Invoke-Gh -Arguments @('api',"repos/$repo/contents/$Path?ref=$resultBranch",'--jq','.sha') -AllowFailure
  if($existing.ExitCode -eq 0){$sha=([string]($existing.Output -join '')).Trim();if($sha -match '^[0-9a-f]{40}$'){$payload.sha=$sha}}
  $tmp=Join-Path $stateRoot ('publish-'+[guid]::NewGuid().ToString('N')+'.json')
  try{
    [IO.File]::WriteAllText($tmp,($payload|ConvertTo-Json -Compress),$utf8)
    $put=Invoke-Gh -Arguments @('api','--method','PUT',"repos/$repo/contents/$Path",'--input',$tmp) -AllowFailure
    return ($put.ExitCode -eq 0)
  }finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
}
function Controller-Running {
  try{
    foreach($p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"){
      $cmd=[string]$p.CommandLine
      if($cmd -and $cmd.Contains('Run-H3-Qwen27B-WebsiteBenchmark.ps1') -and $cmd.Contains($ProjectRoot)){return $true}
    }
  }catch{}
  return $false
}

$auth=Invoke-Gh -Arguments @('auth','status','--hostname','github.com') -AllowFailure
if($auth.ExitCode -ne 0){throw 'GitHub CLI authentication is not valid on H3.'}
$perm=Invoke-Gh -Arguments @('api',"repos/$repo",'--jq','.permissions.push')
if((([string]($perm.Output -join '')).Trim().ToLowerInvariant()) -ne 'true'){throw 'H3 GitHub identity lacks repository write permission.'}

# Stop only the obsolete scheduled watcher loop so it cannot keep emitting the old raw-CDN 404 blocker.
try{Stop-ScheduledTask -TaskName 'AFZ H3 GitHub Direct Benchmark Watcher' -ErrorAction SilentlyContinue}catch{}
try{
  foreach($p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"){
    if($p.ProcessId -eq $PID){continue}
    $cmd=[string]$p.CommandLine
    if($cmd -and ($cmd.Contains('H3-GitHub-Direct-Benchmark-Watcher.ps1') -or $cmd.Contains('Start-H3-GitHub-Direct-Benchmark.ps1'))){
      try{Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue}catch{}
    }
  }
}catch{}

if(Controller-Running){
  [void](Comment $controlRepo $controlIssue '[STATUS][H3-DIRECT] Existing Qwen benchmark controller is already running on H3; API resume did not launch a duplicate.')
  Write-Output 'AFZ_H3_RESUME=already-running'
  exit 0
}

$main=Invoke-Gh -Arguments @('api',"repos/$repo/commits/main",'--jq','.sha')
$sourceSha=([string]($main.Output -join '')).Trim()
if($sourceSha -notmatch '^[0-9a-f]{40}$'){throw 'Could not resolve GitHub main SHA through authenticated API.'}

$requestRaw=Get-ContentAt $requestPath $sourceSha
$req=$requestRaw|ConvertFrom-Json
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'qwen38-27b-website-benchmark'){throw 'Typed request schema/project mismatch.'}
$job=[string]$req.job_id
$start=[int]$req.start_iteration
$max=[int]$req.max_iterations
if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$' -or $start -lt 1 -or $max -lt $start -or $max -gt 8){throw 'Typed request bounds/job id invalid.'}

$controllerRaw=Get-ContentAt $controllerPath $sourceSha
[IO.File]::WriteAllText($controllerFile,$controllerRaw,$utf8)
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($controllerFile,[ref]$tokens,[ref]$errors)
if($errors.Count -gt 0){throw ('Controller parse failure: '+($errors.Message -join '; '))}

$running=[ordered]@{schema=1;transport='h3-direct-github';kind='status';job_id=$job;source_sha=$sourceSha;worker='H3';host=$env:COMPUTERNAME;status='running';message="Authenticated GitHub API resume started on H3. Iterations $start-$max. AFZ queue/claims bypassed.";published_at=(Get-Date -Format o)}
Write-Json $stateFile ([ordered]@{job_id=$job;status='running';source_sha=$sourceSha;start_iteration=$start;max_iterations=$max;started_at=(Get-Date -Format o);transport='github-api-resume'})
$statusPublished=Publish-Json $statusPath $running "H3 direct benchmark running $job"
[void](Comment $controlRepo $controlIssue "[STATUS][H3-DIRECT] Job $job started directly on H3 through authenticated GitHub API content retrieval. Iterations $start-$max. No AFZ queue/claim path is used. StatusBranchPush=$statusPublished")

Remove-Item $stdoutFile,$stderrFile -Force -ErrorAction SilentlyContinue
$p=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$controllerFile,'-ProjectRoot',$ProjectRoot,'-Model',$Model,'-StartIteration',[string]$start,'-MaxIterations',[string]$max) -WorkingDirectory $ProjectRoot -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -Wait -PassThru -NoNewWindow
$stdout=if(Test-Path $stdoutFile){Get-Content $stdoutFile -Raw}else{''}
$marker=@($stdout -split "`r?`n"|Where-Object {$_.StartsWith('AFZ_RESULT_JSON=')}|Select-Object -Last 1)
if($marker.Count -eq 0){
  $errTail=if(Test-Path $stderrFile){(@(Get-Content $stderrFile)|Select-Object -Last 30)-join ' | '}else{''}
  $msg="Benchmark controller returned no AFZ_RESULT_JSON marker; exit=$($p.ExitCode); stderr=$errTail"
  Write-Json $stateFile ([ordered]@{job_id=$job;status='failed';source_sha=$sourceSha;error=$msg;finished_at=(Get-Date -Format o);transport='github-api-resume'})
  [void](Comment $controlRepo $controlIssue "[BLOCKED][H3-DIRECT] $msg")
  throw $msg
}
$result=$marker[0].Substring('AFZ_RESULT_JSON='.Length)|ConvertFrom-Json
$status=if([bool]$result.ok){'completed'}else{'failed'}
Write-Json $stateFile ([ordered]@{job_id=$job;status=$status;source_sha=$sourceSha;result=$result;finished_at=(Get-Date -Format o);transport='github-api-resume'})
$summary=[ordered]@{schema=1;transport='h3-direct-github';job_id=$job;source_sha=$sourceSha;worker='H3';host=$env:COMPUTERNAME;result=$result;published_at=(Get-Date -Format o)}
$resultPublished=Publish-Json $resultPath $summary "H3 direct benchmark result $job"
$finalStatus=[ordered]@{schema=1;transport='h3-direct-github';kind='status';job_id=$job;source_sha=$sourceSha;worker='H3';host=$env:COMPUTERNAME;status=$status;message="Benchmark finished: status=$($result.benchmarkStatus); iteration=$($result.lastIteration); routes=$($result.routesPassing)/$($result.routesTotal).";published_at=(Get-Date -Format o)}
[void](Publish-Json $statusPath $finalStatus "H3 direct benchmark $status $job")
[void](Comment $controlRepo $controlIssue "[RESULT][H3-DIRECT] Job $job finished: status=$($result.benchmarkStatus); iteration=$($result.lastIteration); build_exit=$($result.buildExit); routes=$($result.routesPassing)/$($result.routesTotal); reason=$($result.reason). ResultBranchPush=$resultPublished")
[void](Comment $repo $alertIssue "[H3-DIRECT RESULT] @f3arif job=$job status=$($result.benchmarkStatus) iteration=$($result.lastIteration) build_exit=$($result.buildExit) routes=$($result.routesPassing)/$($result.routesTotal) reason=$($result.reason)")
Write-Output ('AFZ_RESULT_JSON='+($summary|ConvertTo-Json -Depth 30 -Compress))
