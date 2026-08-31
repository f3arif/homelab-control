#Requires -Version 5.1
[CmdletBinding()]
param()

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
$ResponseFile=Join-Path $ProjectRoot 'AFZ-OLLAMA-RESPONSE.json'
$RawFile=Join-Path $ProjectRoot 'AFZ-QWEN-RAW.txt'
$ResultFile=Join-Path $ProjectRoot 'AFZ-BENCHMARK-RESULT.json'
$TaskName='AFZ H3 Qwen35B A3B Benchmark'
$utf8=New-Object Text.UTF8Encoding($false)

function Write-Utf8([string]$Path,[string]$Text){
  $parent=Split-Path -Parent $Path
  if($parent -and -not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
  [IO.File]::WriteAllText($Path,$Text,$utf8)
}
function Write-Json([string]$Path,$Object){Write-Utf8 $Path ($Object|ConvertTo-Json -Depth 30 -Compress)}
function Get-Prop($Object,[string]$Name,$Default=$null){
  if($null -eq $Object){return $Default}
  if($Object.PSObject.Properties.Name -contains $Name){return $Object.$Name}
  return $Default
}
function Read-State{
  if(-not(Test-Path -LiteralPath $StateFile -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}
}
function Save-State([string]$Status,[string]$Phase,[string]$Message,$Prior,$Extra=$null){
  $sourceSha=[string](Get-Prop $Prior 'source_sha' '')
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
    model_call_attempted=$true
    qwen_only_website_author=$true
    human_written_website_code=0
    source_sha=$sourceSha
    project_root=$ProjectRoot
    recovery_mode='postreturn_no_model_call'
    updated_at=(Get-Date -Format o)
  }
  foreach($name in @('model_call_started_at','model_call_returned_at','curl_exit','wall_seconds','prompt_sha256')){
    if($Prior -and $Prior.PSObject.Properties.Name -contains $name){$o[$name]=$Prior.$name}
  }
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  Write-Json $StateFile $o
  if(Test-Path -LiteralPath $SharedRoot -PathType Container){try{Write-Json $SharedState $o}catch{}}
  return [pscustomobject]$o
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
      try{
        $r=Invoke-WebRequest -Uri "http://127.0.0.1:$port$route" -UseBasicParsing -TimeoutSec 10
        $rows+=[pscustomobject]@{route=$route;http=[int]$r.StatusCode;bytes=[int]$r.Content.Length;pass=([int]$r.StatusCode -eq 200)}
      }catch{
        $code=0
        try{if($_.Exception.Response){$code=[int]$_.Exception.Response.StatusCode}}catch{}
        $rows+=[pscustomobject]@{route=$route;http=$code;bytes=0;pass=$false}
      }
    }
    $passed=@($rows|Where-Object {$_.pass}).Count
    [pscustomobject]@{ready=$ready;passed=$passed;total=$Routes.Count;pass=($ready -and $passed -eq $Routes.Count);results=$rows;port=$port}
  }finally{
    if($server){try{& taskkill.exe /PID $server.Id /T /F *> $null}catch{}}
  }
}

if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only recovery; host=$env:COMPUTERNAME"}
if(Test-Path -LiteralPath $ResultFile -PathType Leaf){
  $existing=Get-Content -LiteralPath $ResultFile -Raw -Encoding UTF8|ConvertFrom-Json
  Write-Output ('AFZ_QWEN35B_RESULT='+($existing|ConvertTo-Json -Depth 30 -Compress))
  exit 0
}

$prior=Read-State
if($null -eq $prior){throw 'Existing guarded benchmark state is required.'}
if([string](Get-Prop $prior 'job_id' '') -ne $JobId){throw 'Unexpected benchmark job id in state.'}
if(-not [bool](Get-Prop $prior 'model_call_attempted' $false)){throw 'Recovery refused: model call was not previously attempted.'}
$phase=[string](Get-Prop $prior 'phase' '')
if($phase -notin @('ollama_post_returned','qwen_response_received','files_applied','npm_install','build','smoke','recovery_failed')){
  throw "Recovery refused from phase: $phase"
}
$curlExit=[int](Get-Prop $prior 'curl_exit' -1)
if($curlExit -ne 0){throw "Recovery refused: prior transport curl_exit=$curlExit"}
if(-not(Test-Path -LiteralPath $ResponseFile -PathType Leaf)){throw 'Saved Ollama response file is missing.'}

try{
  $response=(Get-Content -LiteralPath $ResponseFile -Raw -Encoding UTF8)|ConvertFrom-Json
  if($response.PSObject.Properties.Name -contains 'error'){
    $errorText=[string]$response.error
    if(-not [string]::IsNullOrWhiteSpace($errorText)){throw "Saved Ollama response contains error: $errorText"}
  }
  $responseText=[string](Get-Prop $response 'response' '')
  if([string]::IsNullOrWhiteSpace($responseText)){throw 'Saved Qwen response text is empty.'}
  Write-Utf8 $RawFile $responseText

  $promptHash=[string](Get-Prop $prior 'prompt_sha256' '')
  $promptEvalCount=Get-Prop $response 'prompt_eval_count' $null
  $evalCount=Get-Prop $response 'eval_count' $null
  $s=Save-State 'running' 'qwen_response_received' 'Saved Qwen response validated; applying exact FILE bundles without another model call.' $prior ([pscustomobject]@{
    prompt_eval_count=$promptEvalCount
    eval_count=$evalCount
  })

  $pattern='(?ms)<<<FILE:\s*([^>\r\n]+?)\s*>>>\s*\r?\n(.*?)\r?\n?<<<END FILE>>>'
  $matches=[regex]::Matches($responseText,$pattern)
  if($matches.Count -eq 0){throw 'Saved Qwen response contains no valid file bundles.'}
  $allowed=@('.ts','.tsx','.js','.jsx','.mjs','.cjs','.json','.css','.md','.txt','.html','.svg','.xml','.yml','.yaml')
  $rootFull=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')+'\'
  $seen=@{}
  $applied=@()
  foreach($m in $matches){
    $rel=$m.Groups[1].Value.Trim().Replace('/','\')
    $content=$m.Groups[2].Value
    if([IO.Path]::IsPathRooted($rel) -or $rel -match '(^|\\)\.\.(\\|$)'){throw "Rejected Qwen path: $rel"}
    $ext=[IO.Path]::GetExtension($rel).ToLowerInvariant()
    if($ext -notin $allowed){throw "Unsupported extension from Qwen: $rel"}
    $key=$rel.ToLowerInvariant()
    if($seen.ContainsKey($key)){throw "Duplicate Qwen file bundle: $rel"}
    $seen[$key]=$true
    $dest=[IO.Path]::GetFullPath((Join-Path $ProjectRoot $rel))
    if(-not $dest.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)){throw "Qwen path escaped project root: $rel"}
    Write-Utf8 $dest $content
    $applied+=[pscustomobject]@{file=$rel;bytes=(Get-Item -LiteralPath $dest).Length}
  }
  if(-not(Test-Path -LiteralPath (Join-Path $ProjectRoot 'package.json') -PathType Leaf)){throw 'Saved Qwen output did not include package.json.'}
  $s=Save-State 'running' 'files_applied' 'Qwen-authored bundles applied from saved response; starting npm validation.' $prior ([pscustomobject]@{
    file_count=$applied.Count
    files=$applied
  })

  $routes=@('/','/services','/projects','/about','/contact')
  $install=Run-Npm @('install') 'npm-install'
  $s=Save-State 'running' 'npm_install' 'npm install completed during post-return recovery.' $prior ([pscustomobject]@{npm_install=$install})
  $build=if($install.exit_code -eq 0){Run-Npm @('run','build') 'npm-build'}else{[pscustomobject]@{exit_code=$install.exit_code;seconds=0;stdout='';stderr=$install.stderr}}
  $s=Save-State 'running' 'build' 'Build validation completed during post-return recovery.' $prior ([pscustomobject]@{npm_install=$install;build=$build})
  if($build.exit_code -eq 0){$smoke=Run-Smoke $routes}else{$smoke=[pscustomobject]@{ready=$false;passed=0;total=$routes.Count;pass=$false;results=@();port=$null}}

  $promptEvalDuration=[double](Get-Prop $response 'prompt_eval_duration' 0)
  $evalDuration=[double](Get-Prop $response 'eval_duration' 0)
  $totalDuration=[double](Get-Prop $response 'total_duration' 0)
  $promptTps=$null
  if($null -ne $promptEvalCount -and $promptEvalDuration -gt 0){$promptTps=[math]::Round([double]$promptEvalCount/($promptEvalDuration/1e9),2)}
  $genTps=$null
  if($null -ne $evalCount -and $evalDuration -gt 0){$genTps=[math]::Round([double]$evalCount/($evalDuration/1e9),2)}
  $wallSeconds=[double](Get-Prop $prior 'wall_seconds' 0)

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
    recovery_mode='postreturn_no_model_call'
    source_sha=[string](Get-Prop $prior 'source_sha' '')
    project_root=$ProjectRoot
    prompt_sha256=$promptHash
    prompt_eval_count=$promptEvalCount
    prompt_eval_seconds=$(if($promptEvalDuration -gt 0){[math]::Round($promptEvalDuration/1e9,2)}else{$null})
    prompt_tokens_per_second=$promptTps
    eval_count=$evalCount
    eval_seconds=$(if($evalDuration -gt 0){[math]::Round($evalDuration/1e9,2)}else{$null})
    generation_tokens_per_second=$genTps
    ollama_total_seconds=$(if($totalDuration -gt 0){[math]::Round($totalDuration/1e9,2)}else{$null})
    wall_seconds=$wallSeconds
    model_call_started_at=(Get-Prop $prior 'model_call_started_at' $null)
    model_call_returned_at=(Get-Prop $prior 'model_call_returned_at' $null)
    files=$applied
    npm_install=$install
    build=$build
    smoke=$smoke
    pass=($install.exit_code -eq 0 -and $build.exit_code -eq 0 -and [bool]$smoke.pass)
    completed_at=(Get-Date -Format o)
  }
  Write-Json $ResultFile $result
  if(Test-Path -LiteralPath $SharedRoot -PathType Container){try{Write-Json $SharedResult $result}catch{}}
  $s=Save-State 'completed' 'completed' '35B-A3B website benchmark completed from the already-saved model response; no additional model call was made.' $prior ([pscustomobject]@{
    pass=[bool]$result.pass
    result_file=$ResultFile
    shared_result=$SharedResult
    generation_tokens_per_second=$genTps
    eval_count=$evalCount
  })
  Write-Output ('AFZ_QWEN35B_RESULT='+($result|ConvertTo-Json -Depth 30 -Compress))
}catch{
  $message=$_.Exception.Message
  try{$s=Save-State 'failed' 'recovery_failed' $message $prior ([pscustomobject]@{result_file=$ResultFile})}catch{}
  Write-Error $message
  exit 5
}
