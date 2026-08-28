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
$stateFile=Join-Path $root ($JobId+'.json')
$stdout=Join-Path $root ($JobId+'.stdout.log')
$stderr=Join-Path $root ($JobId+'.stderr.log')
$runnerUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/Start-H3-QwenRidge16K-WebsiteTest.ps1"
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root|Out-Null

function Emit($o){
  [Console]::Out.WriteLine(($o|ConvertTo-Json -Depth 12 -Compress))
}
function Read-State {
  if(-not(Test-Path -LiteralPath $stateFile)){return $null}
  try{return Get-Content -LiteralPath $stateFile -Raw|ConvertFrom-Json}catch{return $null}
}

$prior=Read-State
if($prior -and [string]$prior.status -in @('running','completed')){
  Emit ([ordered]@{ok=$true;already=$true;job_id=$JobId;status=[string]$prior.status;expected_sha=$ExpectedSha;state_file=$stateFile;runner=$runner})
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

# If this exact-SHA detached runner is already alive, do not create a second GPU job.
$existing=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue|Where-Object {
  $_.CommandLine -and $_.CommandLine -match [regex]::Escape('Start-H3-QwenRidge16K-WebsiteTest.ps1') -and $_.CommandLine -match [regex]::Escape($ExpectedSha)
})
if($existing.Count -gt 0){
  Emit ([ordered]@{ok=$true;already=$true;job_id=$JobId;status='process-running';expected_sha=$ExpectedSha;pid=[int]$existing[0].ProcessId;state_file=$stateFile;runner=$runner})
  exit 0
}

Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
$args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$runner,'-SourceSha',$ExpectedSha)
$p=Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr

$deadline=(Get-Date).AddSeconds(25)
do{
  Start-Sleep -Milliseconds 500
  $state=Read-State
  if($state -and [string]$state.status -in @('running','completed')){
    Emit ([ordered]@{ok=$true;already=$false;job_id=$JobId;status=[string]$state.status;expected_sha=$ExpectedSha;pid=$p.Id;state_file=$stateFile;stdout=$stdout;stderr=$stderr;runner=$runner})
    exit 0
  }
  $p.Refresh()
  if($p.HasExited){
    $errTail='';$outTail=''
    if(Test-Path -LiteralPath $stderr){$errTail=((Get-Content -LiteralPath $stderr -Tail 20 -ErrorAction SilentlyContinue)-join "`n")}
    if(Test-Path -LiteralPath $stdout){$outTail=((Get-Content -LiteralPath $stdout -Tail 20 -ErrorAction SilentlyContinue)-join "`n")}
    throw "Ridge16K runner exited before launch proof. exit=$($p.ExitCode) stderr=$errTail stdout=$outTail"
  }
}while((Get-Date) -lt $deadline)

throw "Ridge16K runner did not publish running/completed state within 25 seconds. pid=$($p.Id) state=$stateFile"
