#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Repo='f3arif/homelab-control',
  [string]$ResultBranch='h3-direct-results',
  [string]$ProjectRoot='C:\Projects\Qwen38-27B-Website-Benchmark-20260826-174739'
)

$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only return publisher; host=$env:COMPUTERNAME"}
$root='C:\ProgramData\AFZ\H3GitHubDirect'
$stateFile=Join-Path $root 'state.json'
$publisherState=Join-Path $root 'return-publisher-v3.json'
$returnEnvelope=Join-Path $root 'return-envelope.json'
$resultPath='afz-openai-agent/results/h3-qwen27b-benchmark-latest.json'
$statusPath='afz-openai-agent/results/h3-qwen27b-benchmark-status.json'
$requestPath='afz-openai-agent/requests/h3-qwen27b-benchmark.json'
$controlRepo='f3arif/faiz-homelab';$controlIssue=12;$alertIssue=7
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root|Out-Null

function Write-Json([string]$Path,$Object){[IO.File]::WriteAllText($Path,($Object|ConvertTo-Json -Depth 40 -Compress),$utf8)}
function Read-Json([string]$Path){if(-not(Test-Path $Path)){return $null};try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return $null}}
function Controller-Running{
  try{
    foreach($p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"){
      $cmd=[string]$p.CommandLine
      if($cmd -and $cmd.Contains('Run-H3-Qwen27B-WebsiteBenchmark.ps1') -and $cmd.Contains($ProjectRoot)){return $true}
    }
  }catch{}
  return $false
}
function Find-Gh{
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path $p){return $p}}
  return $null
}
function Quote-Arg([string]$v){if($null -eq $v){return '""'};if($v -notmatch '[\s"]'){return $v};return '"'+($v.Replace('"','\"'))+'"'}
function Invoke-Gh([string[]]$Args){
  $o=Join-Path $env:TEMP ('afz-gh-out-'+[guid]::NewGuid().ToString('N')+'.txt');$e=Join-Path $env:TEMP ('afz-gh-err-'+[guid]::NewGuid().ToString('N')+'.txt')
  try{
    $line=($Args|ForEach-Object {Quote-Arg ([string]$_)}) -join ' '
    $p=Start-Process -FilePath $script:gh -ArgumentList $line -RedirectStandardOutput $o -RedirectStandardError $e -Wait -PassThru -NoNewWindow
    $out=if(Test-Path $o){Get-Content $o -Raw}else{''};$err=if(Test-Path $e){Get-Content $e -Raw}else{''}
    [pscustomobject]@{ExitCode=[int]$p.ExitCode;Stdout=([string]$out).Trim();Stderr=([string]$err).Trim()}
  }finally{Remove-Item $o,$e -Force -ErrorAction SilentlyContinue}
}
function Get-PublicJson([string]$Url){$h=@{'User-Agent'='AFZ-H3-Return-V3';'Accept'='application/vnd.github+json';'Cache-Control'='no-cache'};Invoke-RestMethod -Uri $Url -Headers $h -TimeoutSec 30}
function Get-CanonicalRequest{
  $j=Get-PublicJson "https://api.github.com/repos/$Repo/contents/$requestPath`?ref=main"
  $raw=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((([string]$j.content)-replace '\s','')))
  $r=$raw|ConvertFrom-Json
  if([int]$r.schema -ne 1 -or [string]$r.project -ne 'qwen38-27b-website-benchmark'){throw 'Canonical request schema/project mismatch.'}
  $main=Get-PublicJson "https://api.github.com/repos/$Repo/commits/main"
  [pscustomobject]@{Request=$r;MainSha=[string]$main.sha}
}
function Find-ResultMarker{
  if(-not(Test-Path $root)){return $null}
  foreach($f in @(Get-ChildItem -LiteralPath $root -File -Filter '*.stdout.log' -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending)){
    $m=@(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue|Where-Object {$_.StartsWith('AFZ_RESULT_JSON=')}|Select-Object -Last 1)
    if($m.Count -gt 0){try{return [pscustomobject]@{Result=($m[0].Substring('AFZ_RESULT_JSON='.Length)|ConvertFrom-Json);Source=$f.FullName}}catch{}}
  }
  return $null
}
function Resolve-ReturnState{
  $canon=Get-CanonicalRequest;$req=$canon.Request;$job=[string]$req.job_id
  if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Canonical job id invalid.'}
  $local=Read-Json $stateFile
  if($local -and [string]$local.job_id -eq $job -and $local.result){$s=if([bool]$local.result.ok){'completed'}else{'failed'};return [pscustomobject]@{job_id=$job;status=$s;source_sha=$(if(([string]$local.source_sha)-match '^[0-9a-f]{40}$'){[string]$local.source_sha}else{$canon.MainSha});result=$local.result;error=$null;source='state.json'}}
  $marker=Find-ResultMarker
  if($marker){$s=if([bool]$marker.Result.ok){'completed'}else{'failed'};return [pscustomobject]@{job_id=$job;status=$s;source_sha=$canon.MainSha;result=$marker.Result;error=$null;source=('stdout:'+ $marker.Source)}}
  $controllerState=Read-Json (Join-Path $ProjectRoot 'AFZ-BENCHMARK-CONTROLLER\state.json')
  if($controllerState){foreach($name in @('result','finalResult','benchmarkResult')){if($controllerState.PSObject.Properties.Name -contains $name -and $controllerState.$name){$r=$controllerState.$name;$s=if([bool]$r.ok){'completed'}else{'failed'};return [pscustomobject]@{job_id=$job;status=$s;source_sha=$canon.MainSha;result=$r;error=$null;source=('controller-state:'+ $name)}}}}
  if(Controller-Running){return [pscustomobject]@{job_id=$job;status='running';source_sha=$(if($local -and ([string]$local.source_sha)-match '^[0-9a-f]{40}$'){[string]$local.source_sha}else{$canon.MainSha});result=$null;error=$null;source='controller-process'}}
  $err=$null;if($local -and $local.error){$err=[string]$local.error};if(-not $err){$err='No recoverable AFZ_RESULT_JSON payload is currently present. Return transport was repaired without rerunning Qwen.'}
  [pscustomobject]@{job_id=$job;status='blocked';source_sha=$(if($local -and ([string]$local.source_sha)-match '^[0-9a-f]{40}$'){[string]$local.source_sha}else{$canon.MainSha});result=$null;error=$err;source='recovered-blocked'}
}
function Get-RemoteSha([string]$Path){$r=Invoke-Gh @('api',"repos/$Repo/contents/$Path`?ref=$ResultBranch",'--jq','.sha');if($r.ExitCode -ne 0){return $null};$s=$r.Stdout.Trim();if($s -match '^[0-9a-f]{40}$'){return $s};return $null}
function Put-Json([string]$Path,$Object,[string]$Message){
  $json=$Object|ConvertTo-Json -Depth 40 -Compress;$payload=[ordered]@{message=$Message;content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json));branch=$ResultBranch};$sha=Get-RemoteSha $Path;if($sha){$payload.sha=$sha}
  $tmp=Join-Path $env:TEMP ('afz-return-put-'+[guid]::NewGuid().ToString('N')+'.json')
  try{[IO.File]::WriteAllText($tmp,($payload|ConvertTo-Json -Compress),$utf8);$r=Invoke-Gh @('api',"repos/$Repo/contents/$Path",'--method','PUT','--input',$tmp);if($r.ExitCode -ne 0){throw "GitHub Contents API PUT failed path=$Path exit=$($r.ExitCode): $($r.Stderr)"}}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
}
function Try-Comment([string]$RepoName,[int]$Issue,[string]$Body){$tmp=Join-Path $env:TEMP ('afz-return-comment-'+[guid]::NewGuid().ToString('N')+'.txt');try{[IO.File]::WriteAllText($tmp,$Body,$utf8);$r=Invoke-Gh @('issue','comment',[string]$Issue,'--repo',$RepoName,'--body-file',$tmp);return ($r.ExitCode -eq 0)}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}}

try{
  $resolved=Resolve-ReturnState
  $envelope=[ordered]@{schema=1;transport='h3-direct-return-v3';job_id=$resolved.job_id;status=$resolved.status;source_sha=$resolved.source_sha;worker='H3';host=$env:COMPUTERNAME;source=$resolved.source;result=$resolved.result;error=$resolved.error;recovered_at=(Get-Date -Format o)};Write-Json $returnEnvelope $envelope
  $gh=Find-Gh;if(-not $gh){throw 'GitHub CLI is not installed in the interactive H3 publisher context.'};$script:gh=$gh
  $perm=Invoke-Gh @('api',"repos/$Repo",'--jq','.permissions.push');if($perm.ExitCode -ne 0){throw ('GitHub API authentication unavailable in interactive H3 publisher context: '+$(if($perm.Stderr){$perm.Stderr}else{$perm.Stdout}))};if($perm.Stdout.Trim().ToLowerInvariant() -ne 'true'){throw 'H3 GitHub identity lacks repository push permission.'}
  $message=if($resolved.result){"Recovered benchmark result from $($resolved.source) without rerunning Qwen."}elseif($resolved.status -eq 'running'){'Existing benchmark controller is still running; return publisher attached without launching a duplicate.'}else{"Return path repaired; current recoverable state is BLOCKED: $($resolved.error)"}
  $statusDoc=[ordered]@{schema=1;transport='h3-direct-github';kind='status';job_id=$resolved.job_id;source_sha=$resolved.source_sha;worker='H3';host=$env:COMPUTERNAME;status=$resolved.status;message=$message;published_at=(Get-Date -Format o)};Put-Json $statusPath $statusDoc "H3 direct benchmark status $($resolved.status) $($resolved.job_id)"
  $resultPublished=$false;if($resolved.result){$resultDoc=[ordered]@{schema=1;transport='h3-direct-github';job_id=$resolved.job_id;source_sha=$resolved.source_sha;worker='H3';host=$env:COMPUTERNAME;result=$resolved.result;published_at=(Get-Date -Format o)};Put-Json $resultPath $resultDoc "H3 direct benchmark result $($resolved.job_id)";$resultPublished=$true}
  $comment="[H3-DIRECT RETURN V3] job=$($resolved.job_id); status=$($resolved.status); source=$($resolved.source); resultPublished=$resultPublished. Return-only recovery; Qwen was not rerun.";$c1=Try-Comment $controlRepo $controlIssue $comment;$c2=Try-Comment $Repo $alertIssue $comment
  Write-Json $publisherState ([ordered]@{schema=3;ok=$true;job_id=$resolved.job_id;status=$resolved.status;source=$resolved.source;branch_published=$true;result_published=$resultPublished;comments_ok=($c1 -and $c2);updated_at=(Get-Date -Format o)})
  Write-Output ('AFZ_H3_RETURN_V3='+(@{ok=$true;job_id=$resolved.job_id;status=$resolved.status;source=$resolved.source;result_published=$resultPublished}|ConvertTo-Json -Compress))
}catch{$msg=$_.Exception.Message;Write-Json $publisherState ([ordered]@{schema=3;ok=$false;error=$msg;updated_at=(Get-Date -Format o)});Write-Error $msg;exit 1}
