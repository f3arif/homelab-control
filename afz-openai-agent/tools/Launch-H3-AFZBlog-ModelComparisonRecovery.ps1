#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only recovery launcher; host=$env:COMPUTERNAME"}
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha must be 40-char SHA.'}
if($JobId -ne 'afz-blog-qwen35b-vs-ridge27b-20260902-r1'){throw 'Unexpected job id.'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()

$root='C:\ProgramData\AFZ\H3AFZBlogModelComparison'
$projectRoot='C:\Projects\AFZ-Blog-Model-Comparison-20260902-r1'
$stateFile=Join-Path $root 'state.json'
$runner=Join-Path $root 'Recover-H3-AFZBlog-ModelComparison.ps1'
$wrapper=Join-Path $root 'Invoke-AFZBlog-Recovery-Interactive.ps1'
$stdout=Join-Path $root 'recovery.stdout.log'
$stderr=Join-Path $root 'recovery.stderr.log'
$qwenSaved=Join-Path $projectRoot 'qwen35b-a3b-ollama-response.json'
$ridgeSaved=Join-Path $projectRoot 'ridge27b-16k-ollama-response.json'
$url="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/Recover-H3-AFZBlog-ModelComparison.ps1"
$taskName='AFZ H3 AFZ Blog Comparison Recovery'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root|Out-Null

function Emit($o){[Console]::Out.WriteLine(($o|ConvertTo-Json -Depth 20 -Compress))}
function Read-State {
  if(-not(Test-Path -LiteralPath $stateFile -PathType Leaf)){return $null}
  try{return [IO.File]::ReadAllText($stateFile)|ConvertFrom-Json}catch{return $null}
}
function Get-ModelState($State,[string]$Model){
  if(-not $State -or -not($State.PSObject.Properties.Name -contains 'models')){return $null}
  foreach($p in $State.models.PSObject.Properties){if([string]$p.Name -eq $Model){return $p.Value}}
  return $null
}
function Tail([string]$Path){if(Test-Path -LiteralPath $Path){return ((Get-Content -LiteralPath $Path -Tail 30 -ErrorAction SilentlyContinue)-join "`n")};return ''}

# Fail closed before changing the scheduled task. The protected 35B response must
# exist; Ridge must still be unattempted; and no Ridge response may already exist.
$preState=Read-State
if(-not $preState){throw 'H3 recovery state missing; refusing launch.'}
$qwenState=Get-ModelState $preState 'qwen3.6:35b-a3b'
$ridgeState=Get-ModelState $preState 'qwen3.8-ridge:27b-16k'
if(-not $qwenState -or -not [bool]$qwenState.attempted){throw '35B attempted-state proof missing; refusing recovery.'}
if(-not(Test-Path -LiteralPath $qwenSaved -PathType Leaf)){throw 'Protected 35B saved response missing; refusing recovery.'}
if($ridgeState -and [bool]$ridgeState.attempted){
  Emit ([ordered]@{ok=$true;already=$true;status=[string]$ridgeState.status;job_id=$JobId;expected_sha=$ExpectedSha;ridge_attempted=$true;modelReplay35B=$false})
  exit 0
}
if(Test-Path -LiteralPath $ridgeSaved -PathType Leaf){throw 'Ridge saved response exists while state says unattempted; refusing launch.'}

# Read-only Ollama readiness check. Do not consume the single Ridge attempt if the
# local inference service or requested model is not ready.
try{
  $tags=Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 8 -ErrorAction Stop
}catch{throw ('Ollama readiness check failed before Ridge attempt: '+$_.Exception.Message)}
$modelNames=@($tags.models|ForEach-Object{[string]$_.name})
if($modelNames -notcontains 'qwen3.8-ridge:27b-16k'){throw 'Required Ridge model qwen3.8-ridge:27b-16k is not loaded/available in Ollama; refusing launch.'}

$tmp=Join-Path $env:TEMP ('afz-blog-recovery-'+[guid]::NewGuid().ToString('N')+'.ps1')
try{
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-Blog-Recovery';'Cache-Control'='no-cache'} -TimeoutSec 60
  $text=[IO.File]::ReadAllText($tmp)
  $needle='$utf8=New-Object Text.UTF8Encoding($false)'
  if(-not $text.Contains($needle)){throw 'Recovery compatibility patch anchor missing.'}
  $text=$text.Replace($needle,$needle+"`r`n`$script:gh=`$null")

  # Windows PowerShell treats $Args as the automatic unbound-argument variable.
  # Rename the explicit GitHub CLI argument parameter in the downloaded recovery
  # script so Start-Process never receives a null/empty -ArgumentList collision.
  # GitHub publication is disabled for this recovery pass; H3 local state plus the
  # external read-only mirror are the authoritative execution evidence.
  $invokeNeedle='function Invoke-Gh([string[]]$Args)'
  if(-not $text.Contains($invokeNeedle)){throw 'Recovery Invoke-Gh compatibility anchor missing.'}
  $text=$text.Replace($invokeNeedle,'function Invoke-Gh([string[]]$GhArgs)')
  $argsNeedle='($Args|ForEach-Object{Quote-Arg ([string]$_)})'
  if(-not $text.Contains($argsNeedle)){throw 'Recovery Invoke-Gh argument-use anchor missing.'}
  $text=$text.Replace($argsNeedle,'($GhArgs|ForEach-Object{Quote-Arg ([string]$_)})')
  $ghInitNeedle='$script:gh=Find-Gh'
  if(-not $text.Contains($ghInitNeedle)){throw 'Recovery GitHub init anchor missing.'}
  $text=$text.Replace($ghInitNeedle,'$script:gh=$null')

  [IO.File]::WriteAllText($tmp,$text,$utf8)
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)
  if($errors.Count -gt 0){throw ('Recovery script parse failure: '+($errors.Message -join '; '))}
  [IO.File]::WriteAllText($runner,[IO.File]::ReadAllText($tmp),$utf8)
}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}

$existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($existing -and $existing.State -eq 'Running'){
  $live=Read-State;$liveRidge=Get-ModelState $live 'qwen3.8-ridge:27b-16k'
  if($liveRidge -and [bool]$liveRidge.attempted){Emit ([ordered]@{ok=$true;already=$true;job_id=$JobId;status=[string]$liveRidge.status;task=$taskName;ridge_attempted=$true;modelReplay35B=$false});exit 0}
  throw "$taskName is already Running without Ridge attempted-state proof; refusing a second launch."
}

Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue
$wrapperText=@"
#Requires -Version 5.1
`$ErrorActionPreference='Stop'
try {
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '$runner' -SourceSha '$ExpectedSha' -JobId '$JobId' 1> '$stdout' 2> '$stderr'
  exit `$LASTEXITCODE
} catch {
  (`$_|Out-String)|Add-Content -LiteralPath '$stderr' -Encoding UTF8
  exit 1
}
"@
[IO.File]::WriteAllText($wrapper,$wrapperText,$utf8)
$tokens=$null;$errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($wrapper,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ('Wrapper parse failure: '+($errors.Message -join '; '))}

$userId=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
if([string]::IsNullOrWhiteSpace($userId) -or $userId -notmatch '\\'){throw "Unable to resolve H3 user identity: $userId"}
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$wrapper`""
$principal=New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force|Out-Null
$beforeInfo=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
$beforeLastRun=$(if($beforeInfo){$beforeInfo.LastRunTime}else{[datetime]::MinValue})
$launchAt=Get-Date
Start-ScheduledTask -TaskName $taskName

# Do not equate a task returning to Ready with success. Require durable H3 state
# proving the one Ridge attempt has actually started. This mirrors the proven
# Ridge16K website launch protocol.
$deadline=(Get-Date).AddSeconds(40)
do{
  Start-Sleep -Milliseconds 500
  $state=Read-State
  $rs=Get-ModelState $state 'qwen3.8-ridge:27b-16k'
  if($rs -and [bool]$rs.attempted){
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Emit ([ordered]@{ok=$true;already=$false;job_id=$JobId;status=[string]$rs.status;ridge_attempted=$true;task=$taskName;task_state=$(if($task){[string]$task.State}else{$null});expected_sha=$ExpectedSha;principal=$userId;execution_context='h3-interactive-user';modelReplay35B=$false})
    exit 0
  }
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  $info=$(if($task){Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue}else{$null})
  if($task -and $task.State -ne 'Running' -and (Get-Date) -gt $launchAt.AddSeconds(5)){
    $advanced=($info -and $info.LastRunTime -gt $beforeLastRun)
    throw "Recovery task ended/did not start before Ridge launch proof. state=$($task.State) lastRunAdvanced=$advanced lastRun=$($info.LastRunTime) lastResult=$($info.LastTaskResult) stderr=$(Tail $stderr) stdout=$(Tail $stdout)"
  }
}while((Get-Date) -lt $deadline)

$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$info=$(if($task){Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue}else{$null})
throw "Recovery task did not publish Ridge attempted-state within 40 seconds. taskState=$(if($task){[string]$task.State}else{'missing'}) lastRun=$(if($info){$info.LastRunTime}else{$null}) lastResult=$(if($info){$info.LastTaskResult}else{$null}) stderr=$(Tail $stderr) stdout=$(Tail $stdout)"
