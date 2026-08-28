#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$SourceSha='main',
  [string]$RequestPath='afz-openai-agent/requests/h3-qwenridge16k-website-test.json'
)

$ErrorActionPreference='Stop'
$repo='f3arif/homelab-control'
$controlRepo='f3arif/faiz-homelab'
$controlIssue=12
$alertIssue=7
$resultBranch='h3-direct-results'
$resultPath='afz-openai-agent/results/h3-qwenridge16k-website-test-latest.json'
$utf8=New-Object Text.UTF8Encoding($false)

function Find-Gh {
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path $p){return $p}}
  return $null
}
function Invoke-Gh([string[]]$Arguments,[switch]$AllowFailure){
  $old=$ErrorActionPreference
  try{$ErrorActionPreference='Continue';$out=@(& $script:gh @Arguments 2>$null);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
  if(-not $AllowFailure -and $code -ne 0){throw "gh failed exit=$code args=$($Arguments -join ' ')"}
  [pscustomobject]@{ExitCode=$code;Output=$out}
}
function Comment([string]$Repo,[int]$Issue,[string]$Body){
  $r=Invoke-Gh -Arguments @('issue','comment',[string]$Issue,'--repo',$Repo,'--body',$Body) -AllowFailure
  return ($r.ExitCode -eq 0)
}
function Get-ContentAt([string]$Path,[string]$Ref){
  $r=Invoke-Gh -Arguments @('api',"repos/$repo/contents/$Path?ref=$Ref")
  $j=($r.Output -join "`n")|ConvertFrom-Json
  if([string]$j.encoding -ne 'base64' -or [string]::IsNullOrWhiteSpace([string]$j.content)){throw "Invalid GitHub content response for $Path@$Ref"}
  $b64=([string]$j.content)-replace '\s',''
  return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}
function Write-Utf8([string]$Path,[string]$Text){
  $parent=Split-Path -Parent $Path
  if($parent -and -not(Test-Path $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
  [IO.File]::WriteAllText($Path,$Text,$utf8)
}
function Write-Json([string]$Path,$Object){Write-Utf8 $Path ($Object|ConvertTo-Json -Depth 30 -Compress)}
function Ns-To-Sec($Value){if($null -eq $Value){return $null};[math]::Round(([double]$Value/1e9),2)}
function Publish-Json([string]$Path,$Object,[string]$Message){
  $json=$Object|ConvertTo-Json -Depth 30 -Compress
  $payload=[ordered]@{message=$Message;content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json));branch=$resultBranch}
  $existing=Invoke-Gh -Arguments @('api',"repos/$repo/contents/$Path?ref=$resultBranch",'--jq','.sha') -AllowFailure
  if($existing.ExitCode -eq 0){$sha=([string]($existing.Output -join '')).Trim();if($sha -match '^[0-9a-f]{40}$'){$payload.sha=$sha}}
  $tmp=Join-Path $env:TEMP ('afz-qwenridge-publish-'+[guid]::NewGuid().ToString('N')+'.json')
  try{
    Write-Utf8 $tmp ($payload|ConvertTo-Json -Depth 8 -Compress)
    $put=Invoke-Gh -Arguments @('api','--method','PUT',"repos/$repo/contents/$Path",'--input',$tmp) -AllowFailure
    return ($put.ExitCode -eq 0)
  }finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
}
function Get-FreePort {
  $l=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
  $l.Start();try{return ([Net.IPEndPoint]$l.LocalEndpoint).Port}finally{$l.Stop()}
}
function Run-Npm([string[]]$Arguments,[string]$Tag,[string]$ProjectRoot){
  $out=Join-Path $ProjectRoot ("AFZ-$Tag.stdout.log")
  $err=Join-Path $ProjectRoot ("AFZ-$Tag.stderr.log")
  $s=Get-Date
  $p=Start-Process -FilePath 'npm.cmd' -ArgumentList $Arguments -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -Wait -PassThru -NoNewWindow
  [pscustomobject]@{exitCode=$p.ExitCode;seconds=[math]::Round(((Get-Date)-$s).TotalSeconds,2);stdout=$out;stderr=$err}
}
function Run-Smoke([string]$ProjectRoot,[string[]]$Routes){
  $port=Get-FreePort
  $out=Join-Path $ProjectRoot 'AFZ-server.stdout.log'
  $err=Join-Path $ProjectRoot 'AFZ-server.stderr.log'
  $server=$null
  try{
    $server=Start-Process -FilePath 'npm.cmd' -ArgumentList @('start','--','-p',[string]$port) -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
    $ready=$false
    for($i=0;$i -lt 40;$i++){
      Start-Sleep -Seconds 1
      try{$r=Invoke-WebRequest -Uri "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 3;if($r.StatusCode -eq 200){$ready=$true;break}}catch{}
      if($server.HasExited){break}
    }
    $rows=@()
    foreach($route in $Routes){
      try{$r=Invoke-WebRequest -Uri "http://127.0.0.1:$port$route" -UseBasicParsing -TimeoutSec 10;$rows+=[pscustomobject]@{route=$route;http=[int]$r.StatusCode;bytes=[int]$r.Content.Length;pass=([int]$r.StatusCode -eq 200)}}
      catch{$code=0;try{if($_.Exception.Response){$code=[int]$_.Exception.Response.StatusCode}}catch{};$rows+=[pscustomobject]@{route=$route;http=$code;bytes=0;pass=$false}}
    }
    $passed=@($rows|Where-Object {$_.pass}).Count
    [pscustomobject]@{ready=$ready;passed=$passed;total=$Routes.Count;pass=($ready -and $passed -eq $Routes.Count);results=$rows;port=$port}
  }finally{if($server){try{& taskkill.exe /PID $server.Id /T /F *> $null}catch{}}}
}

if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only test; host=$env:COMPUTERNAME"}
$script:gh=Find-Gh
if(-not $gh){throw 'GitHub CLI not found on H3.'}
$auth=Invoke-Gh -Arguments @('auth','status','--hostname','github.com') -AllowFailure
if($auth.ExitCode -ne 0){throw 'GitHub CLI authentication is not valid on H3.'}

if($SourceSha -eq 'main'){
  $main=Invoke-Gh -Arguments @('api',"repos/$repo/commits/main",'--jq','.sha')
  $SourceSha=([string]($main.Output -join '')).Trim()
}
if($SourceSha -notmatch '^[0-9a-f]{40}$'){throw "Invalid SourceSha: $SourceSha"}

$req=(Get-ContentAt $RequestPath $SourceSha)|ConvertFrom-Json
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'qwen38-ridge16k-website-direct-test'){throw 'Typed request schema/project mismatch.'}
$job=[string]$req.job_id
$model=[string]$req.model
$context=[int]$req.context
$projectRoot=[string]$req.project_root
$routes=@($req.required_routes|ForEach-Object {[string]$_})
if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid job id.'}
if($model -ne 'qwen3.8-ridge:27b-16k'){throw "Unexpected model: $model"}
if($context -ne 16384){throw "Unexpected context: $context"}
if(-not [bool]$req.no_think){throw 'no_think must be true.'}
if([int]$req.max_model_calls -ne 1){throw 'This test is intentionally one model call.'}
if($routes.Count -ne 5){throw 'Expected five routes.'}

$stateRoot='C:\ProgramData\AFZ\H3QwenRidge16K'
$stateFile=Join-Path $stateRoot ($job+'.json')
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
if(Test-Path $stateFile){
  try{$prior=Get-Content $stateFile -Raw|ConvertFrom-Json;if([string]$prior.status -in @('running','completed')){Write-Output ('AFZ_QWENRIDGE_STATE='+($prior|ConvertTo-Json -Depth 20 -Compress));exit 0}}catch{}
}
if(Test-Path $projectRoot){
  $existing=@(Get-ChildItem -LiteralPath $projectRoot -Force -ErrorAction SilentlyContinue)
  if($existing.Count -gt 0){throw "Project root already contains files: $projectRoot"}
}else{New-Item -ItemType Directory -Force -Path $projectRoot|Out-Null}

$started=Get-Date
$state=[ordered]@{schema=1;job_id=$job;status='running';source_sha=$SourceSha;worker='H3';host=$env:COMPUTERNAME;model=$model;context=$context;no_think=$true;project_root=$projectRoot;started_at=$started.ToString('o')}
Write-Json $stateFile $state
[void](Comment $controlRepo $controlIssue "[STATUS][H3-RIDGE16K] Job $job started directly on H3. model=$model context=$context no_think=true source=$SourceSha. One model call; Qwen is the only website code author.")

$prompt=@'
/no_think

Build a complete runnable Next.js + React + TypeScript App Router website for AFZ Engineering Inc., an Ontario mechanical engineering consultancy.

IMPORTANT:
Do not reason aloud. Do not explain your plan. Immediately output project files. You are the ONLY website code author.

Required routes:
/
/services
/projects
/about
/contact

Requirements:
- professional, modern, restrained mechanical-engineering design
- responsive desktop/tablet/mobile layout
- working desktop and mobile navigation
- HVAC, heat loss/heat gain, duct design, ventilation, commercial mechanical, kitchen exhaust/make-up air, plumbing, hydronic, gas piping and mechanical permit services
- Ontario engineering context; may reference Ontario Building Code, ASHRAE, CSA B149, NFPA 96 and HRAI principles without implying affiliation
- representative project types only; do not invent actual projects, clients, awards, statistics, staff biographies, street addresses or years in business
- About page with mission, engineering philosophy and typical clients
- Contact page with project inquiry form: Name, Company, Email, Phone, Project Address, Project Type, Service Required, Project Description
- reusable Header, MobileNav, Footer, CTA and card components where useful
- accessible semantic HTML, labels, focus states and useful metadata
- minimal dependencies
- npm install, npm run build and npm start must work
- keep implementation compact enough for the available context

Before answering, mentally validate imports, TypeScript, App Router structure, client/server components and all five routes.

Output EVERY required project file exactly as:
<<<FILE: relative/path/file.ext>>>
complete file contents
<<<END FILE>>>

No Markdown code fences. No planning. No explanations. No commentary. No partial snippets. No "same as above". Do not omit required files.

BEGIN WITH package.json AND GENERATE THE COMPLETE PROJECT NOW.
'@
$promptFile=Join-Path $projectRoot 'AFZ-PROMPT.txt'
$requestFile=Join-Path $projectRoot 'AFZ-OLLAMA-REQUEST.json'
$responseFile=Join-Path $projectRoot 'AFZ-OLLAMA-RESPONSE.json'
$rawFile=Join-Path $projectRoot 'AFZ-QWEN-RAW.txt'
Write-Utf8 $promptFile $prompt

$ollamaList=(& ollama list 2>&1|Out-String)
if($LASTEXITCODE -ne 0 -or $ollamaList -notmatch [regex]::Escape($model)){throw "Required Ollama model not available: $model"}

$body=[ordered]@{model=$model;prompt=$prompt;stream=$false;think=$false;options=[ordered]@{num_ctx=$context;temperature=0.2;num_predict=11000}}
Write-Json $requestFile $body
$modelStart=Get-Date
& curl.exe -sS --max-time 10800 -H 'Content-Type: application/json' --data-binary "@$requestFile" -o "$responseFile" 'http://127.0.0.1:11434/api/generate'
$curlExit=$LASTEXITCODE
$modelEnd=Get-Date
if($curlExit -ne 0){throw "Ollama transport failed with curl exit $curlExit"}
$response=(Get-Content $responseFile -Raw)|ConvertFrom-Json
if($response.error){throw "Ollama error: $($response.error)"}
if([string]::IsNullOrWhiteSpace([string]$response.response)){throw 'Qwen returned no response text.'}
Write-Utf8 $rawFile ([string]$response.response)

$tps=$null
if($response.eval_count -and $response.eval_duration -gt 0){$tps=[math]::Round($response.eval_count/($response.eval_duration/1e9),2)}
$promptTps=$null
if($response.prompt_eval_count -and $response.prompt_eval_duration -gt 0){$promptTps=[math]::Round($response.prompt_eval_count/($response.prompt_eval_duration/1e9),2)}

$pattern='(?ms)<<<FILE:\s*([^>\r\n]+?)\s*>>>\s*\r?\n(.*?)\r?\n?<<<END FILE>>>'
$matches=[regex]::Matches([string]$response.response,$pattern)
if($matches.Count -eq 0){throw 'Qwen returned no valid file bundles.'}
$allowed=@('.ts','.tsx','.js','.jsx','.mjs','.cjs','.json','.css','.md','.txt','.html','.svg','.xml','.yml','.yaml')
$rootFull=[IO.Path]::GetFullPath($projectRoot).TrimEnd('\')+'\'
$seen=@{}
$applied=@()
foreach($m in $matches){
  $rel=$m.Groups[1].Value.Trim().Replace('/','\')
  $content=$m.Groups[2].Value
  if([IO.Path]::IsPathRooted($rel) -or $rel -match '(^|\\)\.\.(\\|$)'){throw "Rejected Qwen path: $rel"}
  $ext=[IO.Path]::GetExtension($rel).ToLowerInvariant();if($ext -notin $allowed){throw "Unsupported extension from Qwen: $rel"}
  $key=$rel.ToLowerInvariant();if($seen.ContainsKey($key)){throw "Duplicate Qwen file bundle: $rel"};$seen[$key]=$true
  $dest=[IO.Path]::GetFullPath((Join-Path $projectRoot $rel));if(-not $dest.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)){throw "Qwen path escaped project root: $rel"}
  Write-Utf8 $dest $content
  $applied+=[pscustomobject]@{file=$rel;bytes=(Get-Item $dest).Length}
}
if(-not(Test-Path (Join-Path $projectRoot 'package.json'))){throw 'Qwen output did not include package.json.'}

$install=Run-Npm @('install') 'npm-install' $projectRoot
$build=if($install.exitCode -eq 0){Run-Npm @('run','build') 'npm-build' $projectRoot}else{[pscustomobject]@{exitCode=$install.exitCode;seconds=0;stdout='';stderr=$install.stderr}}
$smoke=$null
if($build.exitCode -eq 0){$smoke=Run-Smoke $projectRoot $routes}

$processor=''
try{$processor=(& ollama ps 2>&1|Out-String).Trim()}catch{}
$zip=Join-Path $projectRoot 'Qwen38-Ridge16K-Website-Test.zip'
try{
  $zipItems=@('app','components','lib','public','package.json','package-lock.json','tsconfig.json','next.config.mjs','next.config.ts','tailwind.config.ts','postcss.config.js')|ForEach-Object {Join-Path $projectRoot $_}|Where-Object {Test-Path $_}
  if($zipItems.Count -gt 0){Compress-Archive -Path $zipItems -DestinationPath $zip -Force}
}catch{}

$success=($install.exitCode -eq 0 -and $build.exitCode -eq 0 -and $smoke -and $smoke.pass)
$result=[ordered]@{
  schema=1;project='qwen38-ridge16k-website-direct-test';job_id=$job;status=$(if($success){'PASS'}else{'FAIL'});source_sha=$SourceSha;worker='H3';host=$env:COMPUTERNAME;model=$model;context=$context;no_think=$true;human_written_website_code=0;model_calls=1;project_root=$projectRoot;
  model_wall_seconds=[math]::Round(($modelEnd-$modelStart).TotalSeconds,2);ollama_total_seconds=Ns-To-Sec $response.total_duration;load_seconds=Ns-To-Sec $response.load_duration;prompt_tokens=$response.prompt_eval_count;prompt_tokens_per_second=$promptTps;output_tokens=$response.eval_count;output_tokens_per_second=$tps;done=$response.done;done_reason=$response.done_reason;
  files_generated=$applied.Count;files=$applied;install_exit=$install.exitCode;install_seconds=$install.seconds;build_exit=$build.exitCode;build_seconds=$build.seconds;routes_passing=$(if($smoke){$smoke.passed}else{0});routes_total=$routes.Count;routes=$(if($smoke){$smoke.results}else{@()});ollama_ps=$processor;zip=$(if(Test-Path $zip){$zip}else{$null});completed_at=(Get-Date -Format o)
}
Write-Json (Join-Path $projectRoot 'AFZ-BENCHMARK-RESULT.json') $result
Write-Json $stateFile ([ordered]@{schema=1;job_id=$job;status=$(if($success){'completed'}else{'failed'});result=$result;updated_at=(Get-Date -Format o)})
$published=Publish-Json $resultPath $result "H3 Ridge16K website test result $job"
[void](Comment $controlRepo $controlIssue "[RESULT][H3-RIDGE16K] Job $job status=$($result.status) model=$model context=$context no_think=true output_tokens=$($result.output_tokens) output_tps=$($result.output_tokens_per_second) model_wall_s=$($result.model_wall_seconds) files=$($result.files_generated) build_exit=$($result.build_exit) routes=$($result.routes_passing)/$($result.routes_total) human_written_website_code=0 result_branch_push=$published")
[void](Comment $repo $alertIssue "[H3-RIDGE16K RESULT] @f3arif job=$job status=$($result.status) output_tps=$($result.output_tokens_per_second) wall_s=$($result.model_wall_seconds) files=$($result.files_generated) build_exit=$($result.build_exit) routes=$($result.routes_passing)/$($result.routes_total)")
Write-Output ('AFZ_RESULT_JSON='+($result|ConvertTo-Json -Depth 30 -Compress))
if($success){exit 0}else{exit 2}
