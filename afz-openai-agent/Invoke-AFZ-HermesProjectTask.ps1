#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control'
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$expectedHost='DESKTOP-10SKF0M'
$stateRoot='C:\ProgramData\AFZ\ProjectExecution'
$pendingFile=Join-Path $stateRoot 'pending.json'
$resultFile=Join-Path $stateRoot 'result.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Get-Prop($Object,[string]$Name,$Default=$null){
  if($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name){return $Object.$Name}
  return $Default
}
function Read-JsonFile([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return $null}
}
function Limit-Text([string]$Text,[int]$MaxChars=96000){
  if([string]::IsNullOrEmpty($Text)){return ''}
  if($Text.Length -le $MaxChars){return $Text}
  return '[TRUNCATED_TO_LAST_'+$MaxChars+'_CHARS]'+[Environment]::NewLine+$Text.Substring($Text.Length-$MaxChars)
}
function Write-Result($Object){
  $json=$Object|ConvertTo-Json -Depth 24 -Compress
  [IO.File]::WriteAllText($resultFile,$json,$utf8)
  Write-Output $json
}
function Get-GitPath {
  foreach($name in @('git.exe','git')){
    $c=Get-Command $name -ErrorAction SilentlyContinue|Select-Object -First 1
    if($c){if($c.Path){return [string]$c.Path};if($c.Source){return [string]$c.Source}}
  }
  return $null
}
function Get-GitSnapshot([string]$Root){
  $o=[ordered]@{isGit=$false;head=$null;branch=$null;status=$null;dirty=$null}
  try{
    $git=Get-GitPath;if(-not $git){return $o}
    $inside=(& $git -C $Root rev-parse --is-inside-work-tree 2>$null|Out-String).Trim()
    if($LASTEXITCODE -ne 0 -or $inside -ne 'true'){return $o}
    $o.isGit=$true
    $o.head=(& $git -C $Root rev-parse HEAD 2>$null|Out-String).Trim()
    $o.branch=(& $git -C $Root branch --show-current 2>$null|Out-String).Trim()
    $o.status=(& $git -C $Root status --porcelain=v1 -b 2>$null|Out-String).Trim()
    $o.dirty=([bool]($o.status -split "`r?`n"|Where-Object{$_ -and $_ -notmatch '^##'}))
  }catch{}
  return $o
}
function Find-Hermes {
  foreach($name in @('hermes.exe','hermes')){
    try{
      $c=Get-Command $name -ErrorAction SilentlyContinue|Select-Object -First 1
      if($c){if($c.Path){return [string]$c.Path};if($c.Source){return [string]$c.Source}}
    }catch{}
  }
  foreach($p in @(
    (Join-Path $env:USERPROFILE '.local\bin\hermes.exe'),
    (Join-Path $env:LOCALAPPDATA 'AFZ\Hermes\bin\hermes.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Hermes\hermes.exe'),
    (Join-Path $env:APPDATA 'Python\Scripts\hermes.exe')
  )){if(Test-Path -LiteralPath $p -PathType Leaf){return $p}}
  return $null
}
function Test-SafeProjectRoot([string]$Root){
  if([string]::IsNullOrWhiteSpace($Root)){return $false}
  if($Root -match "['\"`r`n]" -or $Root -match '(^|[\\/])[.][.]([\\/]|$)'){return $false}
  if($Root -notmatch '^[A-Za-z]:\\'){return $false}
  $full=[IO.Path]::GetFullPath($Root).TrimEnd('\')
  foreach($blocked in @('C:\Windows','C:\Program Files','C:\Program Files (x86)','C:\ProgramData','C:\Users\Faiz\.ssh','C:\Users\Faiz\.hermes')){
    if($full.Equals($blocked,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($blocked+'\',[StringComparison]::OrdinalIgnoreCase)){return $false}
  }
  return $true
}
function Quote-Arg([string]$Value){
  if($Value -notmatch '[\s"]'){return $Value}
  return '"'+$Value.Replace('"','\"')+'"'
}
function Invoke-BoundedProcess([string]$File,[string[]]$Arguments,[string]$WorkingDirectory,[int]$TimeoutSeconds,[string]$Tag){
  $out=Join-Path $stateRoot ($Tag+'.out.log');$err=Join-Path $stateRoot ($Tag+'.err.log')
  Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue
  $argLine=($Arguments|ForEach-Object{Quote-Arg ([string]$_)}) -join ' '
  $p=Start-Process -FilePath $File -ArgumentList $argLine -WorkingDirectory $WorkingDirectory -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
  if(-not $p.WaitForExit($TimeoutSeconds*1000)){
    try{Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue}catch{}
    return [ordered]@{ok=$false;exit=$null;timeout=$true;stdout=(Limit-Text $(if(Test-Path $out){[IO.File]::ReadAllText($out)}else{''}));stderr=(Limit-Text $(if(Test-Path $err){[IO.File]::ReadAllText($err)}else{''}) 32000)}
  }
  return [ordered]@{ok=([int]$p.ExitCode -eq 0);exit=[int]$p.ExitCode;timeout=$false;stdout=(Limit-Text $(if(Test-Path $out){[IO.File]::ReadAllText($out)}else{''}));stderr=(Limit-Text $(if(Test-Path $err){[IO.File]::ReadAllText($err)}else{''}) 32000)}
}
function New-HermesPrompt($Request){
  $requestId=[string](Get-Prop $Request 'request_id' '')
  $project=[string](Get-Prop $Request 'project' 'unknown')
  $root=[string](Get-Prop $Request 'project_root' '')
  $resume=[string](Get-Prop $Request 'resume_key' '')
  $note=[string](Get-Prop $Request 'cross_chat_note' '')
  $task=[string](Get-Prop $Request 'task' '')
  return @"
AFZ PROJECT TASK
REQUEST_ID: $requestId
PROJECT: $project
PROJECT_ROOT: $root
RESUME_KEY: $resume
CROSS_CHAT_NOTE: $note

You are operating inside a guarded AFZ project-edit lane.

RULES:
- Complete the requested source/config/document edits as far as safely possible now.
- Preserve all existing user work. Never reset, clean, discard, or overwrite unrelated dirty-worktree changes.
- Never force-push, delete repositories, extract credentials, or perform irreversible/destructive operations.
- File writes/patches must remain inside PROJECT_ROOT. Do not edit Hermes configuration, credentials, SSH files, ProgramData, or other projects.
- Terminal/process tools are intentionally unavailable in this lane. Do not try to bypass that restriction.
- Use existing project instructions and skills when useful.
- Keep changes minimal and targeted; inspect before editing and re-read changed files after editing.
- The wrapper will run fixed validation commands after you finish, so do not claim tests/builds passed unless you actually have evidence from file-level checks.
- Existing dirty worktrees must be preserved and continued, not restarted.
- End with: STATUS, VERIFIED, BLOCKER, NEXT, RESUME KEY, CHANGED FILES.

TASK:
$task
"@
}
function Invoke-Validation([string]$Profile,[string]$Root,[int]$TimeoutSeconds){
  if([string]::IsNullOrWhiteSpace($Profile) -or $Profile -eq 'none'){return [ordered]@{ok=$true;profile='none';steps=@()}}
  $steps=@();$ok=$true
  if($Profile -eq 'git-status'){
    $git=Get-GitPath;if(-not $git){return [ordered]@{ok=$false;profile=$Profile;error='git missing';steps=@()}}
    $r=Invoke-BoundedProcess $git @('-C',$Root,'status','--short','--branch') $Root ([math]::Min($TimeoutSeconds,120)) 'validate-git-status';$steps+=,$r;$ok=[bool]$r.ok
  }elseif($Profile -eq 'android'){
    $gradle=Join-Path $Root 'gradlew.bat';if(-not(Test-Path -LiteralPath $gradle -PathType Leaf)){return [ordered]@{ok=$false;profile=$Profile;error='gradlew.bat missing';steps=@()}}
    foreach($args in @(@('test'),@('lint'))){$r=Invoke-BoundedProcess $gradle $args $Root $TimeoutSeconds ('validate-android-'+$args[0]);$steps+=,$r;if(-not $r.ok){$ok=$false;break}}
  }elseif($Profile -eq 'dotnet'){
    $dotnet=(Get-Command dotnet.exe -ErrorAction SilentlyContinue|Select-Object -First 1);if(-not $dotnet){return [ordered]@{ok=$false;profile=$Profile;error='dotnet missing';steps=@()}}
    $dp=$(if($dotnet.Path){[string]$dotnet.Path}else{[string]$dotnet.Source});$r=Invoke-BoundedProcess $dp @('test') $Root $TimeoutSeconds 'validate-dotnet';$steps+=,$r;$ok=[bool]$r.ok
  }elseif($Profile -eq 'node'){
    $npm=(Get-Command npm.cmd -ErrorAction SilentlyContinue|Select-Object -First 1);if(-not $npm){return [ordered]@{ok=$false;profile=$Profile;error='npm missing';steps=@()}}
    $np=$(if($npm.Path){[string]$npm.Path}else{[string]$npm.Source});$r=Invoke-BoundedProcess $np @('test','--if-present') $Root $TimeoutSeconds 'validate-node';$steps+=,$r;$ok=[bool]$r.ok
  }elseif($Profile -eq 'python'){
    $python=(Get-Command python.exe -ErrorAction SilentlyContinue|Select-Object -First 1);if(-not $python){$python=Get-Command python -ErrorAction SilentlyContinue|Select-Object -First 1};if(-not $python){return [ordered]@{ok=$false;profile=$Profile;error='python missing';steps=@()}}
    $pp=$(if($python.Path){[string]$python.Path}else{[string]$python.Source});$r=Invoke-BoundedProcess $pp @('-m','pytest','-q') $Root $TimeoutSeconds 'validate-python';$steps+=,$r;$ok=[bool]$r.ok
  }else{return [ordered]@{ok=$false;profile=$Profile;error='unsupported validation profile';steps=@()}}
  return [ordered]@{ok=$ok;profile=$Profile;steps=$steps}
}

try{
  if($env:COMPUTERNAME -ne $expectedHost){throw "windows-main-only Hermes project executor; host=$env:COMPUTERNAME"}
  $request=Read-JsonFile $pendingFile;if(-not $request){throw "Pending request missing: $pendingFile"}
  $requestId=[string](Get-Prop $request 'request_id' '')
  if($requestId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid request_id'}
  $root=[string](Get-Prop $request 'project_root' '')
  if(-not(Test-SafeProjectRoot $root)){throw 'project_root is outside the guarded project path policy'}
  if(-not(Test-Path -LiteralPath $root -PathType Container)){
    Write-Result ([ordered]@{schema=1;ok=$false;status='failed';classification='PRE_EXECUTION_PROJECT_ROOT_MISSING';requestId=$requestId;route='hermes';worker='windows-main';mutationStarted=$false;projectRoot=$root;message='Project root does not exist.';time=(Get-Date -Format o)});exit 1
  }
  $hermes=Find-Hermes
  if(-not $hermes){
    Write-Result ([ordered]@{schema=1;ok=$false;status='failed';classification='PRE_EXECUTION_HERMES_CLI_MISSING';requestId=$requestId;route='hermes';worker='windows-main';mutationStarted=$false;projectRoot=$root;message='Hermes CLI not found in user context.';time=(Get-Date -Format o)});exit 1
  }
  $maxTurns=[int](Get-Prop $request 'max_turns' 80);if($maxTurns -lt 1){$maxTurns=1};if($maxTurns -gt 200){$maxTurns=200}
  $timeout=[int](Get-Prop $request 'timeout_seconds' 2700);if($timeout -lt 60){$timeout=60};if($timeout -gt 7200){$timeout=7200}
  $allowWeb=[bool](Get-Prop $request 'allow_web' $false)
  $profile=([string](Get-Prop $request 'validation_profile' 'git-status')).ToLowerInvariant()
  $model=([string](Get-Prop $request 'model' '')).Trim();if($model -and $model -notmatch '^[A-Za-z0-9._:/+\-]{1,160}$'){throw 'Invalid model value'}
  $pre=Get-GitSnapshot $root
  $prompt=New-HermesPrompt $request;$promptFile=Join-Path $stateRoot ('prompt-'+$requestId+'.txt');[IO.File]::WriteAllText($promptFile,$prompt,$utf8)
  $oldSafe=$env:HERMES_WRITE_SAFE_ROOT;$oldDelay=$env:HERMES_HUMAN_DELAY_MODE;$oldMax=$env:HERMES_MAX_ITERATIONS
  $env:HERMES_WRITE_SAFE_ROOT=$root
  $env:HERMES_HUMAN_DELAY_MODE='off'
  $env:HERMES_MAX_ITERATIONS=[string]$maxTurns
  $toolsets=$(if($allowWeb){'file,skills,web'}else{'file,skills'})
  $args=@('chat','--oneshot','--checkpoints','--pass-session-id','--source','tool','--max-turns',[string]$maxTurns,'--toolsets',$toolsets,'--query-file',$promptFile)
  if($model){$args+=@('--model',$model)}
  $mutationStarted=$false
  try{
    $mutationStarted=$true
    $hermesResult=Invoke-BoundedProcess $hermes $args $root $timeout ('hermes-'+$requestId)
  }finally{
    $env:HERMES_WRITE_SAFE_ROOT=$oldSafe;$env:HERMES_HUMAN_DELAY_MODE=$oldDelay;$env:HERMES_MAX_ITERATIONS=$oldMax
    Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
  }
  $postHermes=Get-GitSnapshot $root
  if(-not $hermesResult.ok){
    Write-Result ([ordered]@{schema=1;ok=$false;status='failed';classification=$(if($hermesResult.timeout){'HERMES_TIMEOUT_AFTER_EXECUTION_STARTED'}else{'HERMES_EXIT_NONZERO_AFTER_EXECUTION_STARTED'});requestId=$requestId;route='hermes';worker='windows-main';mutationStarted=$true;projectRoot=$root;preGit=$pre;postGit=$postHermes;hermes=$hermesResult;message='Hermes edit lane did not complete cleanly; review live worktree before any fallback executor runs.';time=(Get-Date -Format o)});exit 1
  }
  $validation=Invoke-Validation $profile $root $timeout
  $post=Get-GitSnapshot $root
  $ok=[bool]$validation.ok
  Write-Result ([ordered]@{schema=1;ok=$ok;status=$(if($ok){'completed'}else{'validation_failed'});classification=$(if($ok){'HERMES_EDIT_AND_VALIDATION_COMPLETED'}else{'HERMES_EDIT_COMPLETED_VALIDATION_FAILED'});requestId=$requestId;route='hermes';worker='windows-main';mutationStarted=$mutationStarted;projectRoot=$root;toolsets=$toolsets;model=$(if($model){$model}else{$null});preGit=$pre;postHermesGit=$postHermes;postGit=$post;hermes=$hermesResult;validation=$validation;resumeKey=[string](Get-Prop $request 'resume_key' '');message=$(if($ok){'Hermes project edit and fixed validation completed.'}else{'Hermes edits completed but validation failed; do not switch executors until the worktree is reviewed.'});time=(Get-Date -Format o)})
  if($ok){exit 0}else{exit 2}
}catch{
  $rid='unknown';try{if($request){$rid=[string](Get-Prop $request 'request_id' 'unknown')}}catch{}
  Write-Result ([ordered]@{schema=1;ok=$false;status='failed';classification='PRE_EXECUTION_WRAPPER_EXCEPTION';requestId=$rid;route='hermes';worker='windows-main';mutationStarted=$false;message=$_.Exception.Message;time=(Get-Date -Format o)})
  exit 1
}
