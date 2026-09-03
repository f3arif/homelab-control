#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId
)

$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only blog benchmark launcher; host=$env:COMPUTERNAME"}
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha must be a 40-character commit SHA.'}
if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid JobId.'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()
if($JobId -ne 'afz-blog-qwen35b-vs-ridge27b-20260902-r1'){throw 'Unexpected blog benchmark JobId.'}

$root='C:\ProgramData\AFZ\H3AFZBlogModelComparison'
$runner=Join-Path $root 'Start-H3-AFZBlog-ModelComparison.ps1'
$wrapper=Join-Path $root 'Invoke-H3-AFZBlog-ModelComparison.ps1'
$stateFile=Join-Path $root 'state.json'
$stdout=Join-Path $root ($JobId+'.stdout.log')
$stderr=Join-Path $root ($JobId+'.stderr.log')
$runnerUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/Start-H3-AFZBlog-ModelComparison.ps1"
$taskName='AFZ H3 AFZ Blog Model Comparison'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root|Out-Null

function Emit($o){[Console]::Out.WriteLine(($o|ConvertTo-Json -Depth 20 -Compress))}
function Read-State{if(-not(Test-Path -LiteralPath $stateFile -PathType Leaf)){return $null};try{return [IO.File]::ReadAllText($stateFile,$utf8)|ConvertFrom-Json}catch{return $null}}
function Any-Attempted($State){if(-not $State -or -not $State.models){return $false};foreach($p in $State.models.PSObject.Properties){if($p.Value -and [bool]$p.Value.attempted){return $true}};return $false}
function Tail([string]$Path){if(Test-Path -LiteralPath $Path){return ((Get-Content -LiteralPath $Path -Tail 25 -ErrorAction SilentlyContinue)-join "`n")};return ''}

$prior=Read-State
if($prior){
  if([string]$prior.job_id -eq $JobId -and [string]$prior.status -in @('completed','partial')){
    Emit ([ordered]@{ok=$true;already=$true;job_id=$JobId;status=[string]$prior.status;expected_sha=$ExpectedSha;state_file=$stateFile;task=$taskName;model_replay=$false})
    exit 0
  }
  if([string]$prior.job_id -eq $JobId -and (Any-Attempted $prior)){
    Emit ([ordered]@{ok=$false;already=$true;job_id=$JobId;status='blocked-existing-attempt';expected_sha=$ExpectedSha;state_file=$stateFile;task=$taskName;model_replay=$false;message='Existing state proves at least one model call was attempted. Launcher refuses a fresh process.'})
    exit 20
  }
}

$tmp=Join-Path $env:TEMP ('AFZ-H3-BlogCompare-'+[guid]::NewGuid().ToString('N')+'.ps1')
try{
  Invoke-WebRequest -Uri $runnerUrl -OutFile $tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-BlogCompare-Launcher';'Cache-Control'='no-cache';'Pragma'='no-cache'} -TimeoutSec 60
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)
  if($errors.Count -gt 0){throw ('Blog comparison runner parse failure: '+($errors.Message -join '; '))}
  [IO.File]::WriteAllText($runner,[IO.File]::ReadAllText($tmp),$utf8)
}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}

$existing=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -and $_.CommandLine -match [regex]::Escape('Start-H3-AFZBlog-ModelComparison.ps1')})
if($existing.Count -gt 0){Emit ([ordered]@{ok=$true;already=$true;job_id=$JobId;status='process-running';expected_sha=$ExpectedSha;pid=[int]$existing[0].ProcessId;state_file=$stateFile;task=$taskName;model_replay=$false});exit 0}

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

$userId=[Security.Principal.WindowsIdentity]::GetCurrent().Name
if([string]::IsNullOrWhiteSpace($userId) -or $userId -notmatch '\\'){throw "Unable to resolve H3 interactive identity: '$userId'"}
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$wrapper`""
$principal=New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($task -and $task.State -eq 'Running'){Emit ([ordered]@{ok=$true;already=$true;job_id=$JobId;status='task-running';expected_sha=$ExpectedSha;state_file=$stateFile;task=$taskName;model_replay=$false});exit 0}
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force|Out-Null
Start-ScheduledTask -TaskName $taskName

$deadline=(Get-Date).AddSeconds(45)
do{
  Start-Sleep -Milliseconds 500
  $state=Read-State
  if($state -and [string]$state.job_id -eq $JobId -and [string]$state.status -in @('running','completed','partial')){
    $t=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Emit ([ordered]@{ok=$true;already=$false;job_id=$JobId;status=[string]$state.status;expected_sha=$ExpectedSha;state_file=$stateFile;stdout=$stdout;stderr=$stderr;task=$taskName;task_state=[string]$t.State;principal=$userId;logon_type='Interactive';model_replay=$false})
    exit 0
  }
  $t=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if($t -and $t.State -ne 'Running'){
    $info=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    throw "Blog comparison runner ended before launch proof. lastResult=$([string]$info.LastTaskResult) stderr=$(Tail $stderr) stdout=$(Tail $stdout)"
  }
}while((Get-Date) -lt $deadline)
throw "Blog comparison runner did not publish running state within 45 seconds. stderr=$(Tail $stderr)"
