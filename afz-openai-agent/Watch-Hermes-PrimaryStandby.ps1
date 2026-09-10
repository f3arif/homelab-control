#Requires -Version 5.1
$ErrorActionPreference='SilentlyContinue'

$stateDir='C:\ProgramData\AFZ\HermesRouting'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$stateFile=Join-Path $stateDir 'health.json'
$logFile=Join-Path $stateDir 'health.log'

$asusTs='100.70.25.8'
$asusLan='192.168.50.94'
$asusMac='40-B0-76-3D-F4-1'
$broadcast='192.168.50.255'

function Test-Tcp([string]$HostName,[int]$Port,[int]$TimeoutMs=1200){
  $c=New-Object Net.Sockets.TcpClient
  try{
    $ar=$c.BeginConnect($HostName,$Port,$null,$null)
    $ok=$ar.AsyncWaitHandle.WaitOne($TimeoutMs,$false) -and $c.Connected
    if($ok){$c.EndConnect($ar)}
    return [bool]$ok
  }catch{return $false}
  finally{$c.Close()}
}

function Test-AsusPing {
  try{
    $raw=(& tailscale.exe ping --timeout=3s -c 1 $asusTs 2>&1 | Out-String)
    return [bool]($raw -match '(?i)\bpong from\b')
  }catch{return $false}
}

function Send-AsusWol {
  try{
    $bytes=$asusMac -split '[:-]' | ForEach-Object {[Convert]::ToByte($_,16)}
    $packet=New-Object byte[] 102
    0..5 | ForEach-Object {$packet[$_]=0xFF}
    for($i=1;$i -le 16;$i++){[Array]::Copy($bytes,0,$packet,6+(($i-1)*6),6)}
    $u=New-Object Net.Sockets.UdpClient
    try{
      $u.EnableBroadcast=$true
      foreach($port in 9,7){
        $ep=New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($broadcast)),$port
        [void]$u.Send($packet,$packet.Length,$ep)
      }
    }finally{$u.Dispose()}
    return $true
  }catch{return $false}
}

$gatewayRaw=(& hermes gateway status 2>&1 | Out-String)
$gatewayOk=[bool]($gatewayRaw -match '(?i)Gateway process running')
$routerExists=Test-Path 'C:\Projects\HermesRouter\hermes_route.py'
$ollamaOk=$false
try{
  $v=Invoke-RestMethod http://127.0.0.1:11434/api/version -TimeoutSec 3
  $ollamaOk=[bool]$v.version
}catch{}

$asusPing=Test-AsusPing
$wolSent=$false
if(-not $asusPing){
  $wolSent=Send-AsusWol
  if($wolSent){
    Start-Sleep -Seconds 5
    $asusPing=Test-AsusPing
  }
}
$asus8796=Test-Tcp $asusTs 8796
$asus8797=Test-Tcp $asusTs 8797
$asus22=Test-Tcp $asusTs 22
$asusWinRm=Test-Tcp $asusLan 5985

$primaryReady=($gatewayOk -and $routerExists -and $ollamaOk)
$standbyNetworkReady=($asusPing -and $asus8796)
$standbyControlReady=$asus8797
$standbyReady=($standbyNetworkReady -and $standbyControlReady)
$classification=if($primaryReady -and $standbyReady){'PRIMARY_AND_STANDBY_READY'}elseif($primaryReady -and $standbyNetworkReady){'PRIMARY_READY_STANDBY_CONTROL_DEGRADED'}elseif($primaryReady){'PRIMARY_READY_STANDBY_OFFLINE'}elseif($standbyReady){'PRIMARY_DEGRADED_STANDBY_READY'}else{'BOTH_DEGRADED'}

$state=[ordered]@{
  schema=1
  time=(Get-Date -Format o)
  host='DESKTOP-H3R6CQN'
  role='primary'
  classification=$classification
  primary=[ordered]@{
    ready=$primaryReady
    hermesGateway=$gatewayOk
    router=$routerExists
    ollama=$ollamaOk
    localModel='qwen3.6:35b-a3b-hermes64k'
  }
  standby=[ordered]@{
    host='DESKTOP-10SKF0M'
    ready=$standbyReady
    networkReady=$standbyNetworkReady
    controlReady=$standbyControlReady
    tailscale=$asusPing
    agent8796=$asus8796
    control8797=$asus8797
    ssh22=$asus22
    winrm5985=$asusWinRm
    wakeOnLanSent=$wolSent
  }
}
$json=$state | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($stateFile,$json,(New-Object Text.UTF8Encoding($false)))
Add-Content -LiteralPath $logFile -Value ("$(Get-Date -Format o) $classification primary=$primaryReady standby=$standbyReady wol=$wolSent") -Encoding UTF8
Write-Output $json
if($primaryReady){exit 0}else{exit 2}