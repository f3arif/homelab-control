#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId,
  [ValidateSet('Bootstrap','Carrier')][string]$Mode='Bootstrap'
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only recovery transport; host=$env:COMPUTERNAME"}
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha required.'}
if($JobId -ne 'afz-blog-qwen35b-vs-ridge27b-20260902-r1'){throw 'Unexpected job id.'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()
$root='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-afz-blog-model-comparison-recovery'
$resultFile=Join-Path $root ($JobId+'.json')
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root|Out-Null
function Save([bool]$Ok,[string]$Status,[string]$Message,$Extra=$null){$o=[ordered]@{ok=$Ok;status=$Status;message=$Message;jobId=$JobId;expectedSha=$ExpectedSha;mode=$Mode;target='DESKTOP-H3R6CQN';modelReplay35B=$false;ridgeCallAllowedOnlyIfUnattempted=$true;updatedAt=(Get-Date -Format o)};if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}};[IO.File]::WriteAllText($resultFile,($o|ConvertTo-Json -Depth 20 -Compress),$utf8)}
function ReadResult{if(Test-Path $resultFile){try{return Get-Content $resultFile -Raw|ConvertFrom-Json}catch{}};return $null}
function Capture([string]$File,[string[]]$Args,[int]$Timeout=180){$tag=[guid]::NewGuid().ToString('N');$o=Join-Path $env:TEMP ($tag+'.out');$e=Join-Path $env:TEMP ($tag+'.err');try{$p=Start-Process -FilePath $File -ArgumentList $Args -PassThru -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e;if(-not $p.WaitForExit($Timeout*1000)){try{$p.Kill()}catch{};throw "timeout ${Timeout}s"};return [pscustomobject]@{ExitCode=[int]$p.ExitCode;StdOut=$(if(Test-Path $o){Get-Content $o -Raw}else{''});StdErr=$(if(Test-Path $e){Get-Content $e -Raw}else{''})}}finally{Remove-Item $o,$e -Force -ErrorAction SilentlyContinue}}
function Wake-H3{$mac='4C-ED-FB-3F-B0-9E';$bytes=$mac -split '[:-]'|ForEach-Object{[Convert]::ToByte($_,16)};$packet=New-Object byte[] 102;0..5|ForEach-Object{$packet[$_]=0xFF};for($i=1;$i -le 16;$i++){[Array]::Copy($bytes,0,$packet,6+(($i-1)*6),6)};$c=New-Object Net.Sockets.UdpClient;try{$c.EnableBroadcast=$true;foreach($round in 1..4){foreach($port in @(9,7)){$ep=New-Object Net.IPEndPoint ([Net.IPAddress]::Parse('192.168.50.255')),$port;[void]$c.Send($packet,$packet.Length,$ep)};Start-Sleep -Milliseconds 400}}finally{$c.Dispose()}}

if($Mode -eq 'Bootstrap'){
  $taskName='AFZ H3 AFZ Blog Recovery Transport'
  $sourceTask=Get-ScheduledTask -TaskName 'AFZ Edge Backup' -ErrorAction Stop
  if(([string]$sourceTask.Principal.LogonType) -notmatch 'Interactive'){throw 'AFZ Edge Backup principal is not Interactive.'}
  $scriptPath=$MyInvocation.MyCommand.Path
  Remove-Item $resultFile -Force -ErrorAction SilentlyContinue
  $arg="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -ExpectedSha `"$ExpectedSha`" -JobId `"$JobId`" -Mode Carrier"
  $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
  $existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if($existing -and $existing.State -eq 'Running'){throw "$taskName already running."}
  Register-ScheduledTask -TaskName $taskName -Action $action -Principal $sourceTask.Principal -Settings $settings -Force|Out-Null
  Start-ScheduledTask -TaskName $taskName
  $deadline=(Get-Date).AddMinutes(5)
  do{Start-Sleep -Seconds 2;$r=ReadResult;if($r -and [string]$r.mode -eq 'Carrier' -and [string]$r.status -in @('completed','failed')){break}}while((Get-Date) -lt $deadline)
  $r=ReadResult;if(-not $r){throw 'Recovery carrier returned no result.'};if(-not [bool]$r.ok){throw ([string]$r.message)}
  Write-Output ('AFZ_BLOG_RECOVERY_BOOTSTRAP_JSON='+($r|ConvertTo-Json -Depth 20 -Compress));exit 0
}

try{
  Save $false 'running' 'Interactive carrier starting; waking H3 if needed.'
  try{Wake-H3}catch{}
  $online=$false;foreach($i in 1..30){foreach($ip in @('100.106.186.118','192.168.50.185','192.168.50.213')){if(Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue){$online=$true;break}};if($online){break};Start-Sleep -Seconds 3};if(-not $online){throw 'H3 did not become reachable.'}
  $key='C:\Users\Faiz\.ssh\afz_h3_worker';$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts';if(-not(Test-Path $key)){throw 'H3 SSH key missing.'};if(-not(Test-Path $known)){throw 'H3 known-hosts missing.'}
  $launcherUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/Launch-H3-AFZBlog-ModelComparisonRecovery.ps1"
  $remote=@"
`$ErrorActionPreference='Stop'
if(`$env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: `$env:COMPUTERNAME"}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
`$tmp=Join-Path `$env:TEMP 'AFZ-Blog-Recovery-Launch-$ExpectedSha.ps1'
try {
  Invoke-WebRequest -Uri '$launcherUrl' -OutFile `$tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-Blog-Recovery-Carrier';'Cache-Control'='no-cache'} -TimeoutSec 60
  `$tokens=`$null;`$errors=`$null;[void][System.Management.Automation.Language.Parser]::ParseFile(`$tmp,[ref]`$tokens,[ref]`$errors);if(`$errors.Count){throw ('Launcher parse failure: '+(`$errors.Message -join '; '))}
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `$tmp -ExpectedSha '$ExpectedSha' -JobId '$JobId'
  exit `$LASTEXITCODE
} finally { Remove-Item `$tmp -Force -ErrorAction SilentlyContinue }
"@
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
  $ssh=(Get-Command ssh.exe -ErrorAction Stop).Source
  $args=@('-i',$key,'-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),'Faiz@100.106.186.118','powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',$encoded)
  $r=Capture $ssh $args 180
  if($r.ExitCode -ne 0){throw "H3 recovery SSH failed exit=$($r.ExitCode) stderr=$($r.StdErr) stdout=$($r.StdOut)"}
  $line=@(($r.StdOut -split '\r?\n')|Where-Object{$_ -match '^\{.*\}$'}|Select-Object -Last 1);if(-not $line){throw "No H3 recovery launch JSON. stdout=$($r.StdOut)"}
  $extra=$line|ConvertFrom-Json;if(-not [bool]$extra.ok){throw 'H3 recovery launcher returned ok=false.'}
  Save $true 'completed' 'H3 guarded blog-comparison recovery launched.' $extra
  Write-Output ($extra|ConvertTo-Json -Compress);exit 0
}catch{$msg=$_.Exception.Message;Save $false 'failed' $msg;Write-Error $msg;exit 1}
