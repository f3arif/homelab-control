#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$jobId='qwen35b-a3b-website-20260830-r1'
$expectedHost='DESKTOP-H3R6CQN'
$recoverySha='5817bd2d55275526f3d90b72f93e3c76ea713e40'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$h3Ip='100.106.186.118'
$h3Mac='4C-ED-FB-3F-B0-9E'
$broadcast='192.168.50.255'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-postreturn-v2'
$statePath=Join-Path $stateRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-QWEN35B-POSTRETURN-V2-LATEST.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 40 -Compress
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
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''Qwen35B post-return stdin empty.''};Invoke-Expression $script'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  $tag=[guid]::NewGuid().ToString('n');$inFile=Join-Path $env:TEMP ($tag+'.in.ps1');$outFile=Join-Path $env:TEMP ($tag+'.out.txt');$errFile=Join-Path $env:TEMP ($tag+'.err.txt')
  try{
    [IO.File]::WriteAllText($inFile,$RemoteScript,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(90000)){try{$p.Kill()}catch{};throw 'H3 post-return V2 bootstrap timed out after 90 seconds.'}
    [ordered]@{exit=[int]$p.ExitCode;stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile)}else{''});stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile)}else{''})}
  }finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}

try{
  if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only recovery; host=$env:COMPUTERNAME"}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  if([string]$identity.User.Value -ne 'S-1-5-18'){throw "Qwen35B post-return V2 must run as SYSTEM; identity=$([string]$identity.Name)"}
  foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required path missing: $p"}}

  if(-not(Test-Tcp $h3Ip 22 1200)){Send-H3Wake}
  $online=$false
  for($i=1;$i -le 90;$i++){if(Test-Tcp $h3Ip 22 1200){$online=$true;break};if($i -in @(30,60)){try{Send-H3Wake}catch{}};Start-Sleep -Seconds 2}
  if(-not $online){throw 'H3 Tailscale SSH did not become reachable within bounded WOL window.'}

  $recoveryUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$recoverySha/afz-openai-agent/tools/Recover-H3-Qwen35BA3B-PostReturn.ps1"
  $remote=@"
`$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if(`$env:COMPUTERNAME -ne '$expectedHost'){throw "Wrong host: `$env:COMPUTERNAME"}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
`$jobId='$jobId'
`$statePath='C:\ProgramData\AFZ\H3Qwen35BA3B\$jobId.json'
`$responsePath='C:\Projects\Qwen36-35B-A3B-Website-Test-20260830-r1\AFZ-OLLAMA-RESPONSE.json'
`$resultPath='C:\Projects\Qwen36-35B-A3B-Website-Test-20260830-r1\AFZ-BENCHMARK-RESULT.json'
if(Test-Path -LiteralPath `$resultPath -PathType Leaf){
  `$result=Get-Content -LiteralPath `$resultPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
  [pscustomobject]@{ok=`$true;classification='QWEN35B_ALREADY_COMPLETED';jobId=`$jobId;modelCallIssuedByRecovery=`$false;result=`$result}|ConvertTo-Json -Depth 40 -Compress
  exit 0
}
if(-not(Test-Path -LiteralPath `$statePath -PathType Leaf)){throw "Authoritative state missing: `$statePath"}
if(-not(Test-Path -LiteralPath `$responsePath -PathType Leaf)){throw "Saved Ollama response missing: `$responsePath"}
`$state=Get-Content -LiteralPath `$statePath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
if([string]`$state.job_id -ne `$jobId){throw 'Qwen35B state job id mismatch.'}
`$attempted=`$false;if(`$state.PSObject.Properties.Name -contains 'model_call_attempted'){`$attempted=[bool]`$state.model_call_attempted}
if(-not `$attempted){throw 'Qwen35B post-return recovery refused: model_call_attempted is not true.'}
`$saved=Get-Content -LiteralPath `$responsePath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
`$done=`$false;if(`$saved.PSObject.Properties.Name -contains 'done'){`$done=[bool]`$saved.done}
`$responseText='';if(`$saved.PSObject.Properties.Name -contains 'response'){`$responseText=[string]`$saved.response}
`$hasError=`$false;if(`$saved.PSObject.Properties.Name -contains 'error'){`$hasError=(-not [string]::IsNullOrWhiteSpace([string]`$saved.error))}
if(-not `$done -or `$hasError -or [string]::IsNullOrWhiteSpace(`$responseText)){throw 'Saved Ollama response is not a successful completed response.'}
`$phase=[string]`$state.phase
if(`$phase -notin @('ollama_post_returned','qwen_response_received','files_applied','npm_install','build','smoke','recovery_failed')){throw "Qwen35B post-return recovery refused from phase: `$phase"}

`$root='C:\ProgramData\AFZ\H3Qwen35BA3B';New-Item -ItemType Directory -Force -Path `$root|Out-Null
`$scriptPath=Join-Path `$root 'Recover-H3-Qwen35BA3B-PostReturn.ps1'
Invoke-WebRequest -Uri '$recoveryUrl' -OutFile `$scriptPath -UseBasicParsing -Headers @{'User-Agent'='AFZ-Qwen35B-PostReturn-V2';'Cache-Control'='no-cache';'Pragma'='no-cache'} -TimeoutSec 60
`$tokens=`$null;`$errors=`$null;[void][System.Management.Automation.Language.Parser]::ParseFile(`$scriptPath,[ref]`$tokens,[ref]`$errors)
if(`$errors.Count -gt 0){throw ('Recovery script parse failure: '+(`$errors.Message -join '; '))}
`$text=[IO.File]::ReadAllText(`$scriptPath)
if(`$text -match '127\.0\.0\.1:11434/api/generate' -or `$text -match '(?i)\bcurl(?:\.exe)?\b' -or `$text -match '(?im)^\s*[&]?\s*ollama(?:\.exe)?\s'){throw 'Forbidden model-call primitive found in post-return recovery.'}

`$taskName='AFZ H3 Qwen35B A3B PostReturn Recovery'
`$arg="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ```"`$scriptPath```""
`$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument `$arg
`$principal=New-ScheduledTaskPrincipal -UserId 'Faiz' -LogonType Interactive -RunLevel Highest
`$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
`$existing=Get-ScheduledTask -TaskName `$taskName -ErrorAction SilentlyContinue
if(-not `$existing){Register-ScheduledTask -TaskName `$taskName -Action `$action -Principal `$principal -Settings `$settings -Force|Out-Null;`$actionTaken='REGISTERED'}else{Set-ScheduledTask -TaskName `$taskName -Action `$action -Principal `$principal -Settings `$settings|Out-Null;`$actionTaken='REFRESHED'}
`$current=Get-ScheduledTask -TaskName `$taskName -ErrorAction Stop
if([string]`$current.State -ne 'Running'){Start-ScheduledTask -TaskName `$taskName;`$actionTaken+='_AND_STARTED'}else{`$actionTaken='ALREADY_RUNNING'}
[pscustomobject]@{ok=`$true;classification='QWEN35B_POSTRETURN_V2_STARTED';jobId=`$jobId;modelCallIssuedByRecovery=`$false;task=`$taskName;taskAction=`$actionTaken;priorPhase=`$phase;recoverySha='$recoverySha'}|ConvertTo-Json -Depth 30 -Compress
"@
  $r=Invoke-H3 $remote
  $jsonLine=@(([string]$r.stdout -split "`r?`n")|Where-Object {$_.Trim() -match '^\{.*\}$'}|Select-Object -Last 1)
  if([int]$r.exit -ne 0){throw "H3 post-return V2 failed exit=$($r.exit) stdout=$($r.stdout) stderr=$($r.stderr)"}
  if(-not $jsonLine){throw "H3 post-return V2 returned no JSON. stdout=$($r.stdout) stderr=$($r.stderr)"}
  $proof=([string]$jsonLine).Trim()|ConvertFrom-Json -ErrorAction Stop
  if(-not [bool]$proof.ok){throw ('H3 post-return V2 returned ok=false: '+[string]$proof.classification)}
  $status=$(if([string]$proof.classification -eq 'QWEN35B_ALREADY_COMPLETED'){'completed'}else{'started'})
  Save-State ([ordered]@{schema=1;ok=$true;status=$status;classification=[string]$proof.classification;jobId=$jobId;modelCallIssuedByRecovery=$false;recoverySha=$recoverySha;h3Proof=$proof;time=(Get-Date -Format o)})
  exit 0
}catch{
  Save-State ([ordered]@{schema=1;ok=$false;status='failed';classification='QWEN35B_POSTRETURN_V2_FAILED';jobId=$jobId;modelCallIssuedByRecovery=$false;recoverySha=$recoverySha;error=$_.Exception.Message;time=(Get-Date -Format o)})
  exit 20
}
