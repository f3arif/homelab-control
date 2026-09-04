#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$ProjectRoot='C:\Projects\Qwen38-27B-Website-Benchmark-20260826-174739',
  [string]$Model='qwen3.8:27b',
  [int]$StartIteration=2,
  [int]$MaxIterations=5
)

$ErrorActionPreference='Stop'
$utf8NoBom=New-Object System.Text.UTF8Encoding($false)
$requiredRoutes=@('/','/services','/projects','/about','/contact')
$controllerRoot=Join-Path $ProjectRoot 'AFZ-BENCHMARK-CONTROLLER'
$historyRoot=Join-Path $controllerRoot 'history'
$stateFile=Join-Path $controllerRoot 'state.json'
$resultFile=Join-Path $ProjectRoot 'BENCHMARK-RESULT.md'
$endFile=Join-Path $ProjectRoot 'BENCHMARK-END.txt'
$finalZip=Join-Path $ProjectRoot 'Qwen38-27B-Website-Benchmark-Final.zip'
New-Item -ItemType Directory -Force -Path $controllerRoot,$historyRoot | Out-Null

function Write-Utf8NoBom([string]$Path,[string]$Text){
  $parent=Split-Path $Path -Parent
  if($parent -and -not(Test-Path $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
  [IO.File]::WriteAllText($Path,$Text,$utf8NoBom)
}
function Write-JsonFile([string]$Path,$Object){Write-Utf8NoBom $Path (($Object|ConvertTo-Json -Depth 20 -Compress))}
function Save-State([string]$Status,[string]$Phase,[int]$Iteration,[string]$Message,$Extra=$null){
  $o=[ordered]@{ok=($Status -notin @('failed','error'));status=$Status;phase=$Phase;iteration=$Iteration;message=$Message;model=$Model;projectRoot=$ProjectRoot;time=(Get-Date -Format o)}
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  Write-JsonFile $stateFile $o
}
function Ns-To-Sec($Value){if($null -eq $Value){return $null};return [math]::Round(([double]$Value/1e9),2)}
function Get-FreePort{
  $l=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
  $l.Start();try{return ([Net.IPEndPoint]$l.LocalEndpoint).Port}finally{$l.Stop()}
}
function Get-SourceSnapshot{
  $files=@()
  foreach($dir in @('app','components','lib')){$p=Join-Path $ProjectRoot $dir;if(Test-Path $p){$files+=Get-ChildItem $p -Recurse -File}}
  foreach($name in @('package.json','package-lock.json','tsconfig.json','next.config.mjs','next.config.ts','tailwind.config.ts','postcss.config.js')){$p=Join-Path $ProjectRoot $name;if(Test-Path $p){$files+=Get-Item $p}}
  $sb=New-Object Text.StringBuilder
  foreach($f in ($files|Sort-Object FullName -Unique)){
    $rel=$f.FullName.Substring($ProjectRoot.Length).TrimStart('\')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("===== CURRENT FILE: $rel =====")
    [void]$sb.AppendLine((Get-Content $f.FullName -Raw))
    [void]$sb.AppendLine("===== END CURRENT FILE: $rel =====")
  }
  return $sb.ToString()
}
function Run-NpmInstall([string]$Tag){
  $out=Join-Path $controllerRoot "$Tag-npm-install.stdout.log";$err=Join-Path $controllerRoot "$Tag-npm-install.stderr.log"
  Remove-Item $out,$err -Force -ErrorAction SilentlyContinue
  $s=Get-Date
  $p=Start-Process -FilePath 'npm.cmd' -ArgumentList @('install') -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -Wait -PassThru -NoNewWindow
  return [pscustomobject]@{exitCode=$p.ExitCode;seconds=[math]::Round(((Get-Date)-$s).TotalSeconds,2);stdout=$out;stderr=$err}
}
function Run-Build([string]$Tag){
  $out=Join-Path $controllerRoot "$Tag-build.stdout.log";$err=Join-Path $controllerRoot "$Tag-build.stderr.log";$combined=Join-Path $controllerRoot "$Tag-build.log"
  Remove-Item $out,$err,$combined -Force -ErrorAction SilentlyContinue
  $s=Get-Date
  $p=Start-Process -FilePath 'npm.cmd' -ArgumentList @('run','build') -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -Wait -PassThru -NoNewWindow
  $text='';if(Test-Path $out){$text+=Get-Content $out -Raw};if(Test-Path $err){$text+="`r`n===== STDERR =====`r`n"+(Get-Content $err -Raw)}
  Write-Utf8NoBom $combined $text
  return [pscustomobject]@{exitCode=$p.ExitCode;seconds=[math]::Round(((Get-Date)-$s).TotalSeconds,2);log=$combined;text=$text}
}
function Run-Smoke([string]$Tag){
  $port=Get-FreePort
  $out=Join-Path $controllerRoot "$Tag-server.stdout.log";$err=Join-Path $controllerRoot "$Tag-server.stderr.log"
  Remove-Item $out,$err -Force -ErrorAction SilentlyContinue
  $server=$null
  try{
    $server=Start-Process -FilePath 'npm.cmd' -ArgumentList @('start','--','-p',[string]$port) -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
    $ready=$false
    for($i=0;$i -lt 30;$i++){
      Start-Sleep -Seconds 1
      try{$r=Invoke-WebRequest -Uri "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 3;if($r.StatusCode -eq 200){$ready=$true;break}}catch{}
      try{if($server.HasExited){break}}catch{}
    }
    $results=@()
    foreach($route in $requiredRoutes){
      try{$r=Invoke-WebRequest -Uri "http://127.0.0.1:$port$route" -UseBasicParsing -TimeoutSec 15;$results+=[pscustomobject]@{route=$route;http=[int]$r.StatusCode;bytes=[int]$r.Content.Length;pass=([int]$r.StatusCode -eq 200)}}
      catch{$code=0;try{if($_.Exception.Response){$code=[int]$_.Exception.Response.StatusCode}}catch{};$results+=[pscustomobject]@{route=$route;http=$code;bytes=0;pass=$false}}
    }
    $passed=@($results|Where-Object {$_.pass}).Count
    return [pscustomobject]@{ready=$ready;passed=$passed;total=$requiredRoutes.Count;pass=($ready -and $passed -eq $requiredRoutes.Count);results=$results;port=$port}
  } finally {
    if($server){try{& taskkill.exe /PID $server.Id /T /F *> $null}catch{}}
  }
}
function Failure-Context($Build,$Smoke){
  if($Build.exitCode -ne 0){$tail=@($Build.text -split "`r?`n")|Select-Object -Last 140;return "PRODUCTION BUILD FAILED.`n`n$($tail -join "`n")"}
  if($Smoke -and -not $Smoke.pass){$lines=@('Production build succeeds, but runtime route validation is incomplete.','Expected routes must remain usable; do not remove navigation links to make the test pass.','');foreach($r in $Smoke.results){$lines+=("{0} HTTP={1} BYTES={2}" -f $r.route,$r.http,$r.bytes)};return ($lines -join "`n")}
  return 'Unknown validation failure. Inspect the supplied project and repair structural completeness.'
}
function Invoke-QwenRepair([int]$Iteration,[string]$Failure){
  $tag=('iteration-{0:d2}' -f $Iteration)
  $source=Get-SourceSnapshot
  $prompt=@"
You are qwen3.8:27b continuing your own website-generation benchmark.

This is AUTONOMOUS REPAIR ITERATION $Iteration.

BENCHMARK RULES:
1. You are the ONLY website code author.
2. Do not start the project over.
3. Inspect your current generated project and the exact validation failure.
4. Decide yourself which files need to be created or modified.
5. Preserve your existing design, content, components, data, and style where reasonable.
6. Do not remove intended functionality or navigation merely to avoid a failing test.
7. Repair all related structural/build/runtime issues you can identify.
8. Return ONLY files that need creation or replacement.
9. Return COMPLETE contents for every changed/new file.
10. Do not use Markdown code fences.
11. Do not include explanations outside file bundles.
12. The controller will apply exactly your returned files, then run npm build and production HTTP tests.
13. Do not claim success yourself.

MANDATORY OUTPUT FORMAT:
<<<FILE: relative/path/to/file.ext>>>
COMPLETE FILE CONTENT
<<<END FILE>>>

VALIDATION FAILURE:
$Failure

CURRENT PROJECT:
$source

REPAIR YOUR WEBSITE.
"@
  $promptFile=Join-Path $controllerRoot "$tag-prompt.txt";$requestFile=Join-Path $controllerRoot "$tag-request.json";$responseFile=Join-Path $controllerRoot "$tag-response.json";$rawFile=Join-Path $controllerRoot "$tag-raw.txt";$metricsFile=Join-Path $controllerRoot "$tag-metrics.json";$appliedFile=Join-Path $controllerRoot "$tag-applied.json"
  Write-Utf8NoBom $promptFile $prompt
  $request=@{model=$Model;prompt=$prompt;stream=$false;options=@{num_ctx=32768;temperature=0.2}}
  $json=$request|ConvertTo-Json -Depth 10 -Compress;$null=$json|ConvertFrom-Json;Write-Utf8NoBom $requestFile $json
  Save-State 'running' 'qwen' $Iteration 'Calling Qwen repair iteration.' ([pscustomobject]@{promptChars=$prompt.Length})
  $s=Get-Date
  & curl.exe -sS --max-time 7200 -H 'Content-Type: application/json' --data-binary "@$requestFile" -o "$responseFile" 'http://127.0.0.1:11434/api/generate'
  $curlExit=$LASTEXITCODE;$e=Get-Date
  if($curlExit -ne 0){throw "Ollama transport failed with curl exit $curlExit"}
  $response=(Get-Content $responseFile -Raw)|ConvertFrom-Json
  if($response.error){throw "Ollama error: $($response.error)"}
  if([string]::IsNullOrWhiteSpace([string]$response.response)){throw 'Qwen returned no response text'}
  Write-Utf8NoBom $rawFile ([string]$response.response)
  $tps=$null;if($response.eval_count -and $response.eval_duration -gt 0){$tps=[math]::Round($response.eval_count/($response.eval_duration/1e9),2)}
  $metrics=[ordered]@{model=$Model;iteration=$Iteration;startedAt=$s.ToString('o');finishedAt=$e.ToString('o');wallSeconds=[math]::Round(($e-$s).TotalSeconds,2);ollamaTotalSeconds=Ns-To-Sec $response.total_duration;loadSeconds=Ns-To-Sec $response.load_duration;promptTokens=$response.prompt_eval_count;outputTokens=$response.eval_count;promptSeconds=Ns-To-Sec $response.prompt_eval_duration;outputSeconds=Ns-To-Sec $response.eval_duration;outputTokensPerSecond=$tps;done=$response.done;doneReason=$response.done_reason}
  Write-JsonFile $metricsFile $metrics
  $pattern='(?ms)<<<FILE:\s*([^>\r\n]+?)\s*>>>\s*\r?\n(.*?)\r?\n?<<<END FILE>>>'
  $matches=[regex]::Matches([string]$response.response,$pattern)
  if($matches.Count -eq 0){throw 'Qwen returned no valid file bundles'}
  $allowed=@('.ts','.tsx','.js','.jsx','.mjs','.cjs','.json','.css','.md','.txt','.html','.svg','.xml','.yml','.yaml')
  $rootFull=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')+'\';$seen=@{};$plan=@()
  foreach($m in $matches){
    $rel=$m.Groups[1].Value.Trim().Replace('/','\');$content=$m.Groups[2].Value
    if([IO.Path]::IsPathRooted($rel)){throw "Qwen emitted absolute path: $rel"};if($rel -match '(^|\\)\.\.(\\|$)'){throw "Qwen emitted path traversal: $rel"}
    $ext=[IO.Path]::GetExtension($rel).ToLowerInvariant();if($ext -notin $allowed){throw "Qwen emitted unsupported extension: $rel"}
    $key=$rel.ToLowerInvariant();if($seen.ContainsKey($key)){throw "Qwen emitted duplicate bundle: $rel"};$seen[$key]=$true
    $dest=[IO.Path]::GetFullPath((Join-Path $ProjectRoot $rel));if(-not $dest.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)){throw "Qwen path escaped project root: $rel"}
    $action=if(Test-Path $dest){'REPLACED'}else{'CREATED'};$plan+=[pscustomobject]@{action=$action;relative=$rel;destination=$dest;content=$content}
  }
  $beforeRoot=Join-Path $historyRoot "$tag-before";New-Item -ItemType Directory -Force -Path $beforeRoot|Out-Null
  foreach($item in $plan){if($item.action -eq 'REPLACED'){$backup=Join-Path $beforeRoot $item.relative;$bp=Split-Path $backup -Parent;New-Item -ItemType Directory -Force -Path $bp|Out-Null;Copy-Item $item.destination $backup -Force}}
  $applied=@();foreach($item in $plan){$parent=Split-Path $item.destination -Parent;New-Item -ItemType Directory -Force -Path $parent|Out-Null;Write-Utf8NoBom $item.destination $item.content;$applied+=[pscustomobject]@{action=$item.action;file=$item.relative;bytes=(Get-Item $item.destination).Length}}
  Write-JsonFile $appliedFile $applied
  return [pscustomobject]@{metrics=$metrics;applied=$applied;packageChanged=(@($applied|Where-Object {$_.file -in @('package.json','package-lock.json')}).Count -gt 0)}
}
function Finalize-Result([bool]$Success,[int]$LastIteration,$Build,$Smoke,[string]$Reason){
  $metricFiles=Get-ChildItem $controllerRoot -Filter 'iteration-*-metrics.json' -ErrorAction SilentlyContinue|Sort-Object Name
  $metrics=@();foreach($m in $metricFiles){try{$metrics+=Get-Content $m.FullName -Raw|ConvertFrom-Json}catch{}}
  $iterationLines=@();foreach($m in $metrics){$iterationLines+=("- Iteration {0}: wall {1}s, prompt {2}, output {3}, {4} tok/s" -f $m.iteration,$m.wallSeconds,$m.promptTokens,$m.outputTokens,$m.outputTokensPerSecond)}
  $routes='';if($Smoke){$routes=($Smoke.results|ForEach-Object{"- $($_.route): HTTP $($_.http), bytes $($_.bytes), pass=$($_.pass)"}) -join "`r`n"}
  $md=@"
# Qwen 3.8 27B Website Benchmark Result

- Status: $(if($Success){'PASS'}else{'FAIL'})
- Model: $Model
- Host: $env:COMPUTERNAME
- Project: $ProjectRoot
- Last repair iteration: $LastIteration
- Human-written website repair code: 0
- Controller policy: diagnostics/build/tests + apply only Qwen-authored file bundles
- Final build exit: $($Build.exitCode)
- Final build seconds: $($Build.seconds)
- Routes passing: $(if($Smoke){"$($Smoke.passed)/$($Smoke.total)"}else{'0/5'})
- Reason: $Reason

## Qwen repair metrics
$($iterationLines -join "`r`n")

## Final runtime routes
$routes

Generated: $(Get-Date -Format o)
"@
  Write-Utf8NoBom $resultFile $md
  Write-Utf8NoBom $endFile ("STATUS={0}`r`nTIME={1}`r`nLAST_ITERATION={2}`r`n" -f $(if($Success){'PASS'}else{'FAIL'}),(Get-Date -Format o),$LastIteration)
  Remove-Item $finalZip -Force -ErrorAction SilentlyContinue
  $items=@();foreach($name in @('app','components','lib','public','package.json','package-lock.json','tsconfig.json','next.config.mjs','next.config.ts','tailwind.config.ts','postcss.config.js','BENCHMARK-RESULT.md','BENCHMARK-END.txt')){$p=Join-Path $ProjectRoot $name;if(Test-Path $p){$items+=$p}}
  if($items.Count -gt 0){Compress-Archive -Path $items -DestinationPath $finalZip -Force}
  $summary=[ordered]@{ok=$Success;benchmarkStatus=$(if($Success){'PASS'}else{'FAIL'});model=$Model;host=$env:COMPUTERNAME;lastIteration=$LastIteration;buildExit=$Build.exitCode;buildSeconds=$Build.seconds;routesPassing=$(if($Smoke){$Smoke.passed}else{0});routesTotal=$requiredRoutes.Count;reason=$Reason;resultFile=$resultFile;zipFile=$(if(Test-Path $finalZip){$finalZip}else{$null});completedAt=(Get-Date -Format o)}
  Save-State $(if($Success){'completed'}else{'failed'}) 'complete' $LastIteration $Reason ([pscustomobject]@{result=$summary})
  Write-Output ('AFZ_RESULT_JSON='+($summary|ConvertTo-Json -Depth 10 -Compress))
  return $summary
}

try{
  if(-not(Test-Path $ProjectRoot)){throw "Project root missing: $ProjectRoot"}
  if(-not(Test-Path (Join-Path $ProjectRoot 'package.json'))){throw 'package.json missing'}
  if($StartIteration -lt 1){$StartIteration=1};if($MaxIterations -lt $StartIteration){$MaxIterations=$StartIteration};if($MaxIterations -gt 8){$MaxIterations=8}
  Set-Location $ProjectRoot
  $ollamaList=(& ollama list 2>&1|Out-String);if($LASTEXITCODE -ne 0 -or $ollamaList -notmatch [regex]::Escape($Model)){throw "Required Ollama model not available: $Model"}
  Save-State 'running' 'baseline' $StartIteration 'Running current build/runtime baseline.'
  if(-not(Test-Path (Join-Path $ProjectRoot 'node_modules'))){$install=Run-NpmInstall 'baseline';if($install.exitCode -ne 0){throw "npm install failed exit=$($install.exitCode)"}}
  $build=Run-Build 'baseline-current';$smoke=$null
  if($build.exitCode -eq 0){$smoke=Run-Smoke 'baseline-current';if($smoke.pass){$r=Finalize-Result $true ($StartIteration-1) $build $smoke 'Project already passes build and all runtime routes.';exit 0}}
  $failure=Failure-Context $build $smoke
  for($iteration=$StartIteration;$iteration -le $MaxIterations;$iteration++){
    $repair=Invoke-QwenRepair $iteration $failure
    if($repair.packageChanged){$install=Run-NpmInstall ("iteration-{0:d2}" -f $iteration);if($install.exitCode -ne 0){$build=[pscustomobject]@{exitCode=$install.exitCode;seconds=$install.seconds;log=$install.stderr;text=(Get-Content $install.stderr -Raw)};$smoke=$null;$failure="npm install failed after Qwen package changes.`n$($build.text)";continue}}
    Save-State 'running' 'build' $iteration 'Running production build after Qwen iteration.'
    $tag=("iteration-{0:d2}" -f $iteration);$build=Run-Build $tag;$smoke=$null
    if($build.exitCode -eq 0){Save-State 'running' 'smoke' $iteration 'Running production route smoke test.';$smoke=Run-Smoke $tag;if($smoke.pass){$r=Finalize-Result $true $iteration $build $smoke 'Production build passes and all required routes return HTTP 200.';exit 0}}
    $failure=Failure-Context $build $smoke
  }
  $r=Finalize-Result $false $MaxIterations $build $smoke "Bounded iteration limit reached before full website runtime success.";exit 2
} catch {
  $msg=$_.Exception.Message
  try{Save-State 'failed' 'exception' $StartIteration $msg}catch{}
  $summary=[ordered]@{ok=$false;benchmarkStatus='ERROR';model=$Model;host=$env:COMPUTERNAME;lastIteration=$StartIteration;buildExit=$null;buildSeconds=$null;routesPassing=0;routesTotal=$requiredRoutes.Count;reason=$msg;completedAt=(Get-Date -Format o)}
  Write-Output ('AFZ_RESULT_JSON='+($summary|ConvertTo-Json -Depth 10 -Compress))
  Write-Error $msg
  exit 1
}
