#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$jobId='qwen27b-website-20260827-i02'
$expectedHost='DESKTOP-H3R6CQN'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$h3Ip='100.106.186.118'
$h3Mac='4C-ED-FB-3F-B0-9E'
$broadcast='192.168.50.255'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen27b-transport-recovery'
$statePath=Join-Path $stateRoot 'latest.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Read-State {
  if(-not(Test-Path -LiteralPath $statePath -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}
}
function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 30 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  Write-Output $json
}
function Test-Tcp([string]$HostName,[int]$Port,[int]$TimeoutMs=1200){
  $c=New-Object Net.Sockets.TcpClient
  try{
    $ar=$c.BeginConnect($HostName,$Port,$null,$null)
    if(-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs,$false)){return $false}
    $c.EndConnect($ar);return $true
  }catch{return $false}finally{try{$c.Close()}catch{}}
}
function Send-H3Wake {
  $bytes=$h3Mac -split '[:-]'|ForEach-Object {[Convert]::ToByte($_,16)}
  $packet=New-Object byte[] 102
  0..5|ForEach-Object {$packet[$_]=0xFF}
  for($i=1;$i -le 16;$i++){[Array]::Copy($bytes,0,$packet,6+(($i-1)*6),6)}
  $client=New-Object Net.Sockets.UdpClient
  try{
    $client.EnableBroadcast=$true
    foreach($round in 1..4){
      foreach($port in @(9,7)){
        $ep=New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($broadcast)),$port
        [void]$client.Send($packet,$packet.Length,$ep)
      }
      Start-Sleep -Milliseconds 350
    }
  }finally{$client.Dispose()}
}
function Invoke-H3([string]$RemoteScript){
  # Keep the full H3 body off the Windows command line. The encoded bootstrap
  # consumes redirected stdin and invokes only that exact bounded script.
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''Qwen27B recovery stdin was empty.''};Invoke-Expression $script'
  $bootstrapEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $args=@(
    '-i',$key,
    '-o','IdentitiesOnly=yes',
    '-o','BatchMode=yes',
    '-o','ConnectTimeout=12',
    '-o','StrictHostKeyChecking=yes',
    '-o',('UserKnownHostsFile='+$known),
    $target,
    'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$bootstrapEncoded
  )
  $inFile=Join-Path $env:TEMP ('afz-qwen27b-recovery-in-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('afz-qwen27b-recovery-out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $errFile=Join-Path $env:TEMP ('afz-qwen27b-recovery-err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    [IO.File]::WriteAllText($inFile,$RemoteScript,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(90000)){
      try{$p.Kill()}catch{}
      throw 'H3 Qwen27B guarded transport timed out after 90 seconds.'
    }
    return [ordered]@{
      exit=[int]$p.ExitCode
      stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile)}else{''})
      stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile)}else{''})
    }
  }finally{
    Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue
  }
}

try{
  if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only recovery; host=$env:COMPUTERNAME"}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  if([string]$identity.User.Value -ne 'S-1-5-18'){throw "Qwen27B transport recovery must run as SYSTEM; identity=$([string]$identity.Name)"}
  foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required path missing: $p"}}

  $prior=Read-State
  if($prior -and [string]$prior.jobId -eq $jobId){
    if([string]$prior.status -eq 'completed'){Save-State $prior;exit 0}
    if([string]$prior.status -eq 'blocked-github-auth'){
      try{$age=((Get-Date)-[datetime]$prior.time).TotalMinutes}catch{$age=999}
      if($age -lt 30){Save-State $prior;exit 0}
    }
  }

  Save-State ([ordered]@{schema=1;status='running';classification='QWEN27B_SYSTEM_TRANSPORT_RECOVERY_RUNNING';jobId=$jobId;transport='SYSTEM-key+strict-ssh+encoded-stdin';modelCallIssuedByRecovery=$false;time=(Get-Date -Format o)})|Out-Null

  if(-not(Test-Tcp $h3Ip 22 1200)){Send-H3Wake}
  $online=$false
  for($i=1;$i -le 90;$i++){
    if(Test-Tcp $h3Ip 22 1200){$online=$true;break}
    if($i -in @(30,60)){try{Send-H3Wake}catch{}}
    Start-Sleep -Seconds 2
  }
  if(-not $online){throw 'H3 Tailscale SSH did not become reachable within the bounded Wake-on-LAN window.'}

  $remote=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: $env:COMPUTERNAME"}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$jobId='qwen27b-website-20260827-i02'
$legacyTask='AFZ H3 GitHub Direct Benchmark Watcher'
$controllerName='Run-H3-Qwen27B-WebsiteBenchmark.ps1'
$switchUrl='https://raw.githubusercontent.com/f3arif/homelab-control/main/afz-openai-agent/tools/Switch-H3-Qwen27B-ToApiResume.ps1'

function Controller-Processes {
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue|Where-Object {
    ([string]$_.CommandLine -match [regex]::Escape($controllerName)) -or
    (([string]$_.CommandLine -match [regex]::Escape('Qwen38-27B-Website-Benchmark-20260826-174739')) -and ([string]$_.CommandLine -match '(?i)qwen27b|websitebenchmark'))
  }|Select-Object ProcessId,ParentProcessId,Name,CommandLine)
}
function Legacy-Processes {
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue|Where-Object {
    [string]$_.CommandLine -match 'H3-GitHub-Direct-Benchmark-Watcher[.]ps1|Start-H3-GitHub-Direct-Benchmark[.]ps1'
  }|Select-Object ProcessId,ParentProcessId,Name,CommandLine)
}
function Find-Gh {
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path -LiteralPath $p){return $p}}
  return $null
}

$controllerBefore=@(Controller-Processes)
$task=Get-ScheduledTask -TaskName $legacyTask -ErrorAction SilentlyContinue
if($task){
  try{Disable-ScheduledTask -TaskName $legacyTask -ErrorAction Stop|Out-Null}catch{}
  try{Stop-ScheduledTask -TaskName $legacyTask -ErrorAction SilentlyContinue}catch{}
}
for($pass=0;$pass -lt 4;$pass++){
  $legacy=@(Legacy-Processes)
  if($legacy.Count -eq 0){break}
  foreach($p in $legacy){try{Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
  Start-Sleep -Milliseconds 500
}
$legacyAfter=@(Legacy-Processes)
if($legacyAfter.Count -gt 0){throw 'Obsolete H3 watcher/launcher processes remain after bounded stop.'}

$controllerAfter=@(Controller-Processes)
if($controllerBefore.Count -gt 0 -or $controllerAfter.Count -gt 0){
  [ordered]@{ok=$true;status='completed';classification='QWEN27B_EXISTING_CONTROLLER_PROTECTED';jobId=$jobId;legacyTaskDisabled=[bool]$task;legacyProcessCount=0;controllerCount=@($controllerAfter).Count;resumeLaunched=$false;modelCallIssuedByRecovery=$false;time=(Get-Date -Format o)}|ConvertTo-Json -Depth 8 -Compress
  exit 0
}

$gh=Find-Gh
$ghAuth=$false
if($gh){
  & $gh auth status --hostname github.com *> $null
  $ghAuth=($LASTEXITCODE -eq 0)
}
if(-not $ghAuth){
  [ordered]@{ok=$false;status='blocked-github-auth';classification='QWEN27B_LEGACY_WATCHER_DISABLED_GH_AUTH_REQUIRED';jobId=$jobId;legacyTaskDisabled=[bool]$task;legacyProcessCount=0;controllerCount=0;resumeLaunched=$false;modelCallIssuedByRecovery=$false;time=(Get-Date -Format o)}|ConvertTo-Json -Depth 8 -Compress
  exit 0
}

$tmp=Join-Path $env:TEMP ('AFZ-Qwen27B-ApiSwitch-'+[guid]::NewGuid().ToString('n')+'.ps1')
try{
  Invoke-WebRequest -Uri $switchUrl -OutFile $tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-Qwen27B-TransportRecovery';'Cache-Control'='no-cache';'Pragma'='no-cache'} -TimeoutSec 60
  $tokens=$null;$errors=$null
  [void][Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)
  if($errors.Count -gt 0){throw ('Qwen27B API switch parse failure: '+($errors.Message -join '; '))}
  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $tmp 2>&1|Out-String).Trim()
  $code=$LASTEXITCODE
  if($code -ne 0){throw "Qwen27B API switch failed exit=$code output=$raw"}
  $line=@(($raw -split "`r?`n")|Where-Object {$_.Trim() -match '^\{.*\}$'}|Select-Object -Last 1)
  $switchResult=$null
  if($line){try{$switchResult=([string]$line).Trim()|ConvertFrom-Json}catch{}}
  [ordered]@{ok=$true;status='completed';classification='QWEN27B_API_RESUME_SWITCH_EXECUTED';jobId=$jobId;legacyTaskDisabled=$true;legacyProcessCount=0;controllerCount=0;resumeLaunched=$true;switch=$switchResult;modelCallIssuedByRecovery=$false;time=(Get-Date -Format o)}|ConvertTo-Json -Depth 14 -Compress
}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
'@

  $r=Invoke-H3 $remote
  $stdout=[string]$r.stdout
  $stderr=[string]$r.stderr
  if([int]$r.exit -ne 0){throw "H3 Qwen27B recovery failed exit=$($r.exit) stdout=$stdout stderr=$stderr"}
  $jsonLine=@(($stdout -split "`r?`n")|Where-Object {$_.Trim() -match '^\{.*\}$'}|Select-Object -Last 1)
  if(-not $jsonLine){throw "H3 Qwen27B recovery returned no JSON proof. stdout=$stdout stderr=$stderr"}
  $proof=([string]$jsonLine).Trim()|ConvertFrom-Json -ErrorAction Stop

  $status=[string]$proof.status
  $classification=[string]$proof.classification
  $final=[ordered]@{schema=1;status=$status;classification=$classification;jobId=$jobId;transport='SYSTEM-key+strict-ssh+encoded-stdin';modelCallIssuedByRecovery=$false;h3Proof=$proof;time=(Get-Date -Format o)}
  Save-State $final
  exit 0
}catch{
  $final=[ordered]@{schema=1;status='failed';classification='QWEN27B_SYSTEM_TRANSPORT_RECOVERY_FAILED';jobId=$jobId;modelCallIssuedByRecovery=$false;error=$_.Exception.Message;detail=($_|Out-String).Trim();time=(Get-Date -Format o)}
  Save-State $final
  exit 20
}
