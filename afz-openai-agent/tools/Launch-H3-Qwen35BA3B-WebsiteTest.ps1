#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId
)

$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only launcher; host=$env:COMPUTERNAME"}
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha must be a 40-character commit SHA.'}
if($JobId -ne 'qwen35b-a3b-website-20260830-r1'){throw "Unexpected 35B benchmark JobId: $JobId"}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()

$root='C:\ProgramData\AFZ\H3Qwen35BA3B'
$runner=Join-Path $root 'Start-H3-Qwen35BA3B-WebsiteTest.ps1'
$wrapper=Join-Path $root 'Invoke-H3-Qwen35BA3B-InteractiveRunner.ps1'
$stateFile=Join-Path $root ($JobId+'.json')
$stdout=Join-Path $root ($JobId+'.stdout.log')
$stderr=Join-Path $root ($JobId+'.stderr.log')
$runnerUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/Start-H3-Qwen35BA3B-WebsiteTest.ps1"
$taskName='AFZ H3 Qwen35B A3B Benchmark'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root|Out-Null

function Emit($o){[Console]::Out.WriteLine(($o|ConvertTo-Json -Depth 20 -Compress))}
function Read-State {
  if(-not(Test-Path -LiteralPath $stateFile -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}
}
function Model-CallProtected($s){
  if(-not $s){return $false}
  if($s.PSObject.Properties.Name -contains 'model_call_attempted' -and [bool]$s.model_call_attempted){return $true}
  return ([string]$s.phase -in @('ollama_post_started','ollama_post_returned','qwen_response_received','files_applied','npm_install','build','smoke','completed'))
}
function Tail([string]$Path){if(Test-Path -LiteralPath $Path){return ((Get-Content -LiteralPath $Path -Tail 30 -ErrorAction SilentlyContinue)-join "`n")};return ''}

$prior=Read-State
if(Model-CallProtected $prior){
  Emit ([ordered]@{ok=$true;already=$true;protected=$true;job_id=$JobId;status=[string]$prior.status;phase=[string]$prior.phase;model_call_attempted=$true;expected_sha=$ExpectedSha;state_file=$stateFile;task=$taskName})
  exit 0
}
if($prior -and [string]$prior.status -eq 'completed'){
  Emit ([ordered]@{ok=$true;already=$true;protected=$true;job_id=$JobId;status='completed';phase=[string]$prior.phase;expected_sha=$ExpectedSha;state_file=$stateFile;task=$taskName})
  exit 0
}

# Download the exact merged runner. The runner itself carries the one-model-call guard.
$tmp=Join-Path $env:TEMP ('AFZ-H3-Qwen35BA3B-'+[guid]::NewGuid().ToString('N')+'.ps1')
try{
  Invoke-WebRequest -Uri $runnerUrl -OutFile $tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-Qwen35BA3B-Launcher';'Cache-Control'='no-cache';'Pragma'='no-cache'} -TimeoutSec 60
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)
  if($errors.Count -gt 0){throw ('35B runner parse failure: '+($errors.Message -join '; '))}
  [IO.File]::WriteAllText($runner,[IO.File]::ReadAllText($tmp),$utf8)
}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}

# Re-check after download in case a prior transport completed concurrently.
$prior=Read-State
if(Model-CallProtected $prior){
  Emit ([ordered]@{ok=$true;already=$true;protected=$true;job_id=$JobId;status=[string]$prior.status;phase=[string]$prior.phase;model_call_attempted=$true;expected_sha=$ExpectedSha;state_file=$stateFile;task=$taskName})
  exit 0
}

$existingTask=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($existingTask -and $existingTask.State -eq 'Running'){
  $state=Read-State
  if($state -and ([string]$state.status -eq 'running' -or (Model-CallProtected $state))){
    Emit ([ordered]@{ok=$true;already=$true;job_id=$JobId;status=[string]$state.status;phase=[string]$state.phase;expected_sha=$ExpectedSha;state_file=$stateFile;task=$taskName;task_state='Running'})
    exit 0
  }
  throw "$taskName is already running without matching guarded state; refusing a duplicate launch."
}

# Do not silently resume a partially prepared pre-call project. That state is safe
# but must be inspected explicitly rather than deleting evidence automatically.
if($prior -and -not(Model-CallProtected $prior)){
  $phase=[string]$prior.phase
  if($phase -and $phase -ne 'preflight'){
    throw "Existing pre-call 35B state requires explicit inspection before resume: phase=$phase status=$([string]$prior.status)"
  }
}

Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
$wrapperText=@"
#Requires -Version 5.1
`$ErrorActionPreference='Stop'
try {
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '$runner' -SourceSha '$ExpectedSha' 1> '$stdout' 2> '$stderr'
  exit `$LASTEXITCODE
} catch {
  (`$_ | Out-String) | Add-Content -LiteralPath '$stderr' -Encoding UTF8
  exit 1
}
"@
[IO.File]::WriteAllText($wrapper,$wrapperText,$utf8)
$tokens=$null;$errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($wrapper,[ref]$tokens,[ref]$errors)
if($errors.Count -gt 0){throw ('35B interactive wrapper parse failure: '+($errors.Message -join '; '))}

$userId=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
if([string]::IsNullOrWhiteSpace($userId) -or $userId -notmatch '\\'){throw "Unable to resolve authenticated H3 Windows identity: '$userId'"}
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$wrapper`""
$principal=New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force|Out-Null
Start-ScheduledTask -TaskName $taskName

$deadline=(Get-Date).AddSeconds(45)
do{
  Start-Sleep -Milliseconds 500
  $state=Read-State
  if($state){
    if(Model-CallProtected $state){
      Emit ([ordered]@{ok=$true;already=$false;protected=$true;job_id=$JobId;status=[string]$state.status;phase=[string]$state.phase;model_call_attempted=$true;expected_sha=$ExpectedSha;state_file=$stateFile;stdout=$stdout;stderr=$stderr;runner=$runner;task=$taskName;principal=$userId;execution_context='h3-interactive-user'})
      exit 0
    }
    if([string]$state.status -in @('blocked','failed')){
      Emit ([ordered]@{ok=$false;already=$false;protected=$false;job_id=$JobId;status=[string]$state.status;phase=[string]$state.phase;message=[string]$state.message;model_call_attempted=$false;expected_sha=$ExpectedSha;state_file=$stateFile;task=$taskName})
      exit 2
    }
    if([string]$state.phase -eq 'pre_ollama'){
      # Keep waiting briefly for the durable model-call-start marker.
    }
  }
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if($task -and $task.State -ne 'Running'){
    $info=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    throw "35B interactive runner ended before model-call proof. lastResult=$([string]$info.LastTaskResult) stderr=$(Tail $stderr) stdout=$(Tail $stdout)"
  }
}while((Get-Date) -lt $deadline)

throw "35B interactive runner did not publish ollama_post_started/terminal state within 45 seconds. task=$taskName state=$stateFile stderr=$(Tail $stderr)"
