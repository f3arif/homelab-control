#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$root='C:\AFZ\Stremio-Failover-H3'
$python=Join-Path $root '.venv\Scripts\python.exe'
$proxy=Join-Path $root 'afz_lan_proxy.py'
# Persist the byte-pinned device-order edge over restarts.
# If the candidate is missing or differs, launch the original module.
$deviceStage='C:\AFZ\Nuvio-Setup-20260923\device-source-order-20261012\LAN-v2'
$deviceFile=Join-Path $deviceStage 'afz_lan_proxy_device_v2.py'
$deviceSHA='b926a6c6fffb4daa60a5200f26fc4d0499b1bf5331591022bd9365cd34496b0b'
$enableDeviceV2=$false
try{
  if(Test-Path -LiteralPath $deviceFile -PathType Leaf){
    $enableDeviceV2=((Get-FileHash $deviceFile -Algorithm SHA256).Hash.ToLowerInvariant() -eq $deviceSHA)
  }
}catch{$enableDeviceV2=$false}
$module=if($enableDeviceV2){'afz_lan_proxy_device_v2:app'}else{'afz_lan_proxy:app'}
$certDir=Join-Path $root 'certs'
$hostName='desktop-h3r6cqn.tailc9bb62.ts.net'
$crt=Join-Path $certDir ($hostName+'.crt')
$key=Join-Path $certDir ($hostName+'.key')
$stdout=Join-Path $root 'lan-tls-edge.log'
$stderr=Join-Path $root 'lan-tls-edge.err.log'
$pidFile=Join-Path $root 'lan-tls-edge.pid'
$port=8445
$upstream='http://127.0.0.1:18774'
$publicBase="https://${hostName}:$port"

if([Environment]::MachineName -ne 'DESKTOP-H3R6CQN'){throw 'WRONG_HOST'}
if(-not(Test-Path $python)){throw 'PYTHON_MISSING'}
if(-not(Test-Path $proxy)){throw 'LAN_PROXY_SOURCE_MISSING'}
# AFZ_V06224_BOOT_ORCHESTRATOR
# The existing SYSTEM boot task for this script also restores the current
# AFZ core/public path before bringing up the LAN TLS edge.
$publicLauncher=Join-Path $root 'Start-AFZ-Stremio-H3-Public.ps1'
if(-not(Test-Path -LiteralPath $publicLauncher -PathType Leaf)){throw 'PUBLIC_LAUNCHER_MISSING'}
& powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $publicLauncher | Out-Null
if($LASTEXITCODE -ne 0){throw ('PUBLIC_LAUNCHER_EXIT_'+$LASTEXITCODE)}
try{
  $m243=Invoke-RestMethod -Uri 'http://127.0.0.1:18774/manifest.json' -TimeoutSec 8
}catch{throw 'CORE243_NOT_READY_FOR_LAN_TLS'}
if([string]$m243.version -ne '0.6.243'){throw ('CORE243_VERSION_MISMATCH_'+[string]$m243.version)}

$cfg=Get-NetIPConfiguration | Where-Object {
  $_.IPv4DefaultGateway -and $_.IPv4Address -and
  $_.IPv4Address.IPAddress -notmatch '^169\.254\.'
} | Sort-Object @{Expression={if($_.InterfaceAlias -eq 'Ethernet'){0}else{1}}} | Select-Object -First 1
if(-not $cfg){throw 'LAN_INTERFACE_NOT_FOUND'}
$lanIp=[string]($cfg.IPv4Address | Select-Object -First 1 -ExpandProperty IPAddress)
$ifAlias=[string]$cfg.InterfaceAlias

New-Item -ItemType Directory -Force -Path $certDir | Out-Null
$renew=$true
if((Test-Path $crt) -and (Test-Path $key)){
  try{
    $certObj=New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($crt)
    $renew=($certObj.NotAfter -lt (Get-Date).AddDays(14))
  }catch{$renew=$true}
}
if($renew){
  & 'C:\Program Files\Tailscale\tailscale.exe' cert --min-validity 336h --cert-file $crt --key-file $key $hostName | Out-Null
  if($LASTEXITCODE -ne 0){throw 'TAILSCALE_CERT_REFRESH_FAILED'}
}

$fwName='AFZ Stremio LAN TLS 8445'
$fw=Get-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue
if(-not $fw){
  New-NetFirewallRule -DisplayName $fwName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress LocalSubnet -InterfaceAlias $ifAlias -Profile Any | Out-Null
}

$fwExplicit='AFZ Stremio LAN TLS 8445 ExplicitSubnet'
$fw2=Get-NetFirewallRule -DisplayName $fwExplicit -ErrorAction SilentlyContinue
if(-not $fw2){
  New-NetFirewallRule -DisplayName $fwExplicit -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress '192.168.50.0/24' -InterfaceAlias $ifAlias -Profile Any | Out-Null
}

# AFZ_PY311_PUBLIC_TCP_BLOCK_REPAIR_V1
# Windows created an automatic Public-profile TCP block for the exact Python
# executable that owns the AFZ LAN proxies. A block rule overrides the narrow
# AFZ port allows, so disable only this validated TCP rule. Default inbound
# remains blocked and the UDP block is intentionally untouched.
$pyBlockName='{CEBD9EC7-8711-4195-9660-1BBF5930D39E}'
$pyBlockProgram='C:\users\faiz\appdata\local\programs\python\python311\python.exe'
try{
  $br=Get-NetFirewallRule -Name $pyBlockName -ErrorAction SilentlyContinue
  if($br){
    $ba=$br | Get-NetFirewallApplicationFilter
    $bp=$br | Get-NetFirewallPortFilter
    $valid=($br.Direction -eq 'Inbound' -and $br.Action -eq 'Block' -and
            [string]$br.Profile -match 'Public' -and [string]$bp.Protocol -eq 'TCP' -and
            [string]$ba.Program -ieq $pyBlockProgram)
    if(-not $valid){throw 'PY311_PUBLIC_TCP_BLOCK_IDENTITY_MISMATCH'}
    if($br.Enabled){Disable-NetFirewallRule -Name $pyBlockName | Out-Null}
  }
}catch{
  throw ('PY311_PUBLIC_TCP_BLOCK_REPAIR_FAILED_' + $_.Exception.Message)
}

function Test-LanTls {
  try{
    $json=& curl.exe -sS -m 8 --resolve "${hostName}:${port}:${lanIp}" "$publicBase/__lan_health"
    if($LASTEXITCODE -ne 0 -or -not $json){return $false}
    $h=$json | ConvertFrom-Json
    return [bool]($h.ok -and [string]$h.lanBase -eq $publicBase)
  }catch{return $false}
}

$listener=Get-NetTCPConnection -State Listen -LocalAddress $lanIp -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
if($listener){
  if(Test-LanTls){
    Write-Output "AFZ_STREMIO_LAN_TLS_ALREADY_HEALTHY $publicBase lan=$lanIp"
    exit 0
  }
  $svcPid=[int]$listener.OwningProcess
  $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$svcPid"
  if(-not $proc -or $proc.Name -notmatch '^python' -or
     ($proc.CommandLine -notmatch 'afz_lan_proxy:app' -and
      $proc.CommandLine -notmatch 'afz_lan_proxy_device_v2:app')){
    throw 'LAN_TLS_PORT_OCCUPIED_BY_UNVERIFIED_SERVICE'
  }
  Stop-Process -Id $svcPid -Force
  Start-Sleep -Milliseconds 500
}

$env:AFZ_LAN_UPSTREAM=$upstream
$env:AFZ_LAN_PUBLIC_BASE=$publicBase
$env:AFZ_SOURCE_PUBLIC_BASE=$publicBase
$env:AFZ_LAN_SEPARATE_ID='0'
$env:AFZ_LAN_MOVIE_ORDER_UPSTREAM='http://127.0.0.1:18792'
$args=@('-m','uvicorn',$module,'--host',$lanIp,'--port',[string]$port,'--log-level','warning','--ssl-keyfile',$key,'--ssl-certfile',$crt,'--no-proxy-headers')
if($enableDeviceV2){$args+=@('--app-dir',$deviceStage)}
$p=Start-Process -FilePath $python -ArgumentList $args -WorkingDirectory $root -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText($pidFile,[string]$p.Id,(New-Object Text.UTF8Encoding($false)))

$deadline=(Get-Date).AddSeconds(25)
do{
  Start-Sleep -Seconds 1
  if($p.HasExited){throw "LAN_TLS_EDGE_EXITED_$($p.ExitCode)"}
  if(Test-LanTls){break}
}while((Get-Date)-lt $deadline)
if(-not(Test-LanTls)){throw 'LAN_TLS_EDGE_NOT_READY'}
$browserLanLauncher=Join-Path $root 'Start-AFZ-Stremio-H3-LAN-Browser-TLS.ps1'
if(-not(Test-Path -LiteralPath $browserLanLauncher -PathType Leaf)){throw 'LAN_BROWSER_TLS_LAUNCHER_MISSING'}
& powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $browserLanLauncher | Out-Null
if($LASTEXITCODE -ne 0){throw ('LAN_BROWSER_TLS_LAUNCHER_EXIT_'+$LASTEXITCODE)}
Write-Output "AFZ_STREMIO_LAN_TLS_ACCEPTED host=$hostName lan=$lanIp port=$port pid=$($p.Id)"
