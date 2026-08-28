#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId
)

$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha required'}
if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid JobId'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: $env:COMPUTERNAME"}

$root='C:\OpenWebUI'
$db=Join-Path $root 'data\webui.db'
$py=Join-Path $root 'venv\Scripts\python.exe'
$pipeDir=Join-Path $root 'afz-functions'
$pipePath=Join-Path $pipeDir 'afz_agent_pipe.py'
$helperDir=Join-Path $root 'afz-bootstrap'
$installerPath=Join-Path $helperDir 'install_afz_agent_pipe.py'
$smokePath=Join-Path $helperDir 'smoke_afz_agent_pipe.py'
$backupDir=Join-Path $root 'data\backups'
$resultPath=Join-Path $root 'logs\afz-pipe-bootstrap-latest.json'
$task='OpenWebUI Server'
$base="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/openwebui"
$pipeUrl="$base/afz_agent_pipe.py"
$installerUrl="$base/install_afz_agent_pipe.py"
$smokeUrl="$base/smoke_afz_agent_pipe.py"
$utf8=New-Object Text.UTF8Encoding($false)

function Invoke-NativeCapture {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string[]]$Arguments=@(),
    [int]$TimeoutSeconds=120
  )
  $tag=[guid]::NewGuid().ToString('N')
  $stdout=Join-Path $env:TEMP ($tag+'.stdout.txt')
  $stderr=Join-Path $env:TEMP ($tag+'.stderr.txt')
  try{
    $sp=@{
      FilePath=$FilePath
      Wait=$false
      PassThru=$true
      NoNewWindow=$true
      RedirectStandardOutput=$stdout
      RedirectStandardError=$stderr
    }
    if($Arguments.Count -gt 0){$sp.ArgumentList=$Arguments}
    $p=Start-Process @sp
    if(-not $p.WaitForExit([math]::Max(1,$TimeoutSeconds)*1000)){
      try{$p.Kill()}catch{}
      throw "Process timeout after ${TimeoutSeconds}s: $FilePath"
    }
    $out=if(Test-Path -LiteralPath $stdout){Get-Content -LiteralPath $stdout -Raw}else{''}
    $err=if(Test-Path -LiteralPath $stderr){Get-Content -LiteralPath $stderr -Raw}else{''}
    return [pscustomobject]@{ExitCode=[int]$p.ExitCode;StdOut=[string]$out;StdErr=[string]$err}
  }finally{
    Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
  }
}

function Download-Exact([string]$Uri,[string]$Path,[string]$Agent){
  Invoke-WebRequest -Uri $Uri -OutFile $Path -UseBasicParsing -Headers @{'User-Agent'=$Agent;'Cache-Control'='no-cache'} -TimeoutSec 60
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Download missing after request: $Path"}
}

if(-not(Test-Path -LiteralPath $db -PathType Leaf)){throw "OpenWebUI database missing: $db"}
if(-not(Test-Path -LiteralPath $py -PathType Leaf)){throw "OpenWebUI venv python missing: $py"}
New-Item -ItemType Directory -Force -Path $pipeDir,$helperDir,$backupDir,(Split-Path $resultPath -Parent)|Out-Null

Download-Exact $pipeUrl $pipePath 'AFZ-OpenWebUI-Pipe-ExactSha'
Download-Exact $installerUrl $installerPath 'AFZ-OpenWebUI-Installer-ExactSha'
Download-Exact $smokeUrl $smokePath 'AFZ-OpenWebUI-Smoke-ExactSha'

foreach($source in @($pipePath,$installerPath,$smokePath)){
  $compile=Invoke-NativeCapture -FilePath $py -Arguments @('-m','py_compile',$source) -TimeoutSeconds 60
  if($compile.ExitCode -ne 0){throw "Python compile failed for $source exit=$($compile.ExitCode) stderr=$($compile.StdErr)"}
}

$install=Invoke-NativeCapture -FilePath $py -Arguments @($installerPath,$db,$pipePath,$backupDir) -TimeoutSeconds 120
if($install.ExitCode -ne 0){throw "OpenWebUI function DB install failed exit=$($install.ExitCode) stderr=$($install.StdErr) stdout=$($install.StdOut)"}
$installLine=@(($install.StdOut -split '\r?\n')|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1)
if(-not $installLine){throw 'OpenWebUI function DB installer returned no JSON result'}
$dbResult=$installLine|ConvertFrom-Json
if(-not [bool]$dbResult.ok){throw 'OpenWebUI function DB installer returned ok=false'}

Get-ScheduledTask -TaskName $task -ErrorAction Stop|Out-Null
try{Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue}catch{}
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName $task
$httpOk=$false
for($i=0;$i -lt 30;$i++){
  Start-Sleep -Seconds 2
  try{
    $r=Invoke-WebRequest -Uri 'http://127.0.0.1:8080/' -UseBasicParsing -TimeoutSec 4
    if($r.StatusCode -eq 200){$httpOk=$true;break}
  }catch{}
}
if(-not $httpOk){throw 'OpenWebUI did not return HTTP 200 after restart'}

$smoke=Invoke-NativeCapture -FilePath $py -Arguments @($smokePath,$pipePath) -TimeoutSeconds 150
if($smoke.ExitCode -ne 0){throw "AFZ Pipe smoke failed exit=$($smoke.ExitCode) stderr=$($smoke.StdErr) stdout=$($smoke.StdOut)"}
$smokeLine=@(($smoke.StdOut -split '\r?\n')|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1)
if(-not $smokeLine){throw 'AFZ Pipe smoke returned no JSON result'}
$smokeObj=$smokeLine|ConvertFrom-Json
if(-not [bool]$smokeObj.ok){throw ('AFZ Pipe smoke returned failure: '+[string]$smokeObj.output)}

$result=[ordered]@{
  ok=$true
  host=$env:COMPUTERNAME
  expectedSha=$ExpectedSha
  jobId=$JobId
  pipe=$pipePath
  dbAction=[string]$dbResult.action
  backup=[string]$dbResult.backup
  openWebUiHttp=$httpOk
  taskState=[string](Get-ScheduledTask -TaskName $task).State
  smoke=[string]$smokeObj.output
  transport='h3-exact-sha-remote-runner'
  completedAt=(Get-Date -Format o)
}
[IO.File]::WriteAllText($resultPath,($result|ConvertTo-Json -Depth 8 -Compress),$utf8)

$od=$env:OneDriveCommercial
if([string]::IsNullOrWhiteSpace($od) -or -not(Test-Path -LiteralPath $od)){$od=Join-Path $env:USERPROFILE 'OneDrive - AFZ Engineering Inc'}
if(Test-Path -LiteralPath $od){
  try{
    $safeResult=Join-Path $od 'AFZ Shared\AFZ Results\000-critical-openwebui-afz-pipe-bootstrap-latest.txt'
    $lines=@(
      'AFZ_OPENWEBUI_PIPE_BOOTSTRAP',
      'STATUS=PASS',
      'HOST='+$env:COMPUTERNAME,
      'EXPECTED_SHA='+$ExpectedSha,
      'JOB_ID='+$JobId,
      'DB_ACTION='+[string]$dbResult.action,
      'BACKUP='+[string]$dbResult.backup,
      'OPENWEBUI_HTTP='+$httpOk,
      'TASK_STATE='+[string](Get-ScheduledTask -TaskName $task).State,
      'TRANSPORT=h3-exact-sha-remote-runner',
      'SMOKE_BEGIN',
      [string]$smokeObj.output,
      'SMOKE_END',
      'COMPLETED_AT='+$result.completedAt
    )
    [IO.File]::WriteAllText($safeResult,($lines -join "`r`n"),$utf8)
  }catch{}
}

Write-Output ($result|ConvertTo-Json -Depth 8 -Compress)
