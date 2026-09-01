#Requires -Version 5.1
[CmdletBinding()]
param([string]$SourceSha='main')

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$JobId='qwen35b-a3b-website-20260830-r1-repair01'
$OriginalJobId='qwen35b-a3b-website-20260830-r1'
$Model='qwen3.6:35b-a3b'
$Context=16384
$OriginalRoot='C:\Projects\Qwen36-35B-A3B-Website-Test-20260830-r1'
$RepairRoot='C:\Projects\Qwen36-35B-A3B-Website-Test-20260830-r1-repair01'
$StateRoot='C:\ProgramData\AFZ\H3Qwen35BA3BRepair'
$StateFile=Join-Path $StateRoot ($JobId+'.json')
$SharedRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results\h3'
$SharedState=Join-Path $SharedRoot ($JobId+'-state.json')
$SharedResult=Join-Path $SharedRoot ($JobId+'-result.json')
$utf8=New-Object Text.UTF8Encoding($false)

function Write-Utf8([string]$Path,[string]$Text){
  $parent=Split-Path -Parent $Path
  if($parent -and -not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
  [IO.File]::WriteAllText($Path,$Text,$utf8)
}
function Write-Json([string]$Path,$Object){Write-Utf8 $Path ($Object|ConvertTo-Json -Depth 40 -Compress)}
function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}}
function Save-State([string]$Status,[string]$Phase,[string]$Message,$Extra=$null){
  $o=[ordered]@{
    schema=1;job_id=$JobId;original_job_id=$OriginalJobId;status=$Status;phase=$Phase;message=$Message
    host=$env:COMPUTERNAME;model=$Model;context=$Context;no_think=$true;max_repair_model_calls=1
    repair_model_call_attempted=$false;qwen_only_website_author=$true;human_written_website_code=0
    original_root=$OriginalRoot;repair_root=$RepairRoot;source_sha=$SourceSha;updated_at=(Get-Date -Format o)
  }
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  Write-Json $StateFile $o
  try{if(Test-Path -LiteralPath $SharedRoot -PathType Container){Write-Json $SharedState $o}}catch{}
  [pscustomobject]$o
}
function Get-FreePort{
  $l=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$l.Start();try{return ([Net.IPEndPoint]$l.LocalEndpoint).Port}finally{$l.Stop()}
}
function Run-Npm([string[]]$Arguments,[string]$Tag){
  $out=Join-Path $RepairRoot ("AFZ-$Tag.stdout.log");$err=Join-Path $RepairRoot ("AFZ-$Tag.stderr.log");$s=Get-Date
  $p=Start-Process -FilePath 'npm.cmd' -ArgumentList $Arguments -WorkingDirectory $RepairRoot -RedirectStandardOutput $out -RedirectStandardError $err -Wait -PassThru -NoNewWindow
  [pscustomobject]@{exit_code=[int]$p.ExitCode;seconds=[math]::Round(((Get-Date)-$s).TotalSeconds,2);stdout=$out;stderr=$err}
}
function Run-Smoke([string[]]$Routes){
  $port=Get-FreePort;$out=Join-Path $RepairRoot 'AFZ-server.stdout.log';$err=Join-Path $RepairRoot 'AFZ-server.stderr.log';$server=$null
  try{
    $server=Start-Process -FilePath 'npm.cmd' -ArgumentList @('start','--','-p',[string]$port) -WorkingDirectory $RepairRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
    $ready=$false
    for($i=0;$i -lt 60;$i++){Start-Sleep -Seconds 1;try{$r=Invoke-WebRequest -Uri "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 3;if($r.StatusCode -eq 200){$ready=$true;break}}catch{};$server.Refresh();if($server.HasExited){break}}
    $rows=@();foreach($route in $Routes){try{$r=Invoke-WebRequest -Uri "http://127.0.0.1:$port$route" -UseBasicParsing -TimeoutSec 10;$rows+=[pscustomobject]@{route=$route;http=[int]$r.StatusCode;bytes=[int]$r.Content.Length;pass=([int]$r.StatusCode -eq 200)}}catch{$code=0;try{if($_.Exception.Response){$code=[int]$_.Exception.Response.StatusCode}}catch{};$rows+=[pscustomobject]@{route=$route;http=$code;bytes=0;pass=$false}}}
    $passed=@($rows|Where-Object {$_.pass}).Count;[pscustomobject]@{ready=$ready;passed=$passed;total=$Routes.Count;pass=($ready -and $passed -eq $Routes.Count);results=$rows;port=$port}
  }finally{if($server){try{& taskkill.exe /PID $server.Id /T /F *> $null}catch{}}}
}
function Tail([string]$Path,[int]$Count=50){if(Test-Path -LiteralPath $Path -PathType Leaf){return ((Get-Content -LiteralPath $Path -Tail $Count -ErrorAction SilentlyContinue)-join "`n")};return ''}

if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only repair; host=$env:COMPUTERNAME"}
if($SourceSha -ne 'main' -and $SourceSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SourceSha must be main or an exact commit SHA.'}
New-Item -ItemType Directory -Force -Path $StateRoot|Out-Null

$prior=Read-Json $StateFile
if($prior){
  $attempted=$false;if($prior.PSObject.Properties.Name -contains 'repair_model_call_attempted'){$attempted=[bool]$prior.repair_model_call_attempted}
  if($attempted -or [string]$prior.status -eq 'completed' -or [string]$prior.phase -in @('repair_ollama_post_started','repair_ollama_post_returned','repair_response_received','files_applied','npm_install','build','smoke','completed')){
    Write-Output ('AFZ_QWEN35B_REPAIR_STATE='+($prior|ConvertTo-Json -Depth 40 -Compress));exit 0
  }
}

$originalResultPath=Join-Path $OriginalRoot 'AFZ-BENCHMARK-RESULT.json'
$originalResponsePath=Join-Path $OriginalRoot 'AFZ-OLLAMA-RESPONSE.json'
$originalBuildErr=Join-Path $OriginalRoot 'AFZ-npm-build.stderr.log'
if(-not(Test-Path -LiteralPath $originalResultPath -PathType Leaf)){throw "Original benchmark result missing: $originalResultPath"}
if(-not(Test-Path -LiteralPath $originalResponsePath -PathType Leaf)){throw "Original saved model response missing: $originalResponsePath"}
$original=Get-Content -LiteralPath $originalResultPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
if([string]$original.job_id -ne $OriginalJobId -or [string]$original.model -ne $Model -or [int]$original.model_calls_used -ne 1){throw 'Original benchmark identity/model-call proof mismatch.'}
if([bool]$original.pass){throw 'Original benchmark already passed; repair call refused.'}

if(Test-Path -LiteralPath $RepairRoot -PathType Container){
  $existing=@(Get-ChildItem -LiteralPath $RepairRoot -Force -ErrorAction SilentlyContinue)
  if($existing.Count -gt 0){throw "Fresh repair root is not empty and no repair-call state exists: $RepairRoot"}
}else{New-Item -ItemType Directory -Force -Path $RepairRoot|Out-Null}

$sourceFiles=@()
foreach($f in @($original.files)){
  $rel=[string]$f.file
  if([string]::IsNullOrWhiteSpace($rel)){continue}
  if([IO.Path]::IsPathRooted($rel) -or $rel -match '(^|\\)\.\.(\\|$)'){throw "Unsafe original file path: $rel"}
  $src=[IO.Path]::GetFullPath((Join-Path $OriginalRoot $rel));$dst=[IO.Path]::GetFullPath((Join-Path $RepairRoot $rel))
  $rootFull=[IO.Path]::GetFullPath($OriginalRoot).TrimEnd('\')+'\';$repairFull=[IO.Path]::GetFullPath($RepairRoot).TrimEnd('\')+'\'
  if(-not $src.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase) -or -not $dst.StartsWith($repairFull,[StringComparison]::OrdinalIgnoreCase)){throw "Path escaped project root: $rel"}
  if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "Original Qwen file missing: $rel"}
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst)|Out-Null;Copy-Item -LiteralPath $src -Destination $dst -Force
  $sourceFiles+=$rel
}
if($sourceFiles.Count -eq 0){throw 'No original Qwen files available for repair.'}

$buildError=Tail $originalBuildErr 80
$parts=New-Object Collections.Generic.List[string]
$parts.Add(@'
/no_think

You are the ONLY website code author. Repair the existing AFZ Engineering Next.js project from the prior qwen3.6:35b-a3b generation.

This is a repair iteration, not a rewrite. Preserve the existing design, content and required routes. Diagnose the supplied build error and all dependency/config consistency issues directly related to it. Make the minimum complete repair needed for npm install, npm run build and npm start to work.

RULES:
- Do not reason aloud or explain.
- Output ONLY changed or new project files.
- Every changed file must be complete, not a patch or snippet.
- Do not alter files unnecessarily.
- Do not remove required routes or features.
- Use exactly this format for each changed/new file:
<<<FILE: relative/path/file.ext>>>
complete file contents
<<<END FILE>>>
- No Markdown code fences. No commentary. No "same as above".
'@)
$parts.Add("`nCURRENT BUILD ERROR:`n$buildError`n")
foreach($rel in $sourceFiles){
  $content=Get-Content -LiteralPath (Join-Path $OriginalRoot $rel) -Raw -Encoding UTF8
  $parts.Add("`n<<<EXISTING_FILE: $($rel.Replace('\\','/'))>>>`n$content`n<<<END EXISTING_FILE>>>`n")
}
$parts.Add("`nREPAIR THE PROJECT NOW. OUTPUT ONLY THE FILES THAT MUST CHANGE.`n")
$prompt=$parts -join ''
$promptFile=Join-Path $RepairRoot 'AFZ-REPAIR-PROMPT.txt';$requestFile=Join-Path $RepairRoot 'AFZ-REPAIR-OLLAMA-REQUEST.json';$responseFile=Join-Path $RepairRoot 'AFZ-REPAIR-OLLAMA-RESPONSE.json';$rawFile=Join-Path $RepairRoot 'AFZ-REPAIR-QWEN-RAW.txt'
Write-Utf8 $promptFile $prompt;$promptHash=(Get-FileHash -LiteralPath $promptFile -Algorithm SHA256).Hash.ToLowerInvariant()

$list=(& ollama list 2>&1|Out-String);if($LASTEXITCODE -ne 0){$s=Save-State 'failed' 'preflight' 'ollama list failed.' ([pscustomobject]@{repair_model_call_attempted=$false;prompt_sha256=$promptHash});Write-Output ('AFZ_QWEN35B_REPAIR_STATE='+($s|ConvertTo-Json -Depth 40 -Compress));exit 1}
$modelPresent=$false;foreach($line in ($list -split "`r?`n")){if($line -match '^qwen3\.6:35b-a3b\s'){$modelPresent=$true;break}}
if(-not $modelPresent){$s=Save-State 'blocked' 'preflight' 'Exact repair model is not installed; no pull attempted.' ([pscustomobject]@{repair_model_call_attempted=$false;prompt_sha256=$promptHash});Write-Output ('AFZ_QWEN35B_REPAIR_STATE='+($s|ConvertTo-Json -Depth 40 -Compress));exit 2}
$active=(& ollama ps 2>&1|Out-String);$activeRows=@(($active -split "`r?`n")|Where-Object {$_ -match '^\S+\s+[0-9a-f]{12,}'})
if($activeRows.Count -gt 0){$s=Save-State 'blocked' 'preflight' 'Another Ollama model is active; repair did not start.' ([pscustomobject]@{repair_model_call_attempted=$false;ollama_ps=$active.Trim();prompt_sha256=$promptHash});Write-Output ('AFZ_QWEN35B_REPAIR_STATE='+($s|ConvertTo-Json -Depth 40 -Compress));exit 3}

$body=[ordered]@{model=$Model;prompt=$prompt;stream=$false;think=$false;options=[ordered]@{num_ctx=$Context;temperature=0.1;num_predict=4096}}
Write-Json $requestFile $body
$s=Save-State 'running' 'pre_repair_ollama' 'Repair prompt prepared; no repair model call started yet.' ([pscustomobject]@{repair_model_call_attempted=$false;prompt_sha256=$promptHash;source_file_count=$sourceFiles.Count})
$start=Get-Date
$s=Save-State 'running' 'repair_ollama_post_started' 'The one allowed Qwen repair call is starting.' ([pscustomobject]@{repair_model_call_attempted=$true;repair_model_calls_used=1;repair_model_call_started_at=$start.ToString('o');prompt_sha256=$promptHash})
& curl.exe -sS --max-time 3600 -H 'Content-Type: application/json' --data-binary "@$requestFile" -o "$responseFile" 'http://127.0.0.1:11434/api/generate'
$curlExit=$LASTEXITCODE;$end=Get-Date
$s=Save-State 'running' 'repair_ollama_post_returned' 'Repair Ollama POST returned.' ([pscustomobject]@{repair_model_call_attempted=$true;repair_model_calls_used=1;curl_exit=$curlExit;wall_seconds=[math]::Round(($end-$start).TotalSeconds,2);repair_model_call_started_at=$start.ToString('o');repair_model_call_returned_at=$end.ToString('o');prompt_sha256=$promptHash})
if($curlExit -ne 0){$s=Save-State 'failed' 'repair_ollama_post_returned' "Repair Ollama transport failed with curl exit $curlExit" ([pscustomobject]@{repair_model_call_attempted=$true;repair_model_calls_used=1;curl_exit=$curlExit});Write-Output ('AFZ_QWEN35B_REPAIR_STATE='+($s|ConvertTo-Json -Depth 40 -Compress));exit 4}

$response=Get-Content -LiteralPath $responseFile -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
if($response.error){throw "Ollama repair error: $($response.error)"};if([string]::IsNullOrWhiteSpace([string]$response.response)){throw 'Qwen repair returned no response.'}
Write-Utf8 $rawFile ([string]$response.response)
$pattern='(?ms)<<<FILE:\s*([^>\r\n]+?)\s*>>>\s*\r?\n(.*?)\r?\n?<<<END FILE>>>';$matches=[regex]::Matches([string]$response.response,$pattern)
if($matches.Count -eq 0){throw 'Qwen repair returned no valid FILE bundles.'}
$allowed=@('.ts','.tsx','.js','.jsx','.mjs','.cjs','.json','.css','.md','.txt','.html','.svg','.xml','.yml','.yaml')
$repairFull=[IO.Path]::GetFullPath($RepairRoot).TrimEnd('\')+'\';$seen=@{};$applied=@()
foreach($m in $matches){
  $rel=$m.Groups[1].Value.Trim().Replace('/','\');$content=$m.Groups[2].Value
  if([IO.Path]::IsPathRooted($rel) -or $rel -match '(^|\\)\.\.(\\|$)'){throw "Rejected Qwen repair path: $rel"}
  $ext=[IO.Path]::GetExtension($rel).ToLowerInvariant();if($ext -notin $allowed){throw "Unsupported repair extension: $rel"}
  $key=$rel.ToLowerInvariant();if($seen.ContainsKey($key)){throw "Duplicate repair bundle: $rel"};$seen[$key]=$true
  $dest=[IO.Path]::GetFullPath((Join-Path $RepairRoot $rel));if(-not $dest.StartsWith($repairFull,[StringComparison]::OrdinalIgnoreCase)){throw "Repair path escaped root: $rel"}
  Write-Utf8 $dest $content;$applied+=[pscustomobject]@{file=$rel;bytes=(Get-Item -LiteralPath $dest).Length}
}
$s=Save-State 'running' 'files_applied' 'Applied only Qwen-authored repair FILE bundles.' ([pscustomobject]@{repair_model_call_attempted=$true;repair_model_calls_used=1;changed_files=$applied})

$install=Run-Npm @('install') 'repair-npm-install';$s=Save-State 'running' 'npm_install' "npm install exit=$($install.exit_code)" ([pscustomobject]@{repair_model_call_attempted=$true;repair_model_calls_used=1;npm_install=$install})
$build=$null;$smoke=$null;$routes=@('/','/services','/projects','/about','/contact')
if($install.exit_code -eq 0){$build=Run-Npm @('run','build') 'repair-npm-build';$s=Save-State 'running' 'build' "npm run build exit=$($build.exit_code)" ([pscustomobject]@{repair_model_call_attempted=$true;repair_model_calls_used=1;build=$build})}
if($build -and $build.exit_code -eq 0){$smoke=Run-Smoke $routes;$s=Save-State 'running' 'smoke' "route smoke $($smoke.passed)/$($smoke.total)" ([pscustomobject]@{repair_model_call_attempted=$true;repair_model_calls_used=1;smoke=$smoke})}
$pass=($install.exit_code -eq 0 -and $build -and $build.exit_code -eq 0 -and $smoke -and [bool]$smoke.pass)
$genTps=$null;$promptTps=$null
try{if([int64]$response.eval_duration -gt 0){$genTps=[math]::Round([double]$response.eval_count/([double]$response.eval_duration/1e9),2)};if([int64]$response.prompt_eval_duration -gt 0){$promptTps=[math]::Round([double]$response.prompt_eval_count/([double]$response.prompt_eval_duration/1e9),2)}}catch{}
$result=[ordered]@{
  schema=1;job_id=$JobId;original_job_id=$OriginalJobId;status='completed';host=$env:COMPUTERNAME;model=$Model;context=$Context;no_think=$true
  repair_model_calls_used=1;qwen_only_website_author=$true;human_written_website_code=0;source_sha=$SourceSha;original_result=$originalResultPath;repair_root=$RepairRoot
  prompt_sha256=$promptHash;prompt_eval_count=$response.prompt_eval_count;prompt_tokens_per_second=$promptTps;eval_count=$response.eval_count;generation_tokens_per_second=$genTps
  repair_wall_seconds=[math]::Round(($end-$start).TotalSeconds,2);changed_files=$applied;npm_install=$install;build=$build;smoke=$smoke;pass=$pass
  build_stdout_tail=$(if($build){Tail $build.stdout 40}else{''});build_stderr_tail=$(if($build){Tail $build.stderr 60}else{''});completed_at=(Get-Date -Format o)
}
$resultPath=Join-Path $RepairRoot 'AFZ-REPAIR-RESULT.json';Write-Json $resultPath $result
try{if(Test-Path -LiteralPath $SharedRoot -PathType Container){Write-Json $SharedResult $result}}catch{}
$s=Save-State 'completed' 'completed' "Qwen35B repair iteration completed; pass=$pass" ([pscustomobject]@{repair_model_call_attempted=$true;repair_model_calls_used=1;pass=$pass;result_file=$resultPath;shared_result=$SharedResult;generation_tokens_per_second=$genTps;eval_count=$response.eval_count})
Write-Output ('AFZ_QWEN35B_REPAIR_RESULT='+($result|ConvertTo-Json -Depth 40 -Compress))
exit $(if($pass){0}else{10})
