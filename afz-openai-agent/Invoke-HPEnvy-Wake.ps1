#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$FixedTarget='hpenvy'
$FixedMac='8c:dc:d4:87:9d:19'
$FixedLanIp='192.168.50.185'
$AllowedBroadcasts=@('192.168.50.255','255.255.255.255')
$AllowedPorts=@(9,7)
$StateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\hpenvy-wake'
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

if([string]::IsNullOrWhiteSpace($RequestPath)){throw 'RequestPath is required'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "Request missing: $RequestPath"}
$r=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$r.id).Trim()
$status=([string]$r.status).Trim().ToUpperInvariant()
$action=([string]$r.action).Trim().ToLowerInvariant()
$target=([string]$r.target).Trim().ToLowerInvariant()
$mac=([string]$r.mac).Trim().ToLowerInvariant()
$lanIp=([string]$r.lanIp).Trim()
if($id -notmatch '^hpenvy-wake-[A-Za-z0-9._-]+$'){throw 'Invalid request id'}
if($status -ne 'ACTIVE' -or $action -ne 'wake-fixed-target'){throw 'Wake request is not active/fixed-target'}
if($target -ne $FixedTarget -or $mac -ne $FixedMac -or $lanIp -ne $FixedLanIp){throw 'HP Envy wake request target mismatch'}

$broadcasts=@($r.broadcasts | ForEach-Object {[string]$_})
$ports=@($r.ports | ForEach-Object {[int]$_})
$repeat=[int]$r.repeat
if($repeat -lt 1 -or $repeat -gt 5){throw 'Invalid repeat count'}
if(@($broadcasts | Where-Object {$_ -notin $AllowedBroadcasts}).Count -gt 0){throw 'Unsupported broadcast target'}
if(@($ports | Where-Object {$_ -notin $AllowedPorts}).Count -gt 0){throw 'Unsupported WOL port'}

$statePath=Join-Path $StateRoot ($id+'.json')
if(Test-Path -LiteralPath $statePath -PathType Leaf){
  try{
    $existing=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if([string]$existing.classification -eq 'HPENVY_WOL_SENT'){
      Write-Output ($existing | ConvertTo-Json -Depth 8 -Compress)
      exit 0
    }
  }catch{}
}

$macBytes=[byte[]](($FixedMac -split '[:-]') | ForEach-Object {[Convert]::ToByte($_,16)})
$packet=New-Object byte[] (6 + (16 * 6))
for($i=0;$i -lt 6;$i++){$packet[$i]=0xFF}
for($i=0;$i -lt 16;$i++){[Array]::Copy($macBytes,0,$packet,6+($i*6),6)}
$sent=@()
foreach($bcast in $broadcasts){
  foreach($port in $ports){
    for($n=1;$n -le $repeat;$n++){
      $udp=New-Object System.Net.Sockets.UdpClient
      try{
        $udp.EnableBroadcast=$true
        $count=$udp.Send($packet,$packet.Length,$bcast,$port)
        $sent += [ordered]@{broadcast=$bcast;port=$port;attempt=$n;bytes=$count}
      }finally{$udp.Close()}
      Start-Sleep -Milliseconds 150
    }
  }
}
$result=[ordered]@{
  schema=1;requestId=$id;classification='HPENVY_WOL_SENT';target=$FixedTarget;mac=$FixedMac;lanIp=$FixedLanIp
  packetBytes=$packet.Length;transmissions=@($sent).Count;sent=$sent;sentAt=(Get-Date -Format o)
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
Write-Output ($result | ConvertTo-Json -Depth 8 -Compress)
