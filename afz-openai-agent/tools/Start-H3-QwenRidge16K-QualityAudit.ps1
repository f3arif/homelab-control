#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId,
  [string]$RequestPath='afz-openai-agent/requests/h3-qwenridge16k-quality-audit.json'
)

$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only QA runner; host=$env:COMPUTERNAME"}
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha must be a 40-character commit SHA.'}
if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid JobId.'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()

$repo='f3arif/homelab-control'
$controlRepo='f3arif/faiz-homelab'
$controlIssue=12
$resultBranch='h3-direct-results'
$stateRoot='C:\ProgramData\AFZ\H3QwenRidge16KQA'
$stateFile=Join-Path $stateRoot ($JobId+'.json')
$outRoot=Join-Path $stateRoot $JobId
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot,$outRoot|Out-Null

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
function Write-Utf8([string]$Path,[string]$Text){
  $parent=Split-Path -Parent $Path
  if($parent -and -not(Test-Path $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
  [IO.File]::WriteAllText($Path,$Text,$utf8)
}
function Write-Json([string]$Path,$Object){Write-Utf8 $Path ($Object|ConvertTo-Json -Depth 40 -Compress)}
function Save-State([string]$Status,[string]$Phase,[string]$Message,$Extra=$null){
  $o=[ordered]@{schema=1;job_id=$JobId;status=$Status;phase=$Phase;message=$Message;expected_sha=$ExpectedSha;host=$env:COMPUTERNAME;model_calls_issued=0;site_mutation_allowed=$false;updated_at=(Get-Date -Format o)}
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  Write-Json $stateFile $o
  return $o
}
function Get-ContentAt([string]$Path,[string]$Ref){
  $r=Invoke-Gh -Arguments @('api',"repos/$repo/contents/${Path}?ref=${Ref}")
  $j=($r.Output -join "`n")|ConvertFrom-Json
  if([string]$j.encoding -ne 'base64' -or [string]::IsNullOrWhiteSpace([string]$j.content)){throw "Invalid GitHub content response for $Path@$Ref"}
  return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((([string]$j.content)-replace '\s','')))
}
function Publish-File([string]$LocalPath,[string]$RemotePath,[string]$Message){
  if(-not(Test-Path -LiteralPath $LocalPath -PathType Leaf)){throw "Publish source missing: $LocalPath"}
  $payload=[ordered]@{message=$Message;content=[Convert]::ToBase64String([IO.File]::ReadAllBytes($LocalPath));branch=$resultBranch}
  $existing=Invoke-Gh -Arguments @('api',"repos/$repo/contents/${RemotePath}?ref=${resultBranch}",'--jq','.sha') -AllowFailure
  if($existing.ExitCode -eq 0){$sha=([string]($existing.Output -join '')).Trim();if($sha -match '^[0-9a-f]{40}$'){$payload.sha=$sha}}
  $tmp=Join-Path $env:TEMP ('afz-ridgeqa-publish-'+[guid]::NewGuid().ToString('N')+'.json')
  try{
    Write-Utf8 $tmp ($payload|ConvertTo-Json -Depth 8 -Compress)
    $put=Invoke-Gh -Arguments @('api','--method','PUT',"repos/$repo/contents/$RemotePath",'--input',$tmp) -AllowFailure
    if($put.ExitCode -ne 0){throw "GitHub publish failed: $RemotePath"}
  }finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
}
function Comment([string]$Body){[void](Invoke-Gh -Arguments @('issue','comment',[string]$controlIssue,'--repo',$controlRepo,'--body',$Body) -AllowFailure)}
function Get-FreePort {
  $l=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
  $l.Start();try{return ([Net.IPEndPoint]$l.LocalEndpoint).Port}finally{$l.Stop()}
}
function Get-SiteFingerprint([string]$Root){
  $files=@()
  foreach($name in @('package.json','tsconfig.json','next.config.js','next.config.mjs','next-env.d.ts','.eslintrc.json')){
    $p=Join-Path $Root $name
    if(Test-Path -LiteralPath $p -PathType Leaf){$files+=Get-Item -LiteralPath $p}
  }
  $src=Join-Path $Root 'src'
  if(Test-Path -LiteralPath $src -PathType Container){$files+=@(Get-ChildItem -LiteralPath $src -Recurse -File|Sort-Object FullName)}
  $rows=@()
  foreach($f in $files){
    $rel=$f.FullName.Substring($Root.TrimEnd('\').Length).TrimStart('\').Replace('\','/')
    $h=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $rows+="$rel|$h"
  }
  $joined=$rows -join "`n"
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$digest=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($joined))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
  [pscustomobject]@{digest=$digest;files=$rows.Count;rows=$rows}
}
function Find-Edge {
  foreach($p in @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe','C:\Program Files\Microsoft\Edge\Application\msedge.exe')){if(Test-Path -LiteralPath $p -PathType Leaf){return $p}}
  $c=Get-Command msedge.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  return $null
}
function Capture-Screenshot([string]$Edge,[string]$Url,[string]$Path,[int]$Width,[int]$Height){
  $profile=Join-Path $env:TEMP ('afz-ridgeqa-edge-'+[guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $profile|Out-Null
  try{
    $args=@('--headless=new','--disable-gpu','--hide-scrollbars','--run-all-compositor-stages-before-draw',"--window-size=$Width,$Height",("--user-data-dir="+$profile),("--screenshot="+$Path),$Url)
    $p=Start-Process -FilePath $Edge -ArgumentList $args -PassThru -Wait -NoNewWindow
    if($p.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -lt 1000){throw "Edge screenshot failed exit=$($p.ExitCode) path=$Path"}
  }finally{Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction SilentlyContinue}
}

$prior=$null
if(Test-Path -LiteralPath $stateFile -PathType Leaf){try{$prior=Get-Content -LiteralPath $stateFile -Raw|ConvertFrom-Json}catch{}}
if($prior -and [string]$prior.status -in @('running','completed')){
  Write-Output ($prior|ConvertTo-Json -Depth 30 -Compress)
  exit 0
}

$script:gh=Find-Gh
if(-not $gh){throw 'GitHub CLI not found on H3.'}
$auth=Invoke-Gh -Arguments @('auth','status','--hostname','github.com') -AllowFailure
if($auth.ExitCode -ne 0){throw 'GitHub CLI authentication is not valid on H3.'}

$req=(Get-ContentAt $RequestPath $ExpectedSha)|ConvertFrom-Json
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'qwenridge16k-readonly-quality-audit'){throw 'QA request schema/project mismatch.'}
if([string]$req.job_id -ne $JobId){throw 'QA request job id mismatch.'}
if([string]$req.source_job_id -ne 'qwenridge16k-afz-website-20260902-r2'){throw 'Unexpected source benchmark job.'}
if([string]$req.project_root -ne 'C:\Projects\Qwen38-Ridge16K-AFZ-Website-Test-20260902-r2'){throw 'Unexpected QA project root.'}
if(-not [bool]$req.no_model_calls -or [bool]$req.site_mutation_allowed){throw 'QA safety contract invalid.'}
$routes=@($req.required_routes|ForEach-Object {[string]$_})
$expectedRoutes=@('/','/services','/projects','/about','/contact')
if($routes.Count -ne $expectedRoutes.Count){throw 'QA route contract mismatch.'}
foreach($route in $expectedRoutes){if($routes -notcontains $route){throw "QA route missing: $route"}}
$root=[string]$req.project_root
if(-not(Test-Path -LiteralPath $root -PathType Container)){throw "Frozen r2 project root missing: $root"}
if(-not(Test-Path -LiteralPath (Join-Path $root '.next') -PathType Container)){throw 'Frozen r2 build output .next is missing.'}

$before=Get-SiteFingerprint $root
[void](Save-State 'running' 'preflight' 'Read-only quality audit preflight passed.' ([pscustomobject]@{project_root=$root;fingerprint_before=$before.digest;tracked_files=$before.files}))
Comment "[STATUS][H3-RIDGE16K-QA] Job $JobId started on frozen Ridge r2 output. Read-only capture only; model calls=0; site mutation allowed=false."

$edge=Find-Edge
if(-not $edge){throw 'Microsoft Edge not found for screenshot capture.'}
$port=Get-FreePort
$serverOut=Join-Path $outRoot 'server.stdout.log'
$serverErr=Join-Path $outRoot 'server.stderr.log'
$server=$null
try{
  $server=Start-Process -FilePath 'npm.cmd' -ArgumentList @('start','--','-H','127.0.0.1','-p',[string]$port) -WorkingDirectory $root -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr -PassThru -NoNewWindow
  $ready=$false
  for($i=0;$i -lt 45;$i++){
    Start-Sleep -Seconds 1
    try{$r=Invoke-WebRequest -Uri "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 3;if([int]$r.StatusCode -eq 200){$ready=$true;break}}catch{}
    if($server.HasExited){break}
  }
  if(-not $ready){throw "Frozen r2 site did not become ready on local port $port"}
  [void](Save-State 'running' 'capture' 'Local frozen site is ready; capturing HTML and screenshots.' ([pscustomobject]@{project_root=$root;port=$port;fingerprint_before=$before.digest}))

  $routeRows=@()
  $routeNames=@{'/'='home';'/services'='services';'/projects'='projects';'/about'='about';'/contact'='contact'}
  foreach($route in $expectedRoutes){
    $name=[string]$routeNames[$route]
    $url="http://127.0.0.1:$port$route"
    $resp=Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15
    $htmlPath=Join-Path $outRoot ($name+'.html')
    Write-Utf8 $htmlPath ([string]$resp.Content)
    $desktop=Join-Path $outRoot ($name+'-desktop.png')
    $mobile=Join-Path $outRoot ($name+'-mobile.png')
    Capture-Screenshot $edge $url $desktop 1440 1200
    Capture-Screenshot $edge $url $mobile 390 844
    $routeRows+=[pscustomobject]@{route=$route;http=[int]$resp.StatusCode;bytes=[int]$resp.Content.Length;html=[IO.Path]::GetFileName($htmlPath);desktop=[IO.Path]::GetFileName($desktop);mobile=[IO.Path]::GetFileName($mobile)}
  }

  $after=Get-SiteFingerprint $root
  $unchanged=($before.digest -eq $after.digest)
  if(-not $unchanged){throw "Frozen r2 source fingerprint changed during read-only QA: before=$($before.digest) after=$($after.digest)"}

  $sourceFiles=[ordered]@{
    'header.tsx'='src\components\Header.tsx'
    'footer.tsx'='src\components\Footer.tsx'
    'contact-form.tsx'='src\components\ContactForm.tsx'
    'home-page.tsx'='src\app\page.tsx'
    'services-page.tsx'='src\app\services\page.tsx'
    'projects-page.tsx'='src\app\projects\page.tsx'
    'about-page.tsx'='src\app\about\page.tsx'
    'contact-page.tsx'='src\app\contact\page.tsx'
    'layout.tsx'='src\app\layout.tsx'
    'globals.css'='src\app\globals.css'
  }
  $publishPrefix='afz-openai-agent/results/qwenridge16k-r2-qa01'
  foreach($row in $routeRows){
    foreach($file in @($row.html,$row.desktop,$row.mobile)){
      Publish-File (Join-Path $outRoot $file) ($publishPrefix+'/'+$file) ("Ridge16K r2 QA artifact $file")
    }
  }
  foreach($entry in $sourceFiles.GetEnumerator()){
    $src=Join-Path $root ([string]$entry.Value)
    if(Test-Path -LiteralPath $src -PathType Leaf){Publish-File $src ($publishPrefix+'/source/'+[string]$entry.Key) ("Ridge16K r2 frozen source evidence "+[string]$entry.Key)}
  }

  $summary=[ordered]@{
    schema=1
    project='qwenridge16k-readonly-quality-audit'
    job_id=$JobId
    source_job_id=[string]$req.source_job_id
    status='PASS'
    expected_sha=$ExpectedSha
    host=$env:COMPUTERNAME
    project_root=$root
    model_calls_issued=0
    site_mutation_allowed=$false
    site_mutation_detected=$false
    fingerprint_before=$before.digest
    fingerprint_after=$after.digest
    tracked_files=$before.files
    edge=$edge
    routes=$routeRows
    screenshots=($routeRows.Count*2)
    html_captures=$routeRows.Count
    completed_at=(Get-Date -Format o)
  }
  $summaryPath=Join-Path $outRoot 'summary.json'
  Write-Json $summaryPath $summary
  Publish-File $summaryPath ($publishPrefix+'/summary.json') 'Publish Ridge16K r2 read-only QA summary'
  $final=Save-State 'completed' 'complete' 'Read-only quality audit captured and published successfully.' ([pscustomobject]@{result_status='PASS';project_root=$root;fingerprint_before=$before.digest;fingerprint_after=$after.digest;site_mutation_detected=$false;published_prefix=$publishPrefix;screenshots=($routeRows.Count*2);html_captures=$routeRows.Count})
  Comment "[RESULT][H3-RIDGE16K-QA] Job $JobId status=PASS routes=5/5 screenshots=$($routeRows.Count*2) html=$($routeRows.Count) model_calls=0 site_mutation_detected=false fingerprint=$($before.digest) result_branch_push=True"
  Write-Output ($final|ConvertTo-Json -Depth 30 -Compress)
}catch{
  $msg=$_.Exception.Message
  $failed=Save-State 'failed' 'error' $msg ([pscustomobject]@{project_root=$root;fingerprint_before=$before.digest})
  Comment "[BLOCKED][H3-RIDGE16K-QA] Job $JobId failed safely: $msg. No model call is permitted by this QA job."
  Write-Error $msg
  exit 1
}finally{
  if($server){try{& taskkill.exe /PID $server.Id /T /F *> $null}catch{}}
}
