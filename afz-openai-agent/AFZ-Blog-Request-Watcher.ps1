#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalSeconds=5
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$IntervalSeconds=[math]::Max(3,[math]::Min($IntervalSeconds,30))
$requestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\afz-blog-source-control.json'
$h3Runner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-AFZBlog-InplaceAttach.ps1'
$prodRunner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-AFZBlog-ProductionGitAttach.ps1'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-blog-source-control'
$latestPath=Join-Path $stateRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-BLOG-SOURCE-CONTROL-LATEST.txt'
$logRoot='C:\ProgramData\AFZ\OpenAIAgent\logs'
$logPath=Join-Path $logRoot 'afz-blog-request-watcher.log'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot,$logRoot|Out-Null
function Log([string]$m){Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) $m" -Encoding UTF8}
function Save($o){
  $json=$o|ConvertTo-Json -Depth 24
  [IO.File]::WriteAllText($latestPath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
}
function Parse-LastJson([string]$Raw){
  $last=$null
  foreach($line in @($Raw -split "`r?`n"|Where-Object{$_})){try{$last=$line|ConvertFrom-Json}catch{}}
  return $last
}
function Invoke-Runner([string]$Path,[string[]]$Args){
  $out=Join-Path $env:TEMP ('afz-blog-watch-'+[guid]::NewGuid().ToString('n')+'.out')
  $err=Join-Path $env:TEMP ('afz-blog-watch-'+[guid]::NewGuid().ToString('n')+'.err')
  try{
    $p=Start-Process -FilePath 'powershell.exe' -ArgumentList (@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Path)+$Args) -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(300000)){try{$p.Kill()}catch{};throw "Runner timeout: $Path"}
    $stdout=$(if(Test-Path $out){[IO.File]::ReadAllText($out)}else{''})
    $stderr=$(if(Test-Path $err){[IO.File]::ReadAllText($err)}else{''})
    [ordered]@{exit=[int]$p.ExitCode;stdout=$stdout;stderr=$stderr;json=(Parse-LastJson $stdout)}
  }finally{Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue}
}
function Read-Request{
  if(-not(Test-Path -LiteralPath $requestPath -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8|ConvertFrom-Json}catch{Log "REQUEST_PARSE_ERROR $($_.Exception.Message)";return $null}
}
function Terminal-For([string]$Id){
  if(-not(Test-Path -LiteralPath $latestPath -PathType Leaf)){return $false}
  try{
    $s=Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8|ConvertFrom-Json
    return ([string]$s.requestId -eq $Id -and [string]$s.status -in @('completed','blocked','failed'))
  }catch{return $false}
}
function Validate-Request($r){
  if($null -eq $r){return $false}
  if([int]$r.schema -ne 1){return $false}
  if([string]$r.project -ne 'afz-blog'){return $false}
  if([string]$r.action -ne 'cutover-github-source'){return $false}
  if([string]$r.status -ne 'ACTIVE'){return $false}
  if([string]$r.expectedBlogSha -notmatch '^[0-9a-fA-F]{40}$'){return $false}
  if([string]$r.h3Workspace -ne 'C:\AFZ\Workspaces\AFZ-Blog\blog-manager'){return $false}
  if([string]$r.productionRoot -ne 'C:\docker\afz-blog-manager'){return $false}
  if(-not [bool]$r.allowProductionGitAttach){return $false}
  if([bool]$r.allowRestart -or [bool]$r.allowPublish){return $false}
  return $true
}
function Process($r){
  $id=([string]$r.id).Trim();$sha=([string]$r.expectedBlogSha).ToLowerInvariant()
  if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){return}
  if(Terminal-For $id){return}
  foreach($p in @($h3Runner,$prodRunner)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Runner missing: $p"}}
  Save ([ordered]@{schema=1;requestId=$id;status='running';classification='AFZ_BLOG_GITHUB_CUTOVER_RUNNING';expectedBlogSha=$sha;source='github-request';productionModified=$false;serviceRestarted=$false;websitePublished=$false;credentialsEmitted=$false;time=(Get-Date -Format o)})
  Log "START id=$id sha=$sha"

  $h3=Invoke-Runner $h3Runner @('-RequestId',($id+'-h3'),'-ExpectedBlogSha',$sha)
  $hj=$h3.json
  if($null -eq $hj -or -not [bool]$hj.ok -or [string]$hj.classification -notin @('H3_AFZ_BLOG_CHECKOUT_READY','H3_AFZ_BLOG_ALREADY_READY')){
    Save ([ordered]@{schema=1;requestId=$id;status='blocked';classification='AFZ_BLOG_GITHUB_CUTOVER_H3_BLOCKED';expectedBlogSha=$sha;h3Exit=$h3.exit;h3=$hj;productionGitAuditStarted=$false;productionGitAttachStarted=$false;productionModified=$false;serviceRestarted=$false;websitePublished=$false;credentialsEmitted=$false;time=(Get-Date -Format o)})
    Log "BLOCK_H3 id=$id exit=$($h3.exit) classification=$(if($hj){[string]$hj.classification}else{'NO_JSON'})"
    return
  }

  $audit=Invoke-Runner $prodRunner @('-Action','audit','-RequestId',($id+'-production-audit'),'-ExpectedBlogSha',$sha)
  $aj=$audit.json
  if($null -eq $aj -or -not [bool]$aj.ok -or -not [bool]$aj.safeToAttach){
    Save ([ordered]@{schema=1;requestId=$id;status='blocked';classification='AFZ_BLOG_GITHUB_CUTOVER_PRODUCTION_AUDIT_BLOCKED';expectedBlogSha=$sha;h3=$hj;productionAudit=$aj;productionGitAttachStarted=$false;productionModified=$false;serviceRestarted=$false;websitePublished=$false;credentialsEmitted=$false;time=(Get-Date -Format o)})
    Log "BLOCK_PROD_AUDIT id=$id exit=$($audit.exit)"
    return
  }

  $apply=Invoke-Runner $prodRunner @('-Action','apply','-RequestId',($id+'-production-attach'),'-ExpectedBlogSha',$sha)
  $pj=$apply.json
  if($null -eq $pj -or -not [bool]$pj.ok -or [string]$pj.classification -ne 'AFZ_BLOG_PRODUCTION_GIT_ATTACHED'){
    Save ([ordered]@{schema=1;requestId=$id;status='failed';classification='AFZ_BLOG_GITHUB_CUTOVER_PRODUCTION_ATTACH_FAILED';expectedBlogSha=$sha;h3=$hj;productionAudit=$aj;productionAttach=$pj;productionModified=$false;serviceRestarted=$false;websitePublished=$false;credentialsEmitted=$false;time=(Get-Date -Format o)})
    Log "FAIL_PROD_ATTACH id=$id exit=$($apply.exit)"
    return
  }

  Save ([ordered]@{schema=1;requestId=$id;status='completed';classification='AFZ_BLOG_GITHUB_CUTOVER_READY_NO_RESTART';expectedBlogSha=$sha;h3=$hj;productionAudit=$aj;productionAttach=$pj;productionModified=$false;serviceRestarted=$false;websitePublished=$false;credentialsEmitted=$false;time=(Get-Date -Format o)})
  Log "COMPLETE id=$id sha=$sha"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZBlogGitRequestWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "WATCHER_START interval=$IntervalSeconds control=github restart=false publish=false"
  while($true){
    try{$r=Read-Request;if(Validate-Request $r){Process $r}}catch{Log "WATCH_ERROR $($_.Exception.Message)"}
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{if($locked){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
