#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SourceSha,
  [Parameter(Mandatory=$true)][string]$JobId
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only recovery; host=$env:COMPUTERNAME"}
if($SourceSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SourceSha must be a 40-character Git SHA.'}
if($JobId -ne 'afz-blog-qwen35b-vs-ridge27b-20260902-r1'){throw 'Unexpected recovery job id.'}
$SourceSha=$SourceSha.ToLowerInvariant()

$repo='f3arif/homelab-control'
$stateRoot='C:\ProgramData\AFZ\H3AFZBlogModelComparison'
$projectRoot='C:\Projects\AFZ-Blog-Model-Comparison-20260902-r1'
$stateFile=Join-Path $stateRoot 'state.json'
$requestFile=Join-Path $projectRoot 'request.json'
$promptFile=Join-Path $projectRoot 'prompt.txt'
$utf8=New-Object Text.UTF8Encoding($false)

function Write-Utf8([string]$Path,[string]$Text){$parent=Split-Path $Path -Parent;if($parent -and -not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null};[IO.File]::WriteAllText($Path,$Text,$utf8)}
function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};return ([IO.File]::ReadAllText($Path,$utf8)|ConvertFrom-Json -ErrorAction Stop)}
function Write-Json([string]$Path,$Object){Write-Utf8 $Path ($Object|ConvertTo-Json -Depth 50)}
function Has-Prop($Object,[string]$Name){return ($Object -and $Object.PSObject.Properties.Name -contains $Name)}
function Get-ModelState($State,[string]$Model){if(-not $State -or -not(Has-Prop $State 'models')){return $null};foreach($p in $State.models.PSObject.Properties){if([string]$p.Name -eq $Model){return $p.Value}};return $null}
function Set-ModelState($States,[string]$Model,$Value){$States[$Model]=$Value}
function Count-Words([string]$Text){if([string]::IsNullOrWhiteSpace($Text)){return 0};return @($Text -split '\s+'|Where-Object{$_ -match '[A-Za-z0-9]'}).Count}
function Validate-Blog($Parsed,$Request){
  $errors=New-Object Collections.Generic.List[string]
  foreach($n in @('title','articleMarkdown','seoTitle','metaDescription','keywords','technicalReviewFlags','sources','codeClaims')){if(-not(Has-Prop $Parsed $n)){$errors.Add("missing:$n")}}
  if($errors.Count -gt 0){return [ordered]@{valid=$false;errors=@($errors);article_word_count=0;word_target_met=$false;source_count=0;claim_count=0;review_flag_count=0;keyword_count=0}}
  $classes=@('CURRENT_CODE_REQUIREMENT','STANDARD_OR_METHODOLOGY','ENGINEERING_BEST_PRACTICE','GENERAL_TECHNICAL_EXPLANATION','CURRENT_CODE_VERIFICATION_REQUIRED')
  $statuses=@('VERIFIED','ENGINEER_REVIEW_REQUIRED','NOT_VERIFIED')
  $severities=@('INFO','REVIEW','IMPORTANT')
  $allowedUrls=@($Request.source_packet|ForEach-Object{[string]$_.url})
  foreach($f in @($Parsed.technicalReviewFlags)){if(-not(Has-Prop $f 'category') -or -not(Has-Prop $f 'severity') -or -not(Has-Prop $f 'message')){$errors.Add('invalid:technicalReviewFlag')}elseif([string]$f.severity -notin $severities){$errors.Add('invalid:reviewSeverity')}}
  foreach($s in @($Parsed.sources)){foreach($n in @('organization','title','url','sourceType','sourceCurrency','reliedUponForCurrentCode','engineerVerificationRequired','notes')){if(-not(Has-Prop $s $n)){$errors.Add("invalid:source:$n")}};if((Has-Prop $s 'url') -and [string]$s.url -notin $allowedUrls){$errors.Add('invalid:sourceUrl:notInPacket')}}
  foreach($c in @($Parsed.codeClaims)){foreach($n in @('claim','classification','provision','sourceUrl','sourceCurrency','verificationStatus','notes')){if(-not(Has-Prop $c $n)){$errors.Add("invalid:claim:$n")}};if((Has-Prop $c 'classification') -and [string]$c.classification -notin $classes){$errors.Add('invalid:claimClassification')};if((Has-Prop $c 'verificationStatus') -and [string]$c.verificationStatus -notin $statuses){$errors.Add('invalid:verificationStatus')};if((Has-Prop $c 'sourceUrl') -and $c.sourceUrl -and [string]$c.sourceUrl -notin $allowedUrls){$errors.Add('invalid:claimSourceUrl:notInPacket')}}
  $words=Count-Words ([string]$Parsed.articleMarkdown)
  return [ordered]@{valid=($errors.Count -eq 0);errors=@($errors);article_word_count=$words;word_target_met=($words -ge [int]$Request.article_word_target_min -and $words -le [int]$Request.article_word_target_max);source_count=@($Parsed.sources).Count;claim_count=@($Parsed.codeClaims).Count;review_flag_count=@($Parsed.technicalReviewFlags).Count;keyword_count=@($Parsed.keywords).Count}
}
function Get-Key([string]$Model){if($Model -eq 'qwen3.6:35b-a3b'){return 'qwen35b-a3b'};if($Model -eq 'qwen3.8-ridge:27b-16k'){return 'ridge27b-16k'};throw "Unexpected model: $Model"}
function Convert-SavedResponse([string]$Model,[string]$PromptHash,$Request,[string]$RecoveryKind){
  $key=Get-Key $Model
  $respFile=Join-Path $projectRoot ($key+'-ollama-response.json')
  if(-not(Test-Path -LiteralPath $respFile -PathType Leaf)){throw "Saved response missing for attempted model ${Model}: $respFile"}
  $ollama=Read-Json $respFile
  if((Has-Prop $ollama 'error') -and -not [string]::IsNullOrWhiteSpace([string]$ollama.error)){return [ordered]@{attempted=$true;status='failed';model=$Model;error=[string]$ollama.error;recovered_from_saved_response=$true;recovery_kind=$RecoveryKind;finished_at=(Get-Date -Format o)}}
  if(-not(Has-Prop $ollama 'response')){throw "Saved Ollama response has no response field for $Model"}
  $raw=[string]$ollama.response
  Write-Utf8 (Join-Path $projectRoot ($key+'-raw.txt')) $raw
  $parsed=$null;$jsonValid=$false;$parseError=$null
  try{$parsed=$raw|ConvertFrom-Json -ErrorAction Stop;$jsonValid=$true}catch{$parseError=$_.Exception.Message}
  if($jsonValid){Write-Json (Join-Path $projectRoot ($key+'-structured.json')) $parsed;$validation=Validate-Blog $parsed $Request}else{$validation=[ordered]@{valid=$false;errors=@('strict-json-parse-failed');article_word_count=0;word_target_met=$false;source_count=0;claim_count=0;review_flag_count=0;keyword_count=0}}
  $outTps=$null;if((Has-Prop $ollama 'eval_count') -and (Has-Prop $ollama 'eval_duration') -and [double]$ollama.eval_duration -gt 0){$outTps=[math]::Round([double]$ollama.eval_count/([double]$ollama.eval_duration/1e9),2)}
  $promptTps=$null;if((Has-Prop $ollama 'prompt_eval_count') -and (Has-Prop $ollama 'prompt_eval_duration') -and [double]$ollama.prompt_eval_duration -gt 0){$promptTps=[math]::Round([double]$ollama.prompt_eval_count/([double]$ollama.prompt_eval_duration/1e9),2)}
  $wall=$null;if((Has-Prop $ollama 'total_duration') -and [double]$ollama.total_duration -gt 0){$wall=[math]::Round([double]$ollama.total_duration/1e9,2)}
  $metrics=[ordered]@{model=$Model;attempted=$true;status='completed';wall_seconds=$wall;done=$(if(Has-Prop $ollama 'done'){[bool]$ollama.done}else{$null});done_reason=$(if(Has-Prop $ollama 'done_reason'){[string]$ollama.done_reason}else{$null});prompt_tokens=$(if(Has-Prop $ollama 'prompt_eval_count'){$ollama.prompt_eval_count}else{$null});prompt_tokens_per_second=$promptTps;output_tokens=$(if(Has-Prop $ollama 'eval_count'){$ollama.eval_count}else{$null});output_tokens_per_second=$outTps;strict_json_valid=$jsonValid;strict_json_parse_error=$parseError;schema_valid=[bool]$validation.valid;schema_errors=@($validation.errors);article_word_count=[int]$validation.article_word_count;word_target_met=[bool]$validation.word_target_met;source_count=[int]$validation.source_count;claim_count=[int]$validation.claim_count;review_flag_count=[int]$validation.review_flag_count;keyword_count=[int]$validation.keyword_count;prompt_sha256=$PromptHash;recovered_from_saved_response=$true;recovery_kind=$RecoveryKind;completed_at=(Get-Date -Format o)}
  Write-Json (Join-Path $projectRoot ($key+'-metrics.json')) $metrics
  return $metrics
}
function Save-State([string]$Status,$States,[string]$Message){$o=[ordered]@{schema=1;project='afz-blog-local-model-comparison';job_id=$JobId;status=$Status;source_sha=$SourceSha;host=$env:COMPUTERNAME;project_root=$projectRoot;models=$States;message=$Message;recovery='post-return-v1';updated_at=(Get-Date -Format o)};Write-Json $stateFile $o}
function Find-Gh{$c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){return $(if($c.Source){$c.Source}else{$c.Path})};foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path $p){return $p}};return $null}
function Quote-Arg([string]$v){if($null -eq $v){return '""'};if($v -notmatch '[\s"]'){return $v};return '"'+($v.Replace('"','\"'))+'"'}
function Invoke-Gh([string[]]$Args){$o=Join-Path $env:TEMP ('afz-blog-rec-gh-'+[guid]::NewGuid().ToString('N')+'.out');$e=$o+'.err';try{$line=($Args|ForEach-Object{Quote-Arg ([string]$_)}) -join ' ';$p=Start-Process -FilePath $script:gh -ArgumentList $line -RedirectStandardOutput $o -RedirectStandardError $e -Wait -PassThru -NoNewWindow;return [pscustomobject]@{ExitCode=[int]$p.ExitCode;Stdout=$(if(Test-Path $o){[IO.File]::ReadAllText($o).Trim()}else{''});Stderr=$(if(Test-Path $e){[IO.File]::ReadAllText($e).Trim()}else{''})}}finally{Remove-Item $o,$e -Force -ErrorAction SilentlyContinue}}
function Get-RemoteSha([string]$Path,[string]$Branch){$r=Invoke-Gh @('api',"repos/$repo/contents/${Path}?ref=${Branch}",'--jq','.sha');if($r.ExitCode -ne 0){return $null};$s=$r.Stdout.Trim();if($s -match '^[0-9a-f]{40}$'){return $s};return $null}
function Put-Text([string]$Path,[string]$Text,[string]$Branch,[string]$Message){$payload=[ordered]@{message=$Message;content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text));branch=$Branch};$rs=Get-RemoteSha $Path $Branch;if($rs){$payload.sha=$rs};$tmp=Join-Path $env:TEMP ('afz-blog-rec-put-'+[guid]::NewGuid().ToString('N')+'.json');try{Write-Utf8 $tmp ($payload|ConvertTo-Json -Compress);$r=Invoke-Gh @('api',"repos/$repo/contents/$Path",'--method','PUT','--input',$tmp);if($r.ExitCode -ne 0){throw "GitHub PUT failed ${Path}: $($r.Stderr)"}}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}}
function Publish($Request,$States,[string]$Status){if(-not $script:gh){return $false};try{$base=[string]$Request.result_path;$branch=[string]$Request.result_branch;$summary=[ordered]@{schema=1;project='afz-blog-local-model-comparison';job_id=$JobId;status=$Status;source_sha=$SourceSha;host=$env:COMPUTERNAME;topic=[string]$Request.topic;context=[int]$Request.context;no_think=[bool]$Request.no_think;num_predict=[int]$Request.num_predict;temperature=[double]$Request.temperature;publish_article=$false;production_db_mutation=$false;recovery='post-return-v1';models=$States;updated_at=(Get-Date -Format o)};Put-Text "$base/summary.json" ($summary|ConvertTo-Json -Depth 50) $branch "Recover H3 AFZ blog comparison $Status $JobId";foreach($m in @($Request.models)){$key=Get-Key ([string]$m);foreach($name in @("$key-metrics.json","$key-raw.txt","$key-ollama-response.json","$key-structured.json")){$local=Join-Path $projectRoot $name;if(Test-Path $local){Put-Text "$base/$name" ([IO.File]::ReadAllText($local,$utf8)) $branch "Recover H3 AFZ blog artifact $key $JobId"}}};return $true}catch{return $false}}
function Comment([string]$Body){if(-not $script:gh){return};$tmp=Join-Path $env:TEMP ('afz-blog-rec-comment-'+[guid]::NewGuid().ToString('N')+'.txt');try{Write-Utf8 $tmp $Body;[void](Invoke-Gh @('issue','comment','31','--repo','f3arif/faiz-homelab','--body-file',$tmp))}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}}

if(-not(Test-Path $stateFile)){throw 'Prior state file missing; refusing recovery.'}
if(-not(Test-Path $requestFile)){throw 'Frozen local request missing; refusing recovery.'}
if(-not(Test-Path $promptFile)){throw 'Frozen prompt missing; refusing recovery.'}
$state=Read-Json $stateFile;$request=Read-Json $requestFile;$prompt=[IO.File]::ReadAllText($promptFile,$utf8)
if([string]$state.job_id -ne $JobId -or [string]$request.job_id -ne $JobId){throw 'Job identity mismatch.'}
if([int]$request.max_model_calls_per_model -ne 1 -or [bool]$request.publish_article -or [bool]$request.production_db_mutation){throw 'Safety contract mismatch.'}
$promptHash=(Get-FileHash -LiteralPath $promptFile -Algorithm SHA256).Hash.ToLowerInvariant()
$states=[ordered]@{}
foreach($m in @($request.models)){ $s=Get-ModelState $state ([string]$m); if($s){$states[[string]$m]=$s}else{$states[[string]$m]=[ordered]@{attempted=$false;status='pending'}} }

$first='qwen3.6:35b-a3b';$second='qwen3.8-ridge:27b-16k'
$firstState=$states[$first]
if(-not [bool]$firstState.attempted){throw '35B prior state does not prove an attempted call; recovery refuses to create one.'}
if([string]$firstState.status -ne 'completed'){
  $states[$first]=Convert-SavedResponse $first $promptHash $request 'saved-35b-post-return'
  Save-State 'running' $states 'Recovered preserved 35B response without model replay.'
}

$secondState=$states[$second]
if([bool]$secondState.attempted){
  if([string]$secondState.status -ne 'completed'){
    $secondResp=Join-Path $projectRoot 'ridge27b-16k-ollama-response.json'
    if(Test-Path $secondResp){$states[$second]=Convert-SavedResponse $second $promptHash $request 'saved-ridge-post-return'}else{$states[$second]=[ordered]@{attempted=$true;status='blocked-no-replay';model=$second;blocked_reason='Prior state proves Ridge was attempted but no saved response is available.';observed_at=(Get-Date -Format o)}}
  }
}else{
  $key=Get-Key $second;$req=Join-Path $projectRoot ($key+'-ollama-request.json');$resp=Join-Path $projectRoot ($key+'-ollama-response.json')
  $body=[ordered]@{model=$second;prompt=$prompt;stream=$false;think=$false;options=[ordered]@{num_ctx=[int]$request.context;temperature=[double]$request.temperature;num_predict=[int]$request.num_predict}}
  Write-Json $req $body
  $states[$second]=[ordered]@{attempted=$true;status='running';model=$second;started_at=(Get-Date -Format o);prompt_sha256=$promptHash;context=[int]$request.context;num_predict=[int]$request.num_predict}
  Save-State 'running' $states 'Ridge Ollama POST starting; single-flight guard set before request.'
  [void](Publish $request $states 'running')
  $start=Get-Date
  & curl.exe -sS --max-time 10800 -H 'Content-Type: application/json' --data-binary "@$req" -o "$resp" 'http://127.0.0.1:11434/api/generate'
  $exit=$LASTEXITCODE;$end=Get-Date
  if($exit -ne 0){$states[$second]=[ordered]@{attempted=$true;status='failed';model=$second;curl_exit=$exit;wall_seconds=[math]::Round(($end-$start).TotalSeconds,2);error="Ollama transport failed with curl exit $exit";finished_at=(Get-Date -Format o)}}else{$states[$second]=Convert-SavedResponse $second $promptHash $request 'first-ridge-call'}
}

$completed=@($request.models|Where-Object{[string]$states[[string]$_].status -eq 'completed'}).Count
$blocked=@($request.models|Where-Object{[string]$states[[string]$_].status -eq 'blocked-no-replay'}).Count
$failed=@($request.models|Where-Object{[string]$states[[string]$_].status -eq 'failed'}).Count
$finalStatus=if($completed -eq 2){'completed'}else{'partial'}
Save-State $finalStatus $states "Recovery finished completed=$completed blocked=$blocked failed=$failed."
$pushed=Publish $request $states $finalStatus
$script:gh=Find-Gh
if($script:gh){$auth=Invoke-Gh @('auth','status','--hostname','github.com');if($auth.ExitCode -ne 0){$script:gh=$null}}
if($script:gh){[void](Publish $request $states $finalStatus);Comment "[RESULT][H3-AFZ-BLOG-COMPARE-RECOVERY] Job $JobId status=$finalStatus completed=$completed/2 blocked=$blocked failed=$failed. 35B was recovered from its saved response without replay; Ridge was called only if prior state proved it unattempted. publish=false db_mutation=false."}
$out=[ordered]@{ok=($finalStatus -eq 'completed');job_id=$JobId;status=$finalStatus;completed_models=$completed;blocked_models=$blocked;failed_models=$failed;models=$states;publish_article=$false;production_db_mutation=$false;recovery='post-return-v1';completed_at=(Get-Date -Format o)}
Write-Output ('AFZ_BLOG_COMPARE_RECOVERY_JSON='+($out|ConvertTo-Json -Depth 50 -Compress))
if($finalStatus -ne 'completed'){exit 20}
exit 0
