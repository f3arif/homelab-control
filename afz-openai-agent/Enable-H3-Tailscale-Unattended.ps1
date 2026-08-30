#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$RequestPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-tailscale-unattended'
$statePath=Join-Path $stateRoot 'generation-1.json'
$latestPath=Join-Path $stateRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'H3-TAILSCALE-UNATTENDED-LATEST.json'
$mirrorTextPath=Join-Path $mirrorRoot 'H3-TAILSCALE-UNATTENDED-LATEST.txt'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$key='C:\Users\Faiz\.ssh\afz_h3_worker'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$expectedHost='DESKTOP-H3R6CQN'
$lanIp='192.168.50.185'
$tailscaleIp='100.106.186.118'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Save-Result($obj){
  $json=$obj | ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  [IO.File]::WriteAllText($latestPath,$json,$utf8)
  try{
    if(Test-Path -LiteralPath $mirrorRoot -PathType Container){
      [IO.File]::WriteAllText($mirrorPath,$json,$utf8)
      [IO.File]::WriteAllText($mirrorTextPath,$json,$utf8)
    }
  }catch{}
  Write-Output ($obj | ConvertTo-Json -Depth 12 -Compress)
}

if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "Request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if([int]$req.schema -ne 1){throw 'Unsupported request schema'}
if([string]$req.project -ne 'afz-infrastructure'){throw 'Unsupported project'}
if([string]$req.action -ne 'h3-enable-tailscale-unattended'){throw 'Unsupported action'}
if([int]$req.generation -ne 1){throw 'Unsupported generation'}
if([string]$req.status -ne 'active'){throw 'Request is not active'}
if([string]$req.target.hostname -ne $expectedHost -or [string]$req.target.lanIp -ne $lanIp -or [string]$req.target.tailscaleIp -ne $tailscaleIp){throw 'H3 target identity mismatch'}
if([string]$req.expected.unattendedPolicy -ne 'always' -or [string]$req.expected.tailscaleIp -ne $tailscaleIp){throw 'Expected-state mismatch'}

if(Test-Path -LiteralPath $statePath -PathType Leaf){
  try{
    $priorState=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if([string]$priorState.status -eq 'completed'){
      Save-Result $priorState
      exit 0
    }
  }catch{}
}

foreach($required in @($ssh,$key,$known)){
  if(-not(Test-Path -LiteralPath $required -PathType Leaf)){
    $r=[ordered]@{schema=1;generation=1;status='failed';classification='H3_TAILSCALE_PREREQUISITE_MISSING';missing=$required;target=$expectedHost;time=(Get-Date -Format o)}
    Save-Result $r
    exit 20
  }
}

$remote=@'
$ErrorActionPreference='Stop'
$policyPath='HKLM:\SOFTWARE\Policies\Tailscale'
$ts='C:\Program Files\Tailscale\tailscale.exe'
if(-not(Test-Path -LiteralPath $ts -PathType Leaf)){throw 'tailscale.exe missing'}
$prior=$null
try{$prior=[string](Get-ItemProperty -LiteralPath $policyPath -Name UnattendedMode -ErrorAction Stop).UnattendedMode}catch{}
New-Item -Path $policyPath -Force | Out-Null
New-ItemProperty -Path $policyPath -Name UnattendedMode -PropertyType String -Value 'always' -Force | Out-Null
$reload=(& $ts syspolicy reload 2>&1 | Out-String).Trim()
$reloadExit=$LASTEXITCODE
$ip=(& $ts ip -4 2>&1 | Out-String).Trim()
$policy=(& $ts syspolicy list 2>&1 | Out-String)
$policyLine=(($policy -split "`r?`n") | Where-Object {$_ -match '^\s*UnattendedMode\s+'} | Select-Object -First 1)
$svc=Get-Service Tailscale -ErrorAction Stop
$ok=($reloadExit -eq 0 -and $ip -eq '100.106.186.118' -and [string]$policyLine -match '\balways\b' -and [string]$svc.Status -eq 'Running')
[ordered]@{ok=$ok;host=$env:COMPUTERNAME;priorUnattendedMode=$prior;unattendedPolicy='always';policyLine=[string]$policyLine;tailscaleIp=$ip;serviceStatus=[string]$svc.Status;reloadExit=$reloadExit;reloadOutput=$reload} | ConvertTo-Json -Compress
if(-not $ok){exit 31}
'@
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))

$attempts=@(
  [ordered]@{transport='lan';target=('Faiz@'+$lanIp);hostKeyAlias=$tailscaleIp},
  [ordered]@{transport='tailscale';target=('Faiz@'+$tailscaleIp);hostKeyAlias=$null}
)
$attemptResults=@()
$success=$null
foreach($a in $attempts){
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',("UserKnownHostsFile="+$known))
  if($a.hostKeyAlias){$args+=@('-o',('HostKeyAlias='+$a.hostKeyAlias))}
  $args+=@($a.target,'powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',$encoded)
  $out=@(& $ssh @args 2>&1)
  $code=$LASTEXITCODE
  $text=($out | Out-String).Trim()
  $parsed=$null
  if($code -eq 0 -and $text){try{$parsed=$text | ConvertFrom-Json}catch{}}
  $entry=[ordered]@{transport=$a.transport;exitCode=$code;parsed=($null -ne $parsed);output=$(if($parsed){$parsed}else{$text.Substring(0,[math]::Min(3000,$text.Length))})}
  $attemptResults+=$entry
  if($code -eq 0 -and $parsed -and [bool]$parsed.ok){$success=[ordered]@{transport=$a.transport;result=$parsed};break}
}

if($success){
  $r=[ordered]@{schema=1;generation=1;status='completed';classification='H3_TAILSCALE_UNATTENDED_ENABLED_AND_VERIFIED';target=$expectedHost;lanIp=$lanIp;tailscaleIp=$tailscaleIp;transportUsed=$success.transport;result=$success.result;attempts=$attemptResults;controlPlane='github';time=(Get-Date -Format o)}
  Save-Result $r
  exit 0
}

$r=[ordered]@{schema=1;generation=1;status='failed';classification='H3_TAILSCALE_UNATTENDED_ENABLE_FAILED';target=$expectedHost;lanIp=$lanIp;tailscaleIp=$tailscaleIp;attempts=$attemptResults;controlPlane='github';time=(Get-Date -Format o)}
Save-Result $r
exit 30
