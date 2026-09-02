#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedRepairSourceSha
)

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
$ResponseFile=Join-Path $RepairRoot 'AFZ-REPAIR-OLLAMA-RESPONSE.json'
$RawFile=Join-Path $RepairRoot 'AFZ-REPAIR-QWEN-RAW.txt'
$ResultPath=Join-Path $RepairRoot 'AFZ-REPAIR-RESULT.json'
$utf8=New-Object Text.UTF8Encoding($false)

function Write-Utf8([string]$Path,[string]$Text){
  $parent=Split-Path -Parent $Path
  if($parent -and -not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
  [IO.File]::WriteAllText($Path,$Text,$utf8)
}
function Write-Json([string]$Path,$Object){Write-Utf8 $Path ($Object|ConvertTo-Json -Depth 40 -Compress)}
function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{return $null}}
function Has-Prop($Object,[string]$Name){return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name)}
function Get-Prop($Object,[string]$Name,$Default=$null){if(Has-Prop $Object $Name){return $Object.$Name};return $Default}
function Save-State([string]$Status,[string]$Phase,[string]$Message,$Prior,$Extra=$null){
  $o=[ordered]@{
    schema=1;job_id=$JobId;original_job_id=$OriginalJobId;status=$Status;phase=$Phase;message=$Message
    host=$env:COMPUTERNAME;model=$Model;context=$Context;no_think=$true;max_repair_model_calls=1
    repair_model_call_attempted=$true;repair_model_calls_used=1;qwen_only_website_author=$true;human_written_website_code=0
    original_root=$OriginalRoot;repair_root=$RepairRoot;source_sha=$ExpectedRepairSourceSha;updated_at=(Get-Date -Format o)
    curl_exit=[int](Get-Prop $Prior 'curl_exit' 0)
    repair_model_call_started_at=[string](Get-Prop $Prior 'repair_model_call_started_at' '')
    repair_model_call_returned_at=[string](Get-Prop $Prior 'repair_model_call_returned_at' '')
    prompt_sha256=[string](Get-Prop $Prior 'prompt_sha256' '')
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
function Tail([string]$Path,[int]$Count=50){if(Test-Path -LiteralPath $Path -PathType Leaf){return ((Get-Content -LiteralPath $Path -Tail $Count -ErrorAction SilentlyContinue)-join "`n")};return ''}

if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only post-return continuation; host=$env:COMPUTERNAME"}
if($ExpectedRepairSourceSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedRepairSourceSha must be an exact 40-character commit SHA.'}
$ExpectedRepairSourceSha=$ExpectedRepairSourceSha.ToLowerInvariant()

$prior=Read-Json $StateFile
if(-not $prior){throw "Repair01 state missing: $StateFile"}
if([string](Get-Prop $prior 'job_id' '') -ne $JobId){throw 'Repair01 state job identity mismatch.'}
if([string](Get-Prop $prior 'model' '') -ne $Model){throw 'Repair01 state model mismatch.'}
$stateSourceSha=[string](Get-Prop $prior 'source_sha' '')
if($stateSourceSha.ToLowerInvariant() -ne $ExpectedRepairSourceSha){throw 'Repair01 source SHA mismatch.'}
if(-not [bool](Get-Prop $prior 'repair_model_call_attempted' $false)){throw 'Saved-response continuation refused because the repair model call was not proven attempted.'}
if([int](Get-Prop $prior 'repair_model_calls_used' 0) -ne 1){throw 'Saved-response continuation refused because repair_model_calls_used is not exactly 1.'}
if([int](Get-Prop $prior 'curl_exit' -1) -ne 0){throw 'Saved-response continuation refused because the saved transport did not return successfully.'}
if([string](Get-Prop $prior 'phase' '') -notin @('repair_ollama_post_returned','repair_response_received','files_applied','npm_install','build','smoke','completed')){throw "Unexpected Repair01 continuation phase: $([string](Get-Prop $prior 'phase' ''))"}

if(Test-Path -LiteralPath $ResultPath -PathType Leaf){
  $existingResult=Read-Json $ResultPath
  if($existingResult -and [string](Get-Prop $existingResult 'job_id' '') -eq $JobId){
    Write-Output ('AFZ_QWEN35B_REPAIR_POSTRETURN_RESULT='+($existingResult|ConvertTo-Json -Depth 40 -Compress))
    exit $(if([bool](Get-Prop $existingResult 'pass' $false)){0}else{10})
  }
}
if(-not(Test-Path -LiteralPath $ResponseFile -PathType Leaf)){throw "Saved Repair01 response missing: $ResponseFile"}
if(-not(Test-Path -LiteralPath (Join-Path $RepairRoot 'package.json') -PathType Leaf)){throw 'Repair root package.json missing; saved-response continuation refused.'}

$response=Get-Content -LiteralPath $ResponseFile -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
if(Has-Prop $response 'error'){
  $errValue=[string](Get-Prop $response 'error' '')
  if(-not [string]::IsNullOrWhiteSpace($errValue)){throw "Saved Repair01 response contains an error: $errValue"}
}
$responseText=[string](Get-Prop $response 'response' '')
if([string]::IsNullOrWhiteSpace($responseText)){throw 'Saved Repair01 response contains no response text.'}
Write-Utf8 $RawFile $responseText
$pattern='(?ms)<<<FILE:\s*([^>\r\n]+?)\s*>>>\s*\r?\n(.*?)\r?\n?<<<END FILE>>>'
$matches=[regex]::Matches($responseText,$pattern)
if($matches.Count -eq 0){throw 'Saved Repair01 response returned no valid FILE bundles.'}
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
$prior=Save-State 'running' 'files_applied' 'Applied only Qwen-authored FILE bundles from the already-saved Repair01 response.' $prior ([pscustomobject]@{changed_files=$applied})

$install=Run-Npm @('install') 'repair-npm-install'
$prior=Save-State 'running' 'npm_install' "npm install exit=$($install.exit_code)" $prior ([pscustomobject]@{changed_files=$applied;npm_install=$install})
$build=$null;$smoke=$null;$routes=@('/','/services','/projects','/about','/contact')
if($install.exit_code -eq 0){
  $build=Run-Npm @('run','build') 'repair-npm-build'
  $prior=Save-State 'running' 'build' "npm run build exit=$($build.exit_code)" $prior ([pscustomobject]@{changed_files=$applied;npm_install=$install;build=$build})
}
if($build -and $build.exit_code -eq 0){
  $smoke=Run-Smoke $routes
  $prior=Save-State 'running' 'smoke' "route smoke $($smoke.passed)/$($smoke.total)" $prior ([pscustomobject]@{changed_files=$applied;npm_install=$install;build=$build;smoke=$smoke})
}
$pass=($install.exit_code -eq 0 -and $build -and $build.exit_code -eq 0 -and $smoke -and [bool]$smoke.pass)
$genTps=$null;$promptTps=$null
try{
  $evalDuration=[int64](Get-Prop $response 'eval_duration' 0);$evalCount=[int64](Get-Prop $response 'eval_count' 0)
  $promptDuration=[int64](Get-Prop $response 'prompt_eval_duration' 0);$promptCount=[int64](Get-Prop $response 'prompt_eval_count' 0)
  if($evalDuration -gt 0){$genTps=[math]::Round([double]$evalCount/([double]$evalDuration/1e9),2)}
  if($promptDuration -gt 0){$promptTps=[math]::Round([double]$promptCount/([double]$promptDuration/1e9),2)}
}catch{}
$result=[ordered]@{
  schema=1;job_id=$JobId;original_job_id=$OriginalJobId;status='completed';host=$env:COMPUTERNAME;model=$Model;context=$Context;no_think=$true
  repair_model_calls_used=1;qwen_only_website_author=$true;human_written_website_code=0;source_sha=$ExpectedRepairSourceSha
  original_result=(Join-Path $OriginalRoot 'AFZ-BENCHMARK-RESULT.json');repair_root=$RepairRoot
  prompt_sha256=[string](Get-Prop $prior 'prompt_sha256' '')
  prompt_eval_count=$(Get-Prop $response 'prompt_eval_count' $null);prompt_tokens_per_second=$promptTps
  eval_count=$(Get-Prop $response 'eval_count' $null);generation_tokens_per_second=$genTps
  repair_wall_seconds=$(try{[math]::Round(([DateTimeOffset]::Parse([string](Get-Prop $prior 'repair_model_call_returned_at' ''))-[DateTimeOffset]::Parse([string](Get-Prop $prior 'repair_model_call_started_at' ''))).TotalSeconds,2)}catch{$null})
  changed_files=$applied;npm_install=$install;build=$build;smoke=$smoke;pass=$pass
  build_stdout_tail=$(if($build){Tail $build.stdout 40}else{''});build_stderr_tail=$(if($build){Tail $build.stderr 60}else{''});completed_at=(Get-Date -Format o)
  continuation='saved-response-only';additional_model_call_issued=$false
}
Write-Json $ResultPath $result
try{if(Test-Path -LiteralPath $SharedRoot -PathType Container){Write-Json $SharedResult $result}}catch{}
$null=Save-State 'completed' 'completed' "Qwen35B Repair01 saved-response continuation completed; pass=$pass" $prior ([pscustomobject]@{changed_files=$applied;pass=$pass;result_file=$ResultPath;shared_result=$SharedResult;generation_tokens_per_second=$genTps;eval_count=$(Get-Prop $response 'eval_count' $null);additional_model_call_issued=$false})
Write-Output ('AFZ_QWEN35B_REPAIR_POSTRETURN_RESULT='+($result|ConvertTo-Json -Depth 40 -Compress))
exit $(if($pass){0}else{10})
