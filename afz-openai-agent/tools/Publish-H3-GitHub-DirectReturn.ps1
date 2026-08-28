#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Repo = 'f3arif/homelab-control',
  [string]$ResultBranch = 'h3-direct-results',
  [string]$StateFile = 'C:\ProgramData\AFZ\H3GitHubDirect\state.json'
)

$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only return publisher; host=$env:COMPUTERNAME"}
$resultPath='afz-openai-agent/results/h3-qwen27b-benchmark-latest.json'
$statusPath='afz-openai-agent/results/h3-qwen27b-benchmark-status.json'
$controlRepo='f3arif/faiz-homelab'
$controlIssue=12
$alertIssue=7
$root='C:\ProgramData\AFZ\H3GitHubDirect'
$publisherState=Join-Path $root 'return-publisher.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root|Out-Null

function Get-Gh{
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path $p){return $p}}
  return $null
}
function Invoke-Gh([string[]]$Arguments){
  $old=$ErrorActionPreference
  try{$ErrorActionPreference='Continue';$out=@(& $script:gh @Arguments 2>&1);$code=$LASTEXITCODE}
  finally{$ErrorActionPreference=$old}
  [pscustomobject]@{ExitCode=$code;Output=$out;Text=([string]($out -join "`n"))}
}
function Write-LocalJson([string]$Path,$Object){[IO.File]::WriteAllText($Path,($Object|ConvertTo-Json -Depth 30 -Compress),$utf8)}
function Get-Fingerprint([string]$Text){
  $sha=[Security.Cryptography.SHA256]::Create()
  try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant())}
  finally{$sha.Dispose()}
}
function Get-RemoteSha([string]$Path){
  $r=Invoke-Gh @('api',"repos/$Repo/contents/$Path`?ref=$ResultBranch",'--jq','.sha')
  if($r.ExitCode -ne 0){return $null}
  $s=$r.Text.Trim();if($s -match '^[0-9a-f]{40}$'){return $s};return $null
}
function Put-JsonFile([string]$Path,$Object,[string]$Message){
  $json=$Object|ConvertTo-Json -Depth 30 -Compress
  $payload=[ordered]@{message=$Message;content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json));branch=$ResultBranch}
  $remoteSha=Get-RemoteSha $Path
  if($remoteSha){$payload.sha=$remoteSha}
  $tmp=Join-Path $env:TEMP ("afz-gh-put-"+[guid]::NewGuid().ToString('N')+'.json')
  try{
    [IO.File]::WriteAllText($tmp,($payload|ConvertTo-Json -Compress),$utf8)
    $r=Invoke-Gh @('api',"repos/$Repo/contents/$Path",'--method','PUT','--input',$tmp)
    if($r.ExitCode -ne 0){throw "GitHub contents PUT failed path=$Path exit=$($r.ExitCode): $($r.Text)"}
  }finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
}
function Try-Comment([string]$Body){
  $ok=$true
  foreach($target in @(@{Repo=$Repo;Issue=$alertIssue},@{Repo=$controlRepo;Issue=$controlIssue})){
    $r=Invoke-Gh @('issue','comment',[string]$target.Issue,'--repo',[string]$target.Repo,'--body',$Body)
    if($r.ExitCode -ne 0){$ok=$false}
  }
  return $ok
}

$gh=Get-Gh
if(-not $gh){throw 'GitHub CLI is not installed on H3.'}
$script:gh=$gh
$auth=Invoke-Gh @('auth','status','--hostname','github.com')
if($auth.ExitCode -ne 0){throw 'GitHub CLI is not authenticated in the H3 return-publisher context.'}
$perm=Invoke-Gh @('api',"repos/$Repo",'--jq','.permissions.push')
if($perm.ExitCode -ne 0 -or $perm.Text.Trim().ToLowerInvariant() -ne 'true'){throw 'Authenticated H3 GitHub identity lacks push permission.'}
if(-not(Test-Path $StateFile)){throw "Benchmark state file missing: $StateFile"}
$raw=Get-Content -LiteralPath $StateFile -Raw
$state=$raw|ConvertFrom-Json
$job=[string]$state.job_id
$status=[string]$state.status
$sourceSha=[string]$state.source_sha
if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid or missing job_id in local state.'}
if($status -notin @('running','completed','failed')){throw "Unsupported local state status: $status"}
$fingerprint=Get-Fingerprint $raw
$prior=$null;if(Test-Path $publisherState){try{$prior=Get-Content $publisherState -Raw|ConvertFrom-Json}catch{}}
$branchDone=($prior -and [string]$prior.fingerprint -eq $fingerprint -and [bool]$prior.branch_published)
$commentDone=($prior -and [string]$prior.fingerprint -eq $fingerprint -and [bool]$prior.comment_published)
if(-not $branchDone){
  $message=if($status -eq 'running'){'Existing benchmark controller state recovered from H3.'}elseif($state.result){'Terminal benchmark state recovered from H3 and published without rerunning Qwen.'}elseif($state.error){[string]$state.error}else{'Terminal H3 benchmark state contains no result payload.'}
  $statusDoc=[ordered]@{schema=1;transport='h3-direct-github';kind='status';job_id=$job;source_sha=$sourceSha;worker='H3';host=$env:COMPUTERNAME;status=$status;message=$message;published_at=(Get-Date -Format o)}
  Put-JsonFile $statusPath $statusDoc "H3 direct benchmark status $status $job"
  if($status -in @('completed','failed') -and $state.result){
    $resultDoc=[ordered]@{schema=1;transport='h3-direct-github';job_id=$job;source_sha=$sourceSha;worker='H3';host=$env:COMPUTERNAME;result=$state.result;published_at=(Get-Date -Format o)}
    Put-JsonFile $resultPath $resultDoc "H3 direct benchmark result $job"
  }
  $branchDone=$true
}
if(-not $commentDone){
  $detail=if($state.result){"benchmarkStatus=$($state.result.benchmarkStatus); iteration=$($state.result.lastIteration); routes=$($state.result.routesPassing)/$($state.result.routesTotal)"}elseif($state.error){"error=$($state.error)"}else{"status=$status"}
  $commentDone=Try-Comment "[H3-DIRECT RETURN] job=$job; status=$status; $detail. Durable result/status publication uses the GitHub Contents API; no benchmark rerun was performed."
}
Write-LocalJson $publisherState ([ordered]@{schema=1;fingerprint=$fingerprint;job_id=$job;status=$status;branch_published=$branchDone;comment_published=$commentDone;updated_at=(Get-Date -Format o)})
[pscustomobject]@{ok=$branchDone;job_id=$job;status=$status;branch_published=$branchDone;comment_published=$commentDone;result_published=([bool]($state.result -and $status -in @('completed','failed')));transport='gh-contents-api';fingerprint=$fingerprint}|ConvertTo-Json -Compress
if(-not $branchDone){exit 1}
