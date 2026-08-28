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
if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid JobId.'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()

$root='C:\ProgramData\AFZ\H3QwenRidge16K'
$runner=Join-Path $root 'Start-H3-QwenRidge16K-WebsiteTest.ps1'
$wrapper=Join-Path $root 'Invoke-H3-QwenRidge16K-InteractiveRunner.ps1'
$stateFile=Join-Path $root ($JobId+'.json')
$stdout=Join-Path $root ($JobId+'.stdout.log')
$stderr=Join-Path $root ($JobId+'.stderr.log')
$runnerUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/Start-H3-QwenRidge16K-WebsiteTest.ps1"
$taskName='AFZ H3 Qwen Ridge16K Runner'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root|Out-Null

function Emit($o){[Console]::Out.WriteLine(($o|ConvertTo-Json -Depth 12 -Compress))}
function Read-State {
  if(-not(Test-Path -LiteralPath $stateFile)){return $null}
  try{return Get-Content -LiteralPath $stateFile -Raw|ConvertFrom-Json}catch{return $null}
}
function Tail([string]$Path){if(Test-Path -LiteralPath $Path){return ((Get-Content -LiteralPath $Path -Tail 30 -ErrorAction SilentlyContinue)-join "`n")};return ''}

$prior=Read-State
if($prior -and [string]$prior.status -in @('running','completed')){
  Emit ([ordered]@{ok=$true;already=$true;job_id=$JobId;status=[string]$prior.status;expected_sha=$ExpectedSha;state_file=$stateFile;runner=$runner;task=$taskName;execution_context='h3-interactive-user'})
  exit 0
}

$tmp=Join-Path $env:TEMP ('AFZ-H3-QwenRidge16K-'+[guid]::NewGuid().ToString('N')+'.ps1')
try{
  Invoke-WebRequest -Uri $runnerUrl -OutFile $tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-QwenRidge16K-Launcher';'Cache-Control'='no-cache';'Pragma'='no-cache'} -TimeoutSec 60
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)
  if($errors.Count -gt 0){throw ('Runner parse failure: '+($errors.Message -join '; '))}
  [IO.File]::WriteAllText($runner,[IO.File]::ReadAllText($tmp),$utf8)
}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}

# Do not create a second GPU job if an exact-SHA runner is already alive.
$existing=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue|Where-Object {
  $_.CommandLine -and $_.CommandLine -match [regex]::Escape('Start-H3-QwenRidge16K-WebsiteTest.ps1') -and $_.CommandLine -match [regex]::Escape($ExpectedSha)
})
if($existing.Count -gt 0){
  Emit ([ordered]@{ok=$true;already=$true;job_id=$JobId;status='process-running';expected_sha=$ExpectedSha;pid=[int]$existing[0].ProcessId;state_file=$stateFile;runner=$runner;task=$taskName})
  exit 0
}

# GitHub CLI credentials on H3 are user-session credentials. The SSH logon can
# install/arm the job but must not be the model runner's security context. Use a
# dedicated triggerless Interactive scheduled task for this one-shot execution.
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
if($errors.Count -gt 0){throw ('Interactive wrapper parse failure: '+($errors.Message -join '; '))}

$userId="$env:USERDOMAIN\$env:USERNAME"
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$wrapper`""
$principal=New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
$existingTask=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($existingTask -and $existingTask.State -eq 'Running'){
  $state=Read-State
  if($state -and [string]$state.status -in @('running','completed')){
    Emit ([ordered]@{ok=$true;already=$true;job_id=$JobId;status=[string]$state.status;expected_sha=$ExpectedSha;state_file=$stateFile;runner=$runner;task=$taskName;task_state='Running';execution_context='h3-interactive-user'})
    exit 0
  }
  throw "$taskName is already running without matching Ridge16K state; refusing a second launch."
}
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force|Out-Null
Start-ScheduledTask -TaskName $taskName

$deadline=(Get-Date).AddSeconds(35)
do{
  Start-Sleep -Milliseconds 500
  $state=Read-State
  if($state -and [string]$state.status -in @('running','completed')){
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Emit ([ordered]@{ok=$true;already=$false;job_id=$JobId;status=[string]$state.status;expected_sha=$ExpectedSha;state_file=$stateFile;stdout=$stdout;stderr=$stderr;runner=$runner;task=$taskName;task_state=[string]$task.State;principal=$userId;logon_type='Interactive';execution_context='h3-interactive-user'})
    exit 0
  }
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if($task -and $task.State -ne 'Running'){
    $info=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    throw "Ridge16K interactive runner ended before launch proof. lastResult=$([string]$info.LastTaskResult) stderr=$(Tail $stderr) stdout=$(Tail $stdout)"
  }
}while((Get-Date) -lt $deadline)

throw "Ridge16K interactive runner did not publish running/completed state within 35 seconds. task=$taskName state=$stateFile stderr=$(Tail $stderr)"
