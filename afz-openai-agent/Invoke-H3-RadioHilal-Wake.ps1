#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)

$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){
  throw "This wake helper is windows-main only; actual=$($env:COMPUTERNAME)"
}
if([string]::IsNullOrWhiteSpace($RequestPath)){
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-radiohilal-wake.json'
}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "Request missing: $RequestPath"}
$r=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$r.id).Trim()
if([int]$r.schema -ne 1){throw 'Invalid schema'}
if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid id'}
if([string]$r.action -ne 'wake-h3-for-radiohilal-cron-repair'){throw 'Invalid action'}
if([string]$r.status -ne 'ACTIVE'){throw 'Request is not ACTIVE'}
if([string]$r.target.host -ne 'DESKTOP-H3R6CQN'){throw 'Invalid target host'}
if([string]$r.target.tailscaleIp -ne '100.106.186.118'){throw 'Invalid target Tailscale IP'}
if([string]$r.target.lanIp -ne '192.168.50.185'){throw 'Invalid target LAN IP'}
if([string]$r.target.mac -ne '4C-ED-FB-3F-B0-9E'){throw 'Invalid target MAC'}
if([string]$r.target.broadcast -ne '192.168.50.255'){throw 'Invalid target broadcast'}

$mac=[string]$r.target.mac
$broadcast=[string]$r.target.broadcast
$lanIp=[string]$r.target.lanIp
$tsIp=[string]$r.target.tailscaleIp
$macBytes=[byte[]](($mac -split '[:-]')|ForEach-Object{[Convert]::ToByte($_,16)})
$packet=New-Object byte[] 102
0..5|ForEach-Object{$packet[$_]=0xFF}
for($i=0;$i -lt 16;$i++){[Array]::Copy($macBytes,0,$packet,6+($i*6),6)}

$sent=@()
$udp=New-Object Net.Sockets.UdpClient
$udp.EnableBroadcast=$true
try{
  foreach($target in @($broadcast,$lanIp,'255.255.255.255')){
    foreach($port in @(9,7)){
      foreach($attempt in 1..3){
        try{
          $n=$udp.Send($packet,$packet.Length,$target,$port)
          $sent += [ordered]@{target=$target;port=$port;attempt=$attempt;bytes=$n}
        }catch{
          $sent += [ordered]@{target=$target;port=$port;attempt=$attempt;error=$_.Exception.Message}
        }
        Start-Sleep -Milliseconds 150
      }
    }
  }
}finally{$udp.Close()}

$tailscaleCandidates=@(
  'C:\Program Files\Tailscale\tailscale.exe',
  'C:\Program Files (x86)\Tailscale\tailscale.exe'
)
$tailscale=($tailscaleCandidates|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1)
if(-not $tailscale){
  try{$tailscale=(Get-Command tailscale.exe -ErrorAction Stop).Source}catch{}
}

$online=$false
$ssh22=$false
$attempts=0
for($i=1;$i -le 30;$i++){
  $attempts=$i
  if($tailscale){
    & $tailscale ping --timeout=3s --c=1 $tsIp *> $null
    if($LASTEXITCODE -eq 0){$online=$true}
  }
  try{
    $ssh22=[bool](Test-NetConnection -ComputerName $tsIp -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue)
  }catch{$ssh22=$false}
  if($online -and $ssh22){break}
  Start-Sleep -Seconds 4
}

[ordered]@{
  schema=1
  id=$id
  ok=($online -and $ssh22)
  classification=$(if($online -and $ssh22){'H3_WOL_READY'}elseif($online){'H3_TAILSCALE_UP_SSH_NOT_READY'}else{'H3_WOL_SENT_NOT_READY'})
  sourceHost=$env:COMPUTERNAME
  targetHost='DESKTOP-H3R6CQN'
  tailscaleReachable=$online
  ssh22Reachable=$ssh22
  attempts=$attempts
  packetAttempts=@($sent).Count
  timestamp=(Get-Date -Format o)
}|ConvertTo-Json -Depth 8 -Compress
if(-not($online -and $ssh22)){exit 2}
