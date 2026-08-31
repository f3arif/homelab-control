#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$jobId='qwen35b-a3b-website-20260830-r1'
$recoverySha='5817bd2d55275526f3d90b72f93e3c76ea713e40'
$expectedHost='DESKTOP-H3R6CQN'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$h3Ip='100.106.186.118'
$h3Mac='4C-ED-FB-3F-B0-9E'
$broadcast='192.168.50.255'
$mirrorState='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results\h3\'+$jobId+'-state.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-postreturn-recovery'
$statePath=Join-Path $stateRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-QWEN35B-POSTRETURN-RECOVERY-LATEST.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}
}
function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 30 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  Write-Output $json
}
function Test-Tcp([string]$HostName,[int]$Port,[int]$TimeoutMs=1200){
  $c=New-Object Net.Sockets.TcpClient
  try{$ar=$c.BeginConnect($HostName,$Port,$null,$null);if(-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs,$false)){return $false};$c.EndConnect($ar);return $true}catch{return $false}finally{try{$c.Close()}catch{}}
}
function Send-H3Wake {
  $bytes=$h3Mac -split '[:-]'|ForEach-Object {[Convert]::ToByte($_,16)}
  $packet=New-Object byte[] 102
  0..5|ForEach-Object {$packet[$_]=0xFF}
  for($i=1;$i -le 16;$i++){[Array]::Copy($bytes,0,$packet,6+(($i-1)*6),6)}
  $client=New-Object Net.Sockets.UdpClient
  try{$client.EnableBroadcast=$true;foreach($round in 1..5){foreach($port in @(9,7)){$ep=New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($broadcast)),$port;[void]$client.Send($packet,$packet.Length,$ep)};Start-Sleep -Milliseconds 400}}finally{$client.Dispose()}
}
function Invoke-H3([string]$RemoteScript){
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''35B post-return recovery stdin was empty.''};Invoke-Expression $script'
  $bootstrapEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$bootstrapEncoded)
  $inFile=Join-Path $env:TEMP ('afz-qwen35b-postreturn-in-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('afz-qwen35b-postreturn-out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $errFile=Join-Path $env:TEMP ('afz-qwen35b-postreturn-err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    [IO.File]::WriteAllText($inFile,$RemoteScript,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(90000)){try{$p.Kill()}catch{};throw 'H3 post-return bootstrap timed out after 90 seconds.'}
    return [ordered]@{exit=[int]$p.ExitCode;stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile)}else{''});stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile)}else{''})}
  }finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}

try{
  if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only recovery; host=$env:COMPUTERNAME"}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  if([string]$identity.User.Value -ne 'S-1-5-18'){throw "35B post-return recovery must run as SYSTEM; identity=$([string]$identity.Name)"}
  foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required path missing: $p"}}

  $remoteState=Read-Json $mirrorState
  if(-not $remoteState){Save-State ([ordered]@{schema=1;status='not-ready';classification='QWEN35B_POSTRETURN_MIRROR_STATE_MISSING';jobId=$jobId;modelCallIssuedByRecovery=$false;time=(Get-Date -Format o)});exit 0}
  if([string]$remoteState.status -eq 'completed'){
    Save-State ([ordered]@{schema=1;status='completed';classification='QWEN35B_POSTRETURN_ALREADY_COMPLETED';jobId=$jobId;modelCallIssuedByRecovery=$false;remoteState=$remoteState;time=(Get-Date -Format o)});exit 0
  }
  if([string]$remoteState.phase -eq 'recovery_failed'){
    Save-State ([ordered]@{schema=1;status='failed';classification='QWEN35B_POSTRETURN_RECOVERY_FAILED_ON_H3';jobId=$jobId;modelCallIssuedByRecovery=$false;remoteState=$remoteState;time=(Get-Date -Format o)});exit 20
  }
  if(-not [bool]$remoteState.model_call_attempted -or [string]$remoteState.phase -ne 'ollama_post_returned' -or [int]$remoteState.curl_exit -ne 0){
    Save-State ([ordered]@{schema=1;status='not-ready';classification='QWEN35B_POSTRETURN_GUARD_NOT_SATISFIED';jobId=$jobId;modelCallIssuedByRecovery=$false;remoteState=$remoteState;time=(Get-Date -Format o)});exit 0
  }

  $prior=Read-Json $statePath
  if($prior -and [string]$prior.jobId -eq $jobId -and [string]$prior.status -eq 'started'){
    Save-State $prior;exit 0
  }

  if(-not(Test-Tcp $h3Ip 22 1200)){Send-H3Wake}
  $online=$false
  for($i=1;$i -le 90;$i++){if(Test-Tcp $h3Ip 22 1200){$online=$true;break};if($i -in @(30,60)){try{Send-H3Wake}catch{}};Start-Sleep -Seconds 2}
  if(-not $online){throw 'H3 Tailscale SSH did not become reachable within the bounded Wake-on-LAN window.'}

  $recoveryUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$recoverySha/afz-openai-agent/tools/Recover-H3-Qwen35BA3B-PostReturn.ps1"
  $remote=@"
`$ErrorActionPreference='Stop'
if(`$env:COMPUTERNAME -ne '$expectedHost'){throw "Wrong host: `$env:COMPUTERNAME"}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
`$root='C:\ProgramData\AFZ\H3Qwen35BA3B'
New-Item -ItemType Directory -Force -Path `$root|Out-Null
`$scriptPath=Join-Path `$root 'Recover-H3-Qwen35BA3B-PostReturn.ps1'
Invoke-WebRequest -Uri '$recoveryUrl' -OutFile `$scriptPath -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-Qwen35B-PostReturn';'Cache-Control'='no-cache';'Pragma'='no-cache'} -TimeoutSec 60
`$tokens=`$null;`$errors=`$null
[void][System.Management.Automation.Language.Parser]::ParseFile(`$scriptPath,[ref]`$tokens,[ref]`$errors)
if(`$errors.Count -gt 0){throw ('post-return recovery parse failure: '+(`$errors.Message -join '; '))}
`$text=[IO.File]::ReadAllText(`$scriptPath)
if(`$text -match '127\.0\.0\.1:11434/api/generate' -or `$text -match '(?i)\bcurl(?:\.exe)?\b' -or `$text -match '(?im)^\s*[&]?\s*ollama(?:\.exe)?\s'){throw 'Forbidden model-call primitive found in post-return recovery.'}
`$taskName='AFZ H3 Qwen35B A3B PostReturn Recovery'
`$arg="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ```"`$scriptPath```""
`$existing=Get-ScheduledTask -TaskName `$taskName -ErrorAction SilentlyContinue
if(`$existing){
  `$info=Get-ScheduledTaskInfo -TaskName `$taskName -ErrorAction SilentlyContinue
  `$lastResult=`$null
  if(`$info){`$lastResult=[int64]`$info.LastTaskResult}
  [pscustomobject]@{ok=`$true;already=`$true;task=`$taskName;state=[string]`$existing.State;lastResult=`$lastResult;script=`$scriptPath;recoverySha='$recoverySha'}|ConvertTo-Json -Compress
  exit 0
}
`$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument `$arg
`$principal=New-ScheduledTaskPrincipal -UserId 'Faiz' -LogonType Interactive -RunLevel Highest
`$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
Register-ScheduledTask -TaskName `$taskName -Action `$action -Principal `$principal -Settings `$settings -Force|Out-Null
Start-ScheduledTask -TaskName `$taskName
[pscustomobject]@{ok=`$true;already=`$false;task=`$taskName;state='started';script=`$scriptPath;recoverySha='$recoverySha'}|ConvertTo-Json -Compress
"@
  $r=Invoke-H3 $remote
  if([int]$r.exit -ne 0){throw "H3 post-return bootstrap failed exit=$($r.exit) stdout=$($r.stdout) stderr=$($r.stderr)"}
  $jsonLine=@(([string]$r.stdout -split "`r?`n")|Where-Object {$_.Trim() -match '^\{.*\}$'}|Select-Object -Last 1)
  if(-not $jsonLine){throw "H3 post-return bootstrap returned no JSON. stdout=$($r.stdout) stderr=$($r.stderr)"}
  $proof=([string]$jsonLine).Trim()|ConvertFrom-Json -ErrorAction Stop
  if(-not [bool]$proof.ok){throw 'H3 post-return bootstrap returned ok=false.'}
  Save-State ([ordered]@{schema=1;status='started';classification='QWEN35B_POSTRETURN_RECOVERY_STARTED_FROM_SAVED_RESPONSE';jobId=$jobId;recoverySha=$recoverySha;modelCallIssuedByRecovery=$false;h3Proof=$proof;time=(Get-Date -Format o)})
  exit 0
}catch{
  Save-State ([ordered]@{schema=1;status='failed';classification='QWEN35B_POSTRETURN_SYSTEM_CARRIER_FAILED';jobId=$jobId;recoverySha=$recoverySha;modelCallIssuedByRecovery=$false;error=$_.Exception.Message;detail=($_|Out-String).Trim();time=(Get-Date -Format o)})
  exit 20
}
