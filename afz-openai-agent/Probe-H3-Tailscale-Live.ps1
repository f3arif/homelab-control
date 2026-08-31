#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$key='C:\Users\Faiz\.ssh\afz_h3_worker'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$target='Faiz@192.168.50.185'
$hostKeyAlias='100.106.186.118'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'H3-TAILSCALE-LIVE-LATEST.txt'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-tailscale-live'
$statePath=Join-Path $stateRoot 'latest.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Save-Result($o){
  $json=$o | ConvertTo-Json -Depth 14
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  Write-Output ($o | ConvertTo-Json -Depth 14 -Compress)
}

foreach($p in @($ssh,$key,$known)){
  if(-not(Test-Path -LiteralPath $p -PathType Leaf)){
    Save-Result ([ordered]@{schema=1;status='failed';classification='H3_LIVE_PROBE_LOCAL_PREREQUISITE_MISSING';missing=$p;time=(Get-Date -Format o)})
    exit 20
  }
}

$remote=@'
$ErrorActionPreference='Continue'
$ts='C:\Program Files\Tailscale\tailscale.exe'
$r=[ordered]@{}
$r.time=Get-Date -Format o
$r.host=$env:COMPUTERNAME
$os=Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$r.lastBoot=$(if($os){$os.LastBootUpTime}else{$null})
$r.uptimeSeconds=$(if($os){[int]((Get-Date)-$os.LastBootUpTime).TotalSeconds}else{$null})
$svc=Get-Service Tailscale -ErrorAction SilentlyContinue
$r.service=$(if($svc){[ordered]@{status=[string]$svc.Status;startType=[string]$svc.StartType}}else{$null})
$ad=Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {$_.Name -match 'Tailscale' -or $_.InterfaceDescription -match 'Tailscale'} | Select-Object -First 1
$r.adapter=$(if($ad){[ordered]@{name=$ad.Name;status=[string]$ad.Status;linkSpeed=[string]$ad.LinkSpeed}}else{$null})
if(Test-Path -LiteralPath $ts){
  $s=(& $ts status 2>&1 | Out-String).Trim();$r.statusExit=$LASTEXITCODE;$r.status=$s
  $i=(& $ts ip -4 2>&1 | Out-String).Trim();$r.ipExit=$LASTEXITCODE;$r.ip4=$i
  $p=(& $ts syspolicy list 2>&1 | Out-String).Trim();$r.syspolicyExit=$LASTEXITCODE;$r.syspolicy=$p
  $d=(& $ts debug prefs 2>&1 | Out-String).Trim();$r.prefsExit=$LASTEXITCODE;$r.prefs=$d
  $n=(& $ts netcheck 2>&1 | Out-String).Trim();$r.netcheckExit=$LASTEXITCODE;$r.netcheck=$n
}else{$r.tailscaleExeMissing=$true}
$r.recentPowerEvents=@(Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddHours(-24)} -ErrorAction SilentlyContinue | Where-Object {$_.Id -in 1,12,13,42,107,109,506,507} | Select-Object -First 30 TimeCreated,Id,ProviderName,Message)
$r | ConvertTo-Json -Depth 8 -Compress
'@
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
$args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),'-o',('HostKeyAlias='+$hostKeyAlias),$target,'powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',$encoded)
$oldEap=$ErrorActionPreference;$ErrorActionPreference='Continue'
$out=@(& $ssh @args 2>&1);$code=$LASTEXITCODE
$ErrorActionPreference=$oldEap
$text=($out | Out-String).Trim()
$parsed=$null
if($code -eq 0 -and $text){try{$parsed=$text | ConvertFrom-Json}catch{}}
if($parsed){
  $class='H3_TAILSCALE_LIVE_UNKNOWN'
  if([string]$parsed.ip4 -eq '100.106.186.118' -and [string]$parsed.service.status -eq 'Running'){$class='H3_TAILSCALE_LIVE_ONLINE'}
  elseif([string]$parsed.ip4 -match 'NoState|no current Tailscale IPs' -or [string]$parsed.status -match 'NoState'){$class='H3_TAILSCALE_LIVE_NOSTATE'}
  elseif([string]$parsed.service.status -ne 'Running'){$class='H3_TAILSCALE_LIVE_SERVICE_NOT_RUNNING'}
  Save-Result ([ordered]@{schema=1;status='completed';classification=$class;transport='lan';sshExit=$code;live=$parsed;time=(Get-Date -Format o)})
  exit 0
}
Save-Result ([ordered]@{schema=1;status='failed';classification='H3_TAILSCALE_LIVE_PROBE_FAILED';transport='lan';sshExit=$code;output=$text.Substring(0,[math]::Min(6000,$text.Length));time=(Get-Date -Format o)})
exit 30
