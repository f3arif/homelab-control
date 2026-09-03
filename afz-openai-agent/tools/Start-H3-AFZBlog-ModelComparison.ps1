#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SourceSha
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only runner; host=$env:COMPUTERNAME"}
if($SourceSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SourceSha must be a 40-character Git commit SHA.'}
$SourceSha=$SourceSha.ToLowerInvariant()

$repo='f3arif/homelab-control'
$requestPath='afz-openai-agent/requests/h3-afz-blog-model-comparison.json'
$requestUrl="https://raw.githubusercontent.com/$repo/$SourceSha/$requestPath"
$stateRoot='C:\ProgramData\AFZ\H3AFZBlogModelComparison'
$projectRoot='C:\Projects\AFZ-Blog-Model-Comparison-20260902-r1'
$stateFile=Join-Path $stateRoot 'state.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot,$projectRoot|Out-Null

function Write-Utf8([string]$Path,[string]$Text){$parent=Split-Path $Path -Parent;if($parent -and -not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null};[IO.File]::WriteAllText($Path,$Text,$utf8)}
function Write-Json([string]$Path,$Object){Write-Utf8 $Path ($Object|ConvertTo-Json -Depth 50)}
function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return [IO.File]::ReadAllText($Path,$utf8)|ConvertFrom-Json -ErrorAction Stop}catch{return $null}}
function Get-Gh{
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path -LiteralPath $p){return $p}}
  return $null
}
function Quote-Arg([string]$v){if($null -eq $v){return '""'};if($v -notmatch '[\s"]'){return $v};return '"'+($v.Replace('"','\"'))+'"'}
function Invoke-Gh([string[]]$GhArgs){
  if(-not $script:gh){throw 'GitHub CLI not initialized.'}
  $o=Join-Path $env:TEMP ('afz-blog-gh-out-'+[guid]::NewGuid().ToString('N')+'.txt')
  $e=Join-Path $env:TEMP ('afz-blog-gh-err-'+[guid]::NewGuid().ToString('N')+'.txt')
  try{
    $line=($GhArgs|ForEach-Object{Quote-Arg ([string]$_)}) -join ' '
    $p=Start-Process -FilePath $script:gh -ArgumentList $line -RedirectStandardOutput $o -RedirectStandardError $e -Wait -PassThru -NoNewWindow
    $out=if(Test-Path $o){[IO.File]::ReadAllText($o)}else{''};$err=if(Test-Path $e){[IO.File]::ReadAllText($e)}else{''}
    return [pscustomobject]@{ExitCode=[int]$p.ExitCode;Stdout=$out.Trim();Stderr=$err.Trim()}
  }finally{Remove-Item $o,$e -Force -ErrorAction SilentlyContinue}
}
function Get-RemoteSha([string]$Path,[string]$Branch){
  $r=Invoke-Gh @('api',"repos/$repo/contents/${Path}?ref=${Branch}",'--jq','.sha')
  if($r.ExitCode -ne 0){return $null}
  $s=$r.Stdout.Trim();if($s -match '^[0-9a-f]{40}$'){return $s};return $null
}
function Put-Text([string]$Path,[string]$Text,[string]$Branch,[string]$Message){
  $payload=[ordered]@{message=$Message;content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text));branch=$Branch}
  $remote=Get-RemoteSha $Path $Branch;if($remote){$payload.sha=$remote}
  $tmp=Join-Path $env:TEMP ('afz-blog-put-'+[guid]::NewGuid().ToString('N')+'.json')
  try{
    Write-Utf8 $tmp ($payload|ConvertTo-Json -Compress)
    $r=Invoke-Gh @('api',"repos/$repo/contents/$Path",'--method','PUT','--input',$tmp)
    if($r.ExitCode -ne 0){throw "GitHub result PUT failed for $Path`: $($r.Stderr)"}
  }finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
}
function Try-Comment([string]$Body){
  try{
    $tmp=Join-Path $env:TEMP ('afz-blog-comment-'+[guid]::NewGuid().ToString('N')+'.txt')
    try{Write-Utf8 $tmp $Body;$r=Invoke-Gh @('issue','comment','31','--repo','f3arif/faiz-homelab','--body-file',$tmp);return ($r.ExitCode -eq 0)}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
  }catch{return $false}
}
function Get-PriorModelState($Prior,[string]$Model){
  if(-not $Prior -or -not $Prior.models){return $null}
  foreach($p in $Prior.models.PSObject.Properties){if([string]$p.Name -eq $Model){return $p.Value}}
  return $null
}
function Save-State([string]$Status,[string]$JobId,$ModelStates,[string]$Message){
  $state=[ordered]@{schema=1;project='afz-blog-local-model-comparison';job_id=$JobId;status=$Status;source_sha=$SourceSha;host=$env:COMPUTERNAME;project_root=$projectRoot;models=$ModelStates;message=$Message;updated_at=(Get-Date -Format o)}
  Write-Json $stateFile $state
}
function Count-Words([string]$Text){if([string]::IsNullOrWhiteSpace($Text)){return 0};return @($Text -split '\s+'|Where-Object{$_ -match '[A-Za-z0-9]'}).Count}
function Validate-BlogOutput($Parsed,$Request){
  $errors=New-Object Collections.Generic.List[string]
  $required=@('title','articleMarkdown','seoTitle','metaDescription','keywords','technicalReviewFlags','sources','codeClaims')
  foreach($name in $required){if(-not($Parsed.PSObject.Properties.Name -contains $name)){$errors.Add("missing:$name")}}
  if($errors.Count -gt 0){return [ordered]@{valid=$false;errors=@($errors);article_word_count=0;source_count=0;claim_count=0;review_flag_count=0}}
  foreach($name in @('title','articleMarkdown','seoTitle','metaDescription')){if([string]::IsNullOrWhiteSpace([string]$Parsed.$name)){$errors.Add("blank:$name")}}
  $classes=@('CURRENT_CODE_REQUIREMENT','STANDARD_OR_METHODOLOGY','ENGINEERING_BEST_PRACTICE','GENERAL_TECHNICAL_EXPLANATION','CURRENT_CODE_VERIFICATION_REQUIRED')
  $statuses=@('VERIFIED','ENGINEER_REVIEW_REQUIRED','NOT_VERIFIED')
  $severities=@('INFO','REVIEW','IMPORTANT')
  $allowedUrls=@($Request.source_packet|ForEach-Object{[string]$_.url})
  foreach($f in @($Parsed.technicalReviewFlags)){
    if(-not($f.PSObject.Properties.Name -contains 'category') -or -not($f.PSObject.Properties.Name -contains 'severity') -or -not($f.PSObject.Properties.Name -contains 'message')){$errors.Add('invalid:technicalReviewFlag');continue}
    if([string]$f.severity -notin $severities){$errors.Add('invalid:reviewSeverity')}
  }
  foreach($s in @($Parsed.sources)){
    foreach($n in @('organization','title','url','sourceType','sourceCurrency','reliedUponForCurrentCode','engineerVerificationRequired','notes')){if(-not($s.PSObject.Properties.Name -contains $n)){$errors.Add("invalid:source:$n")}}
    if([string]$s.url -notin $allowedUrls){$errors.Add('invalid:sourceUrl:notInPacket')}
  }
  foreach($c in @($Parsed.codeClaims)){
    foreach($n in @('claim','classification','provision','sourceUrl','sourceCurrency','verificationStatus','notes')){if(-not($c.PSObject.Properties.Name -contains $n)){$errors.Add("invalid:claim:$n")}}
    if([string]$c.classification -notin $classes){$errors.Add('invalid:claimClassification')}
    if([string]$c.verificationStatus -notin $statuses){$errors.Add('invalid:verificationStatus')}
    if($c.sourceUrl -and [string]$c.sourceUrl -notin $allowedUrls){$errors.Add('invalid:claimSourceUrl:notInPacket')}
  }
  $words=Count-Words ([string]$Parsed.articleMarkdown)
  return [ordered]@{valid=($errors.Count -eq 0);errors=@($errors);article_word_count=$words;word_target_met=($words -ge [int]$Request.article_word_target_min -and $words -le [int]$Request.article_word_target_max);source_count=@($Parsed.sources).Count;claim_count=@($Parsed.codeClaims).Count;review_flag_count=@($Parsed.technicalReviewFlags).Count;keyword_count=@($Parsed.keywords).Count}
}
function Get-ModelKey([string]$Model){if($Model -eq 'qwen3.6:35b-a3b'){return 'qwen35b-a3b'};if($Model -eq 'qwen3.8-ridge:27b-16k'){return 'ridge27b-16k'};return ($Model -replace '[^A-Za-z0-9.-]','_')}
function Publish-Snapshot([string]$JobId,$Request,$ModelStates,[string]$Status){
  if(-not $script:gh){return $false}
  try{
    $base=[string]$Request.result_path;$branch=[string]$Request.result_branch
    $summary=[ordered]@{schema=1;project='afz-blog-local-model-comparison';job_id=$JobId;status=$Status;source_sha=$SourceSha;host=$env:COMPUTERNAME;topic=[string]$Request.topic;context=[int]$Request.context;no_think=[bool]$Request.no_think;num_predict=[int]$Request.num_predict;temperature=[double]$Request.temperature;publish_article=$false;production_db_mutation=$false;models=$ModelStates;updated_at=(Get-Date -Format o)}
    Put-Text "$base/summary.json" ($summary|ConvertTo-Json -Depth 50) $branch "H3 AFZ blog comparison status $Status $JobId"
    foreach($model in @($Request.models)){
      $key=Get-ModelKey ([string]$model)
      foreach($name in @("$key-metrics.json","$key-raw.txt","$key-ollama-response.json","$key-structured.json")){
        $local=Join-Path $projectRoot $name
        if(Test-Path -LiteralPath $local -PathType Leaf){Put-Text "$base/$name" ([IO.File]::ReadAllText($local,$utf8)) $branch "H3 AFZ blog comparison artifact $key $JobId"}
      }
    }
    $promptPath=Join-Path $projectRoot 'prompt.txt';if(Test-Path $promptPath){Put-Text "$base/prompt.txt" ([IO.File]::ReadAllText($promptPath,$utf8)) $branch "H3 AFZ blog comparison prompt $JobId"}
    $reqLocal=Join-Path $projectRoot 'request.json';if(Test-Path $reqLocal){Put-Text "$base/request.json" ([IO.File]::ReadAllText($reqLocal,$utf8)) $branch "H3 AFZ blog comparison request $JobId"}
    return $true
  }catch{return $false}
}

$prior=Read-Json $stateFile
try{
  $rawReq=(Invoke-WebRequest -Uri $requestUrl -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-Blog-Comparison';'Cache-Control'='no-cache';'Pragma'='no-cache'} -TimeoutSec 60).Content
  $request=$rawReq|ConvertFrom-Json -ErrorAction Stop
  if([int]$request.schema -ne 1 -or [string]$request.project -ne 'afz-blog-local-model-comparison'){throw 'Typed blog comparison request contract mismatch.'}
  $job=[string]$request.job_id;if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid job id.'}
  if([string]$request.target -ne 'h3' -or [string]$request.host -ne $env:COMPUTERNAME){throw 'Request target/host mismatch.'}
  if([int]$request.context -ne 16384 -or -not [bool]$request.no_think -or [int]$request.max_model_calls_per_model -ne 1){throw 'Model-call safety contract mismatch.'}
  if([bool]$request.publish_article -or [bool]$request.production_db_mutation){throw 'Production mutation/publish must remain false.'}
  $models=@($request.models|ForEach-Object{[string]$_})
  if($models.Count -ne 2 -or $models[0] -ne 'qwen3.6:35b-a3b' -or $models[1] -ne 'qwen3.8-ridge:27b-16k'){throw 'Unexpected comparison models/order.'}
  if([int]$request.num_predict -lt 3000 -or [int]$request.num_predict -gt 6000){throw 'num_predict outside approved benchmark range.'}
  Write-Utf8 (Join-Path $projectRoot 'request.json') $rawReq

  $sourcePacket=($request.source_packet|ConvertTo-Json -Depth 20)
  $prompt=@"
/no_think

You are preparing a DRAFT technical article for AFZ Engineering Inc., an Ontario mechanical engineering practice. The article will be reviewed by a professional engineer before publication. It must never represent itself as permit-specific design advice or replace project-specific engineering.

This is an isolated local-model automation benchmark. You cannot browse the web. A fixed research packet is supplied below so both models receive identical evidence. Use ONLY that packet for source-dependent/current-code assertions. Do not invent a URL, clause number, article number, numeric requirement, airflow rate, replacement-air percentage, separation distance, hood dimension, duct construction rule, fire-suppression rule, or other current requirement that the packet does not explicitly verify.

CURRENT-CODE DISCIPLINE
For every important technical/code claim classify it as exactly one of:
CURRENT_CODE_REQUIREMENT
STANDARD_OR_METHODOLOGY
ENGINEERING_BEST_PRACTICE
GENERAL_TECHNICAL_EXPLANATION
CURRENT_CODE_VERIFICATION_REQUIRED

If a current requirement cannot be verified confidently from THIS packet: do not state it as a current code requirement; classify it CURRENT_CODE_VERIFICATION_REQUIRED; set verificationStatus to ENGINEER_REVIEW_REQUIRED; and identify exactly what the engineer must verify. Never invent a clause number.

ARTICLE REQUIREMENTS
Write approximately 1,100 to 1,400 words for Ontario homeowners, builders, contractors and property professionals. Tone: professional, technically careful, useful and understandable. Explain distinctions between legal/code requirements, standards/methodology, engineering best practice and general technical explanation. Do not overstate conclusions. Make the article practically useful for coordination before permit submission, including interfaces among hood/exhaust selection, make-up air, HVAC balance, controls/interlocks, architectural/structural/electrical/fire-protection coordination, equipment schedules and permit drawings, while refusing to invent unsupported numeric requirements.

Return the main authoritative sources actually relied upon from the fixed packet. For each source state whether it was relied upon for a current-code claim and whether engineer verification remains necessary. Return specific technicalReviewFlags for items a professional engineer should check before publication. The article MUST remain a draft.

SEO: provide a natural SEO title, meta description and useful non-spam keywords. Do not make promotional claims AFZ cannot substantiate. A short closing invitation to contact AFZ for project-specific mechanical engineering assistance is acceptable.

OUTPUT CONTRACT
Return ONE valid JSON object only. No Markdown code fence and no text before or after JSON. The JSON object must contain exactly these top-level fields (additional nested detail is not required):
{
  "title": string,
  "articleMarkdown": string,
  "seoTitle": string,
  "metaDescription": string,
  "keywords": string[],
  "technicalReviewFlags": [{"category":string,"severity":"INFO"|"REVIEW"|"IMPORTANT","message":string}],
  "sources": [{"organization":string,"title":string,"url":string,"sourceType":string,"sourceCurrency":string,"reliedUponForCurrentCode":boolean,"engineerVerificationRequired":boolean,"notes":string|null}],
  "codeClaims": [{"claim":string,"classification":"CURRENT_CODE_REQUIREMENT"|"STANDARD_OR_METHODOLOGY"|"ENGINEERING_BEST_PRACTICE"|"GENERAL_TECHNICAL_EXPLANATION"|"CURRENT_CODE_VERIFICATION_REQUIRED","provision":string|null,"sourceUrl":string|null,"sourceCurrency":string,"verificationStatus":"VERIFIED"|"ENGINEER_REVIEW_REQUIRED"|"NOT_VERIFIED","notes":string|null}]
}

ARTICLE TOPIC
$([string]$request.topic)

FIXED AUTHORITATIVE SOURCE PACKET
$sourcePacket
"@
  Write-Utf8 (Join-Path $projectRoot 'prompt.txt') $prompt
  $promptHash=(Get-FileHash -LiteralPath (Join-Path $projectRoot 'prompt.txt') -Algorithm SHA256).Hash.ToLowerInvariant()

  $ollamaList=(& ollama list 2>&1|Out-String)
  if($LASTEXITCODE -ne 0){throw 'ollama list failed.'}
  foreach($m in $models){if($ollamaList -notmatch [regex]::Escape($m)){throw "Required model unavailable: $m"}}

  $script:gh=Get-Gh
  if($script:gh){
    $auth=Invoke-Gh @('auth','status','--hostname','github.com')
    if($auth.ExitCode -ne 0){$script:gh=$null}
  }

  $modelStates=[ordered]@{}
  foreach($m in $models){
    $p=Get-PriorModelState $prior $m
    if($p){$modelStates[$m]=$p}else{$modelStates[$m]=[ordered]@{attempted=$false;status='pending'}}
  }
  if($prior -and [string]$prior.job_id -eq $job -and [string]$prior.status -eq 'completed'){
    [void](Publish-Snapshot $job $request $modelStates 'completed')
    Write-Output ('AFZ_BLOG_COMPARE_JSON='+($prior|ConvertTo-Json -Depth 50 -Compress))
    exit 0
  }

  Save-State 'running' $job $modelStates 'AFZ blog model comparison started; production publish and DB mutation disabled.'
  [void](Try-Comment "[STATUS][H3-AFZ-BLOG-COMPARE] Job $job started on H3. Same fixed source packet and production-shaped schema for 35B A3B then Ridge 27B. One call max per model; publish=false; production DB mutation=false; prompt_sha256=$promptHash")

  foreach($model in $models){
    $priorModel=Get-PriorModelState $prior $model
    if($priorModel -and [bool]$priorModel.attempted){
      if([string]$priorModel.status -eq 'completed'){$modelStates[$model]=$priorModel;continue}
      $blocked=[ordered]@{}
      foreach($p in $priorModel.PSObject.Properties){$blocked[$p.Name]=$p.Value}
      $blocked['status']='blocked-no-replay';$blocked['blocked_reason']='Prior state proves this model call was already attempted; benchmark policy forbids replay.';$blocked['observed_at']=(Get-Date -Format o)
      $modelStates[$model]=$blocked
      Save-State 'running' $job $modelStates "Skipped replay of already-attempted model $model."
      continue
    }

    $key=Get-ModelKey $model
    $reqFile=Join-Path $projectRoot ($key+'-ollama-request.json')
    $respFile=Join-Path $projectRoot ($key+'-ollama-response.json')
    $rawFile=Join-Path $projectRoot ($key+'-raw.txt')
    $structuredFile=Join-Path $projectRoot ($key+'-structured.json')
    $metricsFile=Join-Path $projectRoot ($key+'-metrics.json')
    $body=[ordered]@{model=$model;prompt=$prompt;stream=$false;think=$false;options=[ordered]@{num_ctx=[int]$request.context;temperature=[double]$request.temperature;num_predict=[int]$request.num_predict}}
    Write-Json $reqFile $body

    $modelStates[$model]=[ordered]@{attempted=$true;status='running';model=$model;started_at=(Get-Date -Format o);prompt_sha256=$promptHash;context=[int]$request.context;num_predict=[int]$request.num_predict}
    Save-State 'running' $job $modelStates "Ollama POST started for $model; single-flight guard is now irrevocably set."
    [void](Publish-Snapshot $job $request $modelStates 'running')

    $start=Get-Date
    & curl.exe -sS --max-time 10800 -H 'Content-Type: application/json' --data-binary "@$reqFile" -o "$respFile" 'http://127.0.0.1:11434/api/generate'
    $curlExit=$LASTEXITCODE
    $end=Get-Date

    if($curlExit -ne 0){
      $modelStates[$model]=[ordered]@{attempted=$true;status='failed';model=$model;started_at=$modelStates[$model].started_at;finished_at=(Get-Date -Format o);wall_seconds=[math]::Round(($end-$start).TotalSeconds,2);curl_exit=$curlExit;error="Ollama transport failed with curl exit $curlExit"}
      Save-State 'running' $job $modelStates "Model transport failed for $model; no replay permitted."
      [void](Publish-Snapshot $job $request $modelStates 'running')
      [void](Try-Comment "[STATUS][H3-AFZ-BLOG-COMPARE] $model terminal transport failure exit=$curlExit. This call will not be replayed; continuing only with any not-yet-attempted comparison model.")
      continue
    }

    $respText=[IO.File]::ReadAllText($respFile,$utf8)
    $ollama=$respText|ConvertFrom-Json -ErrorAction Stop
    if($ollama.error){
      $modelStates[$model]=[ordered]@{attempted=$true;status='failed';model=$model;wall_seconds=[math]::Round(($end-$start).TotalSeconds,2);error=[string]$ollama.error;finished_at=(Get-Date -Format o)}
      Save-State 'running' $job $modelStates "Ollama returned model error for $model; no replay permitted."
      continue
    }
    $raw=[string]$ollama.response
    Write-Utf8 $rawFile $raw
    $parsed=$null;$jsonValid=$false;$parseError=$null
    try{$parsed=$raw|ConvertFrom-Json -ErrorAction Stop;$jsonValid=$true}catch{$parseError=$_.Exception.Message}
    $validation=$null
    if($jsonValid){$validation=Validate-BlogOutput $parsed $request;Write-Json $structuredFile $parsed}else{$validation=[ordered]@{valid=$false;errors=@('strict-json-parse-failed');article_word_count=0;word_target_met=$false;source_count=0;claim_count=0;review_flag_count=0;keyword_count=0}}
    $outputTps=$null;if($ollama.eval_count -and [double]$ollama.eval_duration -gt 0){$outputTps=[math]::Round([double]$ollama.eval_count/([double]$ollama.eval_duration/1e9),2)}
    $promptTps=$null;if($ollama.prompt_eval_count -and [double]$ollama.prompt_eval_duration -gt 0){$promptTps=[math]::Round([double]$ollama.prompt_eval_count/([double]$ollama.prompt_eval_duration/1e9),2)}
    $metrics=[ordered]@{model=$model;attempted=$true;status='completed';wall_seconds=[math]::Round(($end-$start).TotalSeconds,2);done=[bool]$ollama.done;done_reason=[string]$ollama.done_reason;prompt_tokens=$ollama.prompt_eval_count;prompt_tokens_per_second=$promptTps;output_tokens=$ollama.eval_count;output_tokens_per_second=$outputTps;strict_json_valid=$jsonValid;strict_json_parse_error=$parseError;schema_valid=[bool]$validation.valid;schema_errors=@($validation.errors);article_word_count=[int]$validation.article_word_count;word_target_met=[bool]$validation.word_target_met;source_count=[int]$validation.source_count;claim_count=[int]$validation.claim_count;review_flag_count=[int]$validation.review_flag_count;keyword_count=[int]$validation.keyword_count;prompt_sha256=$promptHash;completed_at=(Get-Date -Format o)}
    Write-Json $metricsFile $metrics
    $modelStates[$model]=$metrics
    Save-State 'running' $job $modelStates "Completed one allowed call for $model."
    $pushed=Publish-Snapshot $job $request $modelStates 'running'
    [void](Try-Comment "[STATUS][H3-AFZ-BLOG-COMPARE] $model call completed: output_tokens=$($metrics.output_tokens) output_tps=$($metrics.output_tokens_per_second) wall_s=$($metrics.wall_seconds) done_reason=$($metrics.done_reason) strict_json=$($metrics.strict_json_valid) schema_valid=$($metrics.schema_valid) article_words=$($metrics.article_word_count) result_push=$pushed")
  }

  $completed=@($models|Where-Object{[string]$modelStates[$_].status -eq 'completed'}).Count
  $blocked=@($models|Where-Object{[string]$modelStates[$_].status -eq 'blocked-no-replay'}).Count
  $failed=@($models|Where-Object{[string]$modelStates[$_].status -eq 'failed'}).Count
  $finalStatus=if($completed -eq $models.Count){'completed'}else{'partial'}
  Save-State $finalStatus $job $modelStates "Benchmark finished with completed=$completed blocked=$blocked failed=$failed."
  $final=[ordered]@{schema=1;project='afz-blog-local-model-comparison';job_id=$job;status=$finalStatus;source_sha=$SourceSha;host=$env:COMPUTERNAME;project_root=$projectRoot;prompt_sha256=$promptHash;topic=[string]$request.topic;publish_article=$false;production_db_mutation=$false;completed_models=$completed;blocked_models=$blocked;failed_models=$failed;models=$modelStates;completed_at=(Get-Date -Format o)}
  Write-Json (Join-Path $projectRoot 'summary.json') $final
  $pushed=Publish-Snapshot $job $request $modelStates $finalStatus
  [void](Try-Comment "[RESULT][H3-AFZ-BLOG-COMPARE] Job $job status=$finalStatus completed_models=$completed/2 blocked=$blocked failed=$failed publish=false db_mutation=false result_push=$pushed. Raw outputs and metrics are preserved on h3-direct-results for blind scoring.")
  Write-Output ('AFZ_BLOG_COMPARE_JSON='+($final|ConvertTo-Json -Depth 50 -Compress))
  if($finalStatus -ne 'completed'){exit 20}
  exit 0
}catch{
  $msg=$_.Exception.Message
  try{
    if(-not $job){$job='afz-blog-qwen35b-vs-ridge27b-20260902-r1'}
    if(-not $modelStates){$modelStates=[ordered]@{}}
    Save-State 'failed' $job $modelStates $msg
    [void](Try-Comment "[BLOCKED][H3-AFZ-BLOG-COMPARE] Job $job runner failure: $msg No attempted model call will be replayed automatically.")
  }catch{}
  Write-Error $msg
  exit 20
}
