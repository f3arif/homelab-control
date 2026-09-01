#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

$JobId='qwen35b-a3b-website-20260830-r1-repair01'
$Model='qwen3.6:35b-a3b'
$ExpectedHost='DESKTOP-H3R6CQN'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$h3Ip='100.106.186.118'
$h3Mac='4C-ED-FB-3F-B0-9E'
$broadcast='192.168.50.255'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-repair01'
$statePath=Join-Path $stateRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-QWEN35B-REPAIR01-LATEST.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-State($o){$json=$o|ConvertTo-Json -Depth 40 -Compress;[IO.File]::WriteAllText($statePath,$json,$utf8);try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{};Write-Output $json}
function Test-Tcp([string]$HostName,[int]$Port,[int]$TimeoutMs=1200){$c=New-Object Net.Sockets.TcpClient;try{$ar=$c.BeginConnect($HostName,$Port,$null,$null);if(-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs,$false)){return $false};$c.EndConnect($ar);return $true}catch{return $false}finally{try{$c.Close()}catch{}}}
function Send-H3Wake{
  $bytes=$h3Mac -split '[:-]'|ForEach-Object {[Convert]::ToByte($_,16)};$packet=New-Object byte[] 102;0..5|ForEach-Object {$packet[$_]=0xFF};for($i=1;$i -le 16;$i++){[Array]::Copy($bytes,0,$packet,6+(($i-1)*6),6)}
  $client=New-Object Net.Sockets.UdpClient;try{$client.EnableBroadcast=$true;foreach($round in 1..5){foreach($port in @(9,7)){$ep=New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($broadcast)),$port;[void]$client.Send($packet,$packet.Length,$ep)};Start-Sleep -Milliseconds 400}}finally{$client.Dispose()}
}
function Invoke-H3([string]$RemoteScript){
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''Qwen35B repair stdin empty.''};Invoke-Expression $script';$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  $tag=[guid]::NewGuid().ToString('n');$inFile=Join-Path $env:TEMP ($tag+'.in.ps1');$outFile=Join-Path $env:TEMP ($tag+'.out.txt');$errFile=Join-Path $env:TEMP ($tag+'.err.txt')
  try{[IO.File]::WriteAllText($inFile,$RemoteScript,$utf8);$p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden;if(-not $p.WaitForExit(120000)){try{$p.Kill()}catch{};throw 'H3 repair bootstrap timed out after 120 seconds.'};[ordered]@{exit=[int]$p.ExitCode;stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile)}else{''});stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile)}else{''})}}finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}

try{
  if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only repair launcher; host=$env:COMPUTERNAME"}
  if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha must be an exact 40-character commit SHA.'};$ExpectedSha=$ExpectedSha.ToLowerInvariant()
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent();if([string]$identity.User.Value -ne 'S-1-5-18'){throw "Qwen35B repair launcher requires SYSTEM; identity=$([string]$identity.Name)"}
  foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required path missing: $p"}}

  if(-not(Test-Tcp $h3Ip 22 1200)){Send-H3Wake}
  $online=$false;for($i=1;$i -le 90;$i++){if(Test-Tcp $h3Ip 22 1200){$online=$true;break};if($i -in @(30,60)){try{Send-H3Wake}catch{}};Start-Sleep -Seconds 2};if(-not $online){throw 'H3 Tailscale SSH did not become reachable within bounded WOL window.'}

  $runnerUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/Start-H3-Qwen35BA3B-WebsiteRepair01.ps1"
  $remote=@"
`$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
if(`$env:COMPUTERNAME -ne '$ExpectedHost'){throw "Wrong host: `$env:COMPUTERNAME"}
`$jobId='$JobId';`$statePath='C:\ProgramData\AFZ\H3Qwen35BA3BRepair\$JobId.json';`$taskName='AFZ H3 Qwen35B A3B Repair01'
function Read-State{if(-not(Test-Path -LiteralPath `$statePath -PathType Leaf)){return `$null};try{return Get-Content -LiteralPath `$statePath -Raw -Encoding UTF8|ConvertFrom-Json}catch{return `$null}}
`$prior=Read-State
if(`$prior){`$attempted=`$false;if(`$prior.PSObject.Properties.Name -contains 'repair_model_call_attempted'){`$attempted=[bool]`$prior.repair_model_call_attempted};if(`$attempted -or [string]`$prior.status -eq 'completed'){[pscustomobject]@{ok=`$true;classification='QWEN35B_REPAIR_ALREADY_STARTED';jobId=`$jobId;state=`$prior}|ConvertTo-Json -Depth 40 -Compress;exit 0}}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
`$root='C:\ProgramData\AFZ\H3Qwen35BA3BRepair';New-Item -ItemType Directory -Force -Path `$root|Out-Null;`$scriptPath=Join-Path `$root 'Start-H3-Qwen35BA3B-WebsiteRepair01.ps1'
Invoke-WebRequest -Uri '$runnerUrl' -OutFile `$scriptPath -UseBasicParsing -Headers @{'User-Agent'='AFZ-Qwen35B-Repair01';'Cache-Control'='no-cache';'Pragma'='no-cache'} -TimeoutSec 60
`$tokens=`$null;`$errors=`$null;[void][System.Management.Automation.Language.Parser]::ParseFile(`$scriptPath,[ref]`$tokens,[ref]`$errors);if(`$errors.Count -gt 0){throw ('Repair runner parse failure: '+(`$errors.Message -join '; '))}
`$text=[IO.File]::ReadAllText(`$scriptPath);if(`$text -notmatch [regex]::Escape('$Model') -or `$text -notmatch 'max_repair_model_calls=1'){throw 'Repair runner contract markers missing.'}
`$arg="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ```"`$scriptPath```" -SourceSha '$ExpectedSha'"
`$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument `$arg
`$userId=[Security.Principal.WindowsIdentity]::GetCurrent().Name
if([string]::IsNullOrWhiteSpace(`$userId) -or `$userId -notmatch '\\'){throw "Unable to resolve authenticated H3 Windows identity: '`$userId'"}
`$principal=New-ScheduledTaskPrincipal -UserId `$userId -LogonType Interactive -RunLevel Highest
`$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
`$existing=Get-ScheduledTask -TaskName `$taskName -ErrorAction SilentlyContinue;if(-not `$existing){Register-ScheduledTask -TaskName `$taskName -Action `$action -Principal `$principal -Settings `$settings -Force|Out-Null}else{Set-ScheduledTask -TaskName `$taskName -Action `$action -Principal `$principal -Settings `$settings|Out-Null}
`$prior=Read-State;if(`$prior){`$attempted=`$false;if(`$prior.PSObject.Properties.Name -contains 'repair_model_call_attempted'){`$attempted=[bool]`$prior.repair_model_call_attempted};if(`$attempted){[pscustomobject]@{ok=`$true;classification='QWEN35B_REPAIR_ALREADY_STARTED';jobId=`$jobId;state=`$prior}|ConvertTo-Json -Depth 40 -Compress;exit 0}}
`$current=Get-ScheduledTask -TaskName `$taskName -ErrorAction Stop;if([string]`$current.State -ne 'Running'){Start-ScheduledTask -TaskName `$taskName}
`$deadline=(Get-Date).AddSeconds(75);do{Start-Sleep -Seconds 1;`$s=Read-State;if(`$s){`$attempted=`$false;if(`$s.PSObject.Properties.Name -contains 'repair_model_call_attempted'){`$attempted=[bool]`$s.repair_model_call_attempted};if(`$attempted -or [string]`$s.status -in @('blocked','failed','completed')){break}}}while((Get-Date)-lt `$deadline)
`$s=Read-State
if(-not `$s){`$current=Get-ScheduledTask -TaskName `$taskName -ErrorAction SilentlyContinue;`$info=Get-ScheduledTaskInfo -TaskName `$taskName -ErrorAction SilentlyContinue;throw "Repair task created but no state appeared within 75 seconds. principal=`$userId taskState=$([string]`$current.State) lastResult=$([string]`$info.LastTaskResult)"}
`$classification='QWEN35B_REPAIR_STATE_READY';if([bool]`$s.repair_model_call_attempted){`$classification='QWEN35B_REPAIR_MODEL_CALL_STARTED'}elseif([string]`$s.status -eq 'blocked'){`$classification='QWEN35B_REPAIR_BLOCKED'}
[pscustomobject]@{ok=`$true;classification=`$classification;jobId=`$jobId;task=`$taskName;principal=`$userId;state=`$s}|ConvertTo-Json -Depth 40 -Compress
"@
  $r=Invoke-H3 $remote;if([int]$r.exit -ne 0){throw "H3 repair launcher failed exit=$($r.exit) stdout=$($r.stdout) stderr=$($r.stderr)"}
  $line=@(([string]$r.stdout -split "`r?`n")|Where-Object {$_.Trim() -match '^\{.*\}$'}|Select-Object -Last 1);if(-not $line){throw "H3 repair launcher returned no JSON. stdout=$($r.stdout) stderr=$($r.stderr)"};$proof=([string]$line).Trim()|ConvertFrom-Json -ErrorAction Stop;if(-not [bool]$proof.ok){throw 'H3 repair launcher returned ok=false.'}
  Save-State ([ordered]@{schema=1;ok=$true;status='completed';classification=[string]$proof.classification;jobId=$JobId;model=$Model;repairModelCallIssued=([string]$proof.classification -eq 'QWEN35B_REPAIR_MODEL_CALL_STARTED');expectedSha=$ExpectedSha;h3Proof=$proof;time=(Get-Date -Format o)});exit 0
}catch{Save-State ([ordered]@{schema=1;ok=$false;status='failed';classification='QWEN35B_REPAIR_LAUNCH_FAILED';jobId=$JobId;model=$Model;repairModelCallIssued=$false;expectedSha=$ExpectedSha;error=$_.Exception.Message;time=(Get-Date -Format o)});exit 20}
