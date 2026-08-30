#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$SourceSha='main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$JobId='qwen35b-a3b-website-20260830-r1'
$Model='qwen3.6:35b-a3b'
$Context=16384
$ProjectRoot='C:\Projects\Qwen36-35B-A3B-Website-Test-20260830-r1'
$StateRoot='C:\ProgramData\AFZ\H3Qwen35BA3B'
$StateFile=Join-Path $StateRoot ($JobId+'.json')
$SharedRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results\h3'
$SharedState=Join-Path $SharedRoot ($JobId+'-state.json')
$SharedResult=Join-Path $SharedRoot ($JobId+'-result.json')
$TaskName='AFZ H3 Qwen35B A3B Benchmark'
$utf8=New-Object Text.UTF8Encoding($false)

function Write-Utf8([string]$Path,[string]$Text){
  $parent=Split-Path -Parent $Path
  if($parent -and -not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
  [IO.File]::WriteAllText($Path,$Text,$utf8)
}
function Write-Json([string]$Path,$Object){Write-Utf8 $Path ($Object|ConvertTo-Json -Depth 30 -Compress)}
function Save-State([string]$Status,[string]$Phase,[string]$Message,$Extra=$null){
  $o=[ordered]@{
    schema=1
    job_id=$JobId
    status=$Status
    phase=$Phase
    message=$Message
    host=$env:COMPUTERNAME
    model=$Model
    context=$Context
    no_think=$true
    max_model_calls=1
    qwen_only_website_author=$true
    human_written_website_code=0
    source_sha=$SourceSha
    project_root=$ProjectRoot
    updated_at=(Get-Date -Format o)
  }
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  Write-Json $StateFile $o
  if(Test-Path -LiteralPath $SharedRoot -PathType Container){try{Write-Json $SharedState $o}catch{}}
  return [pscustomobject]$o
}
function Read-State{
  if(-not(Test-Path -LiteralPath $StateFile -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}
}
function Get-FreePort{
  $l=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
  $l.Start();try{return ([Net.IPEndPoint]$l.LocalEndpoint).Port}finally{$l.Stop()}
}
function Run-Npm([string[]]$Arguments,[string]$Tag){
  $out=Join-Path $ProjectRoot ("AFZ-$Tag.stdout.log")
  $err=Join-Path $ProjectRoot ("AFZ-$Tag.stderr.log")
  $s=Get-Date
  $p=Start-Process -FilePath 'npm.cmd' -ArgumentList $Arguments -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -Wait -PassThru -NoNewWindow
  [pscustomobject]@{exit_code=[int]$p.ExitCode;seconds=[math]::Round(((Get-Date)-$s).TotalSeconds,2);stdout=$out;stderr=$err}
}
function Run-Smoke([string[]]$Routes){
  $port=Get-FreePort
  $out=Join-Path $ProjectRoot 'AFZ-server.stdout.log'
  $err=Join-Path $ProjectRoot 'AFZ-server.stderr.log'
  $server=$null
  try{
    $server=Start-Process -FilePath 'npm.cmd' -ArgumentList @('start','--','-p',[string]$port) -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
    $ready=$false
    for($i=0;$i -lt 60;$i++){
      Start-Sleep -Seconds 1
      try{$r=Invoke-WebRequest -Uri "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 3;if($r.StatusCode -eq 200){$ready=$true;break}}catch{}
      $server.Refresh();if($server.HasExited){break}
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
function Snapshot-Compute([string]$Prefix){
  try{(& ollama ps 2>&1|Out-String)|Set-Content -LiteralPath (Join-Path $ProjectRoot ($Prefix+'-ollama-ps.txt')) -Encoding UTF8}catch{}
  try{(& nvidia-smi 2>&1|Out-String)|Set-Content -LiteralPath (Join-Path $ProjectRoot ($Prefix+'-nvidia-smi.txt')) -Encoding UTF8}catch{}
}

if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only benchmark; host=$env:COMPUTERNAME"}
if($SourceSha -ne 'main' -and $SourceSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SourceSha must be main or an exact 40-character commit SHA.'}
New-Item -ItemType Directory -Force -Path $StateRoot|Out-Null

$prior=Read-State
if($prior){
  $attempted=$false
  if($prior.PSObject.Properties.Name -contains 'model_call_attempted'){$attempted=[bool]$prior.model_call_attempted}
  if($attempted -or [string]$prior.status -eq 'completed' -or [string]$prior.phase -in @('ollama_post_started','ollama_post_returned','qwen_response_received','files_applied','npm_install','build','smoke','completed')){
    Write-Output ('AFZ_QWEN35B_STATE='+($prior|ConvertTo-Json -Depth 30 -Compress))
    exit 0
  }
}

if(Test-Path -LiteralPath $ProjectRoot -PathType Container){
  $existing=@(Get-ChildItem -LiteralPath $ProjectRoot -Force -ErrorAction SilentlyContinue)
  if($existing.Count -gt 0){throw "Fresh benchmark project root is not empty: $ProjectRoot"}
}else{New-Item -ItemType Directory -Force -Path $ProjectRoot|Out-Null}

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
$promptFile=Join-Path $ProjectRoot 'AFZ-PROMPT.txt'
$requestFile=Join-Path $ProjectRoot 'AFZ-OLLAMA-REQUEST.json'
$responseFile=Join-Path $ProjectRoot 'AFZ-OLLAMA-RESPONSE.json'
$rawFile=Join-Path $ProjectRoot 'AFZ-QWEN-RAW.txt'
Write-Utf8 $promptFile $prompt
$promptHash=(Get-FileHash -LiteralPath $promptFile -Algorithm SHA256).Hash.ToLowerInvariant()

# Preflight is fail-closed: no model pull, no unload, and no benchmark start while another model is active.
$list=(& ollama list 2>&1|Out-String)
if($LASTEXITCODE -ne 0){$s=Save-State 'failed' 'preflight' 'ollama list failed.' ([pscustomobject]@{model_call_attempted=$false;prompt_sha256=$promptHash});Write-Output ('AFZ_QWEN35B_STATE='+($s|ConvertTo-Json -Depth 30 -Compress));exit 1}
$modelPresent=$false
foreach($line in ($list -split "`r?`n")){if($line -match '^qwen3\.6:35b-a3b\s'){$modelPresent=$true;break}}
if(-not $modelPresent){$s=Save-State 'blocked' 'preflight' 'Exact qwen3.6:35b-a3b model is not installed; no pull was attempted.' ([pscustomobject]@{model_call_attempted=$false;prompt_sha256=$promptHash});Write-Output ('AFZ_QWEN35B_STATE='+($s|ConvertTo-Json -Depth 30 -Compress));exit 2}
$active=(& ollama ps 2>&1|Out-String)
$activeRows=@(($active -split "`r?`n")|Where-Object {$_ -match '^\S+\s+[0-9a-f]{12,}'})
if($activeRows.Count -gt 0){$s=Save-State 'blocked' 'preflight' 'Another Ollama model is active; benchmark did not start.' ([pscustomobject]@{model_call_attempted=$false;prompt_sha256=$promptHash;ollama_ps=$active.Trim()});Write-Output ('AFZ_QWEN35B_STATE='+($s|ConvertTo-Json -Depth 30 -Compress));exit 3}

$routes=@('/','/services','/projects','/about','/contact')
$body=[ordered]@{model=$Model;prompt=$prompt;stream=$false;think=$false;options=[ordered]@{num_ctx=$Context;temperature=0.2;num_predict=11000}}
Write-Json $requestFile $body
Snapshot-Compute 'pre'
$s=Save-State 'running' 'pre_ollama' 'Preflight passed; exact prompt/request written. Ollama POST has not started yet.' ([pscustomobject]@{model_call_attempted=$false;prompt_sha256=$promptHash;request_file=$requestFile})

# A detached one-shot snapshot records actual residency/utilization after model load begins.
$telemetry=Join-Path $ProjectRoot 'AFZ-live-snapshot.ps1'
$telemetryText=@"
Start-Sleep -Seconds 30
try{(& ollama ps 2>&1|Out-String)|Set-Content -LiteralPath '$(Join-Path $ProjectRoot 'live-ollama-ps.txt')' -Encoding UTF8}catch{}
try{(& nvidia-smi 2>&1|Out-String)|Set-Content -LiteralPath '$(Join-Path $ProjectRoot 'live-nvidia-smi.txt')' -Encoding UTF8}catch{}
"@
Write-Utf8 $telemetry $telemetryText
Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$telemetry) -WindowStyle Hidden|Out-Null

$modelStart=Get-Date
$s=Save-State 'running' 'ollama_post_started' 'The one allowed Ollama model call is starting.' ([pscustomobject]@{model_call_attempted=$true;model_call_started_at=$modelStart.ToString('o');prompt_sha256=$promptHash})
& curl.exe -sS --max-time 10800 -H 'Content-Type: application/json' --data-binary "@$requestFile" -o "$responseFile" 'http://127.0.0.1:11434/api/generate'
$curlExit=$LASTEXITCODE
$modelEnd=Get-Date
$s=Save-State 'running' 'ollama_post_returned' 'Ollama POST returned.' ([pscustomobject]@{model_call_attempted=$true;model_call_started_at=$modelStart.ToString('o');model_call_returned_at=$modelEnd.ToString('o');curl_exit=$curlExit;wall_seconds=[math]::Round(($modelEnd-$modelStart).TotalSeconds,2);prompt_sha256=$promptHash})
if($curlExit -ne 0){$s=Save-State 'failed' 'ollama_post_returned' "Ollama transport failed with curl exit $curlExit" ([pscustomobject]@{model_call_attempted=$true;curl_exit=$curlExit;prompt_sha256=$promptHash});Write-Output ('AFZ_QWEN35B_STATE='+($s|ConvertTo-Json -Depth 30 -Compress));exit 4}

$response=(Get-Content -LiteralPath $responseFile -Raw -Encoding UTF8)|ConvertFrom-Json
if($response.error){throw "Ollama error: $($response.error)"}
if([string]::IsNullOrWhiteSpace([string]$response.response)){throw 'Qwen returned no response text.'}
Write-Utf8 $rawFile ([string]$response.response)
$s=Save-State 'running' 'qwen_response_received' 'Qwen response received; applying only exact FILE bundles.' ([pscustomobject]@{model_call_attempted=$true;prompt_sha256=$promptHash;prompt_eval_count=$response.prompt_eval_count;eval_count=$response.eval_count})

$pattern='(?ms)<<<FILE:\s*([^>\r\n]+?)\s*>>>\s*\r?\n(.*?)\r?\n?<<<END FILE>>>'
$matches=[regex]::Matches([string]$response.response,$pattern)
if($matches.Count -eq 0){throw 'Qwen returned no valid file bundles.'}
$allowed=@('.ts','.tsx','.js','.jsx','.mjs','.cjs','.json','.css','.md','.txt','.html','.svg','.xml','.yml','.yaml')
$rootFull=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')+'\'
$seen=@{}
$applied=@()
foreach($m in $matches){
  $rel=$m.Groups[1].Value.Trim().Replace('/','\')
  $content=$m.Groups[2].Value
  if([IO.Path]::IsPathRooted($rel) -or $rel -match '(^|\\)\.\.(\\|$)'){throw "Rejected Qwen path: $rel"}
  $ext=[IO.Path]::GetExtension($rel).ToLowerInvariant();if($ext -notin $allowed){throw "Unsupported extension from Qwen: $rel"}
  $key=$rel.ToLowerInvariant();if($seen.ContainsKey($key)){throw "Duplicate Qwen file bundle: $rel"};$seen[$key]=$true
  $dest=[IO.Path]::GetFullPath((Join-Path $ProjectRoot $rel));if(-not $dest.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)){throw "Qwen path escaped project root: $rel"}
  Write-Utf8 $dest $content
  $applied+=[pscustomobject]@{file=$rel;bytes=(Get-Item -LiteralPath $dest).Length}
}
if(-not(Test-Path -LiteralPath (Join-Path $ProjectRoot 'package.json') -PathType Leaf)){throw 'Qwen output did not include package.json.'}
$s=Save-State 'running' 'files_applied' 'Qwen-authored bundles applied; starting npm validation.' ([pscustomobject]@{model_call_attempted=$true;file_count=$applied.Count;files=$applied;prompt_sha256=$promptHash})

$install=Run-Npm @('install') 'npm-install'
$s=Save-State 'running' 'npm_install' 'npm install completed.' ([pscustomobject]@{model_call_attempted=$true;npm_install=$install;prompt_sha256=$promptHash})
$build=if($install.exit_code -eq 0){Run-Npm @('run','build') 'npm-build'}else{[pscustomobject]@{exit_code=$install.exit_code;seconds=0;stdout='';stderr=$install.stderr}}
$s=Save-State 'running' 'build' 'Build validation completed.' ([pscustomobject]@{model_call_attempted=$true;npm_install=$install;build=$build;prompt_sha256=$promptHash})
$smoke=$null
if($build.exit_code -eq 0){$smoke=Run-Smoke $routes}else{$smoke=[pscustomobject]@{ready=$false;passed=0;total=$routes.Count;pass=$false;results=@();port=$null}}
Snapshot-Compute 'post'

$promptTps=$null;if($response.prompt_eval_count -and $response.prompt_eval_duration -gt 0){$promptTps=[math]::Round([double]$response.prompt_eval_count/([double]$response.prompt_eval_duration/1e9),2)}
$genTps=$null;if($response.eval_count -and $response.eval_duration -gt 0){$genTps=[math]::Round([double]$response.eval_count/([double]$response.eval_duration/1e9),2)}
$result=[ordered]@{
  schema=1
  job_id=$JobId
  status='completed'
  host=$env:COMPUTERNAME
  task=$TaskName
  model=$Model
  context=$Context
  no_think=$true
  max_model_calls=1
  model_calls_used=1
  qwen_only_website_author=$true
  human_written_website_code=0
  source_sha=$SourceSha
  project_root=$ProjectRoot
  prompt_sha256=$promptHash
  prompt_eval_count=$response.prompt_eval_count
  prompt_eval_seconds=$(if($response.prompt_eval_duration){[math]::Round([double]$response.prompt_eval_duration/1e9,2)}else{$null})
  prompt_tokens_per_second=$promptTps
  eval_count=$response.eval_count
  eval_seconds=$(if($response.eval_duration){[math]::Round([double]$response.eval_duration/1e9,2)}else{$null})
  generation_tokens_per_second=$genTps
  ollama_total_seconds=$(if($response.total_duration){[math]::Round([double]$response.total_duration/1e9,2)}else{$null})
  wall_seconds=[math]::Round(($modelEnd-$modelStart).TotalSeconds,2)
  files=$applied
  npm_install=$install
  build=$build
  smoke=$smoke
  pass=($install.exit_code -eq 0 -and $build.exit_code -eq 0 -and [bool]$smoke.pass)
  completed_at=(Get-Date -Format o)
}
Write-Json (Join-Path $ProjectRoot 'AFZ-BENCHMARK-RESULT.json') $result
if(Test-Path -LiteralPath $SharedRoot -PathType Container){try{Write-Json $SharedResult $result}catch{}}
$s=Save-State 'completed' 'completed' '35B-A3B website benchmark completed.' ([pscustomobject]@{model_call_attempted=$true;pass=[bool]$result.pass;result_file=(Join-Path $ProjectRoot 'AFZ-BENCHMARK-RESULT.json');shared_result=$SharedResult;generation_tokens_per_second=$genTps;eval_count=$response.eval_count;prompt_sha256=$promptHash})
Write-Output ('AFZ_QWEN35B_RESULT='+($result|ConvertTo-Json -Depth 30 -Compress))
