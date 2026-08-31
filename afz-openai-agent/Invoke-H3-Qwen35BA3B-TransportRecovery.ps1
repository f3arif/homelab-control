#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

$jobId='qwen35b-a3b-website-20260830-r1'
$expectedHost='DESKTOP-H3R6CQN'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$h3Ip='100.106.186.118'
$h3Mac='4C-ED-FB-3F-B0-9E'
$broadcast='192.168.50.255'
$activationPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-a3b-request\'+$jobId+'-activation-v1.json'
$bootstrapPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-a3b-bootstrap\latest.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-a3b-transport-recovery'
$statePath=Join-Path $stateRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-QWEN35B-TRANSPORT-RECOVERY-LATEST.json'
$mirrorTextPath=Join-Path $mirrorRoot 'AFZ-QWEN35B-TRANSPORT-RECOVERY-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}
}
function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 30 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{
    if(Test-Path -LiteralPath $mirrorRoot -PathType Container){
      [IO.File]::WriteAllText($mirrorPath,$json,$utf8)
      [IO.File]::WriteAllText($mirrorTextPath,$json,$utf8)
    }
  }catch{}
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
    foreach($round in 1..5){
      foreach($port in @(9,7)){
        $ep=New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($broadcast)),$port
        [void]$client.Send($packet,$packet.Length,$ep)
      }
      Start-Sleep -Milliseconds 400
    }
  }finally{$client.Dispose()}
}
function Invoke-H3([string]$RemoteScript){
  # Keep the full remote body off the process command line. The tiny encoded
  # bootstrap only consumes redirected stdin and invokes that exact body.
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''35B recovery stdin was empty.''};Invoke-Expression $script'
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
  $inFile=Join-Path $env:TEMP ('afz-qwen35b-recovery-in-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('afz-qwen35b-recovery-out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $errFile=Join-Path $env:TEMP ('afz-qwen35b-recovery-err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    [IO.File]::WriteAllText($inFile,$RemoteScript,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(90000)){
      try{$p.Kill()}catch{}
      throw 'H3 35B guarded transport timed out after 90 seconds.'
    }
    $stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile)}else{''})
    $stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile)}else{''})
    return [ordered]@{exit=[int]$p.ExitCode;stdout=$stdout;stderr=$stderr}
  }finally{
    Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue
  }
}
function Invoke-PostReturnRecovery {
  $helper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Qwen35BA3B-PostReturnRecovery.ps1'
  if(-not(Test-Path -LiteralPath $helper -PathType Leaf)){return [ordered]@{ok=$false;status='helper-missing';path=$helper}}
  try{
    $raw=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot | Select-Object -Last 1
    $code=$LASTEXITCODE
    if($raw -is [string]){try{$parsed=$raw|ConvertFrom-Json}catch{$parsed=[ordered]@{status='invalid-json';raw=[string]$raw}}}else{$parsed=$raw}
    return [ordered]@{ok=($code -eq 0);status=$(if($code -eq 0){'completed'}else{'helper-failed'});exit=$code;result=$parsed}
  }catch{return [ordered]@{ok=$false;status='helper-exception';error=$_.Exception.Message}}
}

try{
  if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only recovery; host=$env:COMPUTERNAME"}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  if([string]$identity.User.Value -ne 'S-1-5-18'){throw "35B transport recovery must run as SYSTEM; identity=$([string]$identity.Name)"}
  foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required path missing: $p"}}

  # This continuation is independent of the one-call transport activation. It can
  # only consume the already-saved successful Ollama response and contains no model call.
  $postReturnRecovery=Invoke-PostReturnRecovery

  $prior=Read-Json $statePath
  if($prior -and [string]$prior.jobId -eq $jobId -and [string]$prior.status -eq 'completed'){
    $wrapped=[ordered]@{}
    foreach($p in $prior.PSObject.Properties){$wrapped[$p.Name]=$p.Value}
    $wrapped['postReturnRecovery']=$postReturnRecovery
    Save-State $wrapped
    exit 0
  }

  $activation=Read-Json $activationPath
  if(-not $activation){throw "35B activation marker missing: $activationPath"}
  if([string]$activation.jobId -ne $jobId -or [int]$activation.maxModelCalls -ne 1){throw '35B activation marker contract mismatch.'}
  $benchmarkSha=([string]$activation.expectedSha).Trim().ToLowerInvariant()
  if($benchmarkSha -notmatch '^[0-9a-f]{40}$'){throw '35B activation marker has no valid expectedSha.'}

  $failed=Read-Json $bootstrapPath
  if(-not $failed){throw "35B bootstrap state missing: $bootstrapPath"}
  $failureText=[string]$failed.message
  if([string]$failed.jobId -ne $jobId -or [string]$failed.status -ne 'failed' -or $failureText -notmatch 'afz_h3_worker' -or $failureText -notmatch '(?i)permission denied'){
    throw '35B recovery is allowed only for the proven pre-H3 SSH private-key permission failure.'
  }

  Save-State ([ordered]@{schema=1;status='running';classification='QWEN35B_SYSTEM_TRANSPORT_RECOVERY_RUNNING';jobId=$jobId;benchmarkSha=$benchmarkSha;maxModelCalls=1;transport='SYSTEM-key+strict-ssh+encoded-stdin+existing-H3-launcher-guard';modelCallIssuedByRecovery=$false;postReturnRecovery=$postReturnRecovery;time=(Get-Date -Format o)})|Out-Null

  if(-not(Test-Tcp $h3Ip 22 1200)){Send-H3Wake}
  $online=$false
  for($i=1;$i -le 90;$i++){
    if(Test-Tcp $h3Ip 22 1200){$online=$true;break}
    if($i -in @(30,60)){try{Send-H3Wake}catch{}}
    Start-Sleep -Seconds 2
  }
  if(-not $online){throw 'H3 Tailscale SSH did not become reachable within the bounded Wake-on-LAN window.'}

  $launcherUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$benchmarkSha/afz-openai-agent/tools/Launch-H3-Qwen35BA3B-WebsiteTest.ps1"
  $remote=@"
`$ErrorActionPreference='Stop'
if(`$env:COMPUTERNAME -ne '$expectedHost'){throw "Wrong host: `$env:COMPUTERNAME"}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
`$tmp=Join-Path `$env:TEMP 'AFZ-H3-Qwen35BA3B-Recovery-$benchmarkSha.ps1'
try {
  Invoke-WebRequest -Uri '$launcherUrl' -OutFile `$tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-Qwen35BA3B-Recovery';'Cache-Control'='no-cache';'Pragma'='no-cache'} -TimeoutSec 60
  `$tokens=`$null;`$errors=`$null
  [void][System.Management.Automation.Language.Parser]::ParseFile(`$tmp,[ref]`$tokens,[ref]`$errors)
  if(`$errors.Count -gt 0){throw ('35B launcher parse failure: '+(`$errors.Message -join '; '))}
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `$tmp -ExpectedSha '$benchmarkSha' -JobId '$jobId'
  exit `$LASTEXITCODE
} finally {
  Remove-Item -LiteralPath `$tmp -Force -ErrorAction SilentlyContinue
}
"@

  $remoteResult=Invoke-H3 $remote
  $stdout=[string]$remoteResult.stdout
  $stderr=[string]$remoteResult.stderr
  if([int]$remoteResult.exit -ne 0){throw "H3 35B launcher failed exit=$($remoteResult.exit) stdout=$stdout stderr=$stderr"}
  $jsonLine=@(($stdout -split "`r?`n")|Where-Object {$_.Trim() -match '^\{.*\}$'}|Select-Object -Last 1)
  if(-not $jsonLine){throw "H3 35B launcher returned no JSON proof. stdout=$stdout stderr=$stderr"}
  $proof=([string]$jsonLine).Trim()|ConvertFrom-Json -ErrorAction Stop
  if(-not [bool]$proof.ok){throw ('H3 35B launcher returned ok=false: '+[string]$proof.message)}
  $protected=($proof.PSObject.Properties.Name -contains 'protected' -and [bool]$proof.protected) -or ($proof.PSObject.Properties.Name -contains 'model_call_attempted' -and [bool]$proof.model_call_attempted)
  $classification=$(if([bool]$proof.already -and $protected){'QWEN35B_EXISTING_MODEL_CALL_PROTECTED'}elseif($protected){'QWEN35B_SINGLE_GUARDED_MODEL_CALL_STARTED'}elseif([bool]$proof.already){'QWEN35B_EXISTING_GUARDED_STATE_RETURNED'}else{'QWEN35B_GUARDED_LAUNCHER_RETURNED'})
  $final=[ordered]@{schema=1;status='completed';classification=$classification;jobId=$jobId;benchmarkSha=$benchmarkSha;maxModelCalls=1;transport='SYSTEM-key+strict-ssh+encoded-stdin+existing-H3-launcher-guard';modelCallIssuedByRecovery=$false;postReturnRecovery=$postReturnRecovery;h3Proof=$proof;time=(Get-Date -Format o)}
  Save-State $final
  exit 0
}catch{
  $final=[ordered]@{schema=1;status='failed';classification='QWEN35B_SYSTEM_TRANSPORT_RECOVERY_FAILED';jobId=$jobId;maxModelCalls=1;modelCallIssuedByRecovery=$false;error=$_.Exception.Message;detail=($_|Out-String).Trim();time=(Get-Date -Format o)}
  Save-State $final
  exit 20
}
