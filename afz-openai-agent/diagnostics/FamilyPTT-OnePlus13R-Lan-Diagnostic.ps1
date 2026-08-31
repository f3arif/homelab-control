#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$serial = '95038870'
$package = 'ca.afzeng.familyptt'
$bridgeRoot = 'C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$resultPath = Join-Path $bridgeRoot 'FAMILYPTT-ONEPLUS13R-LAN-DIAG-LATEST.txt'
$adbCandidates = @(
  'C:\Users\Faiz\AppData\Local\Android\Sdk\platform-tools\adb.exe',
  'C:\Android\platform-tools\adb.exe'
)
$adb = $adbCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

$lines = New-Object System.Collections.Generic.List[string]
function Add-Line([string]$s='') { [void]$lines.Add($s) }
function Run-Adb([string[]]$args) {
  if (-not $adb) { return @('ADB_NOT_FOUND') }
  $old = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $raw = @(& $adb @args 2>&1)
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $old }
  return @("[exit=$code]") + @($raw | ForEach-Object { [string]$_ })
}
function Add-Section([string]$name, [string[]]$content) {
  Add-Line ""
  Add-Line "===== $name ====="
  foreach ($x in $content) { Add-Line ([string]$x) }
}

try {
  Add-Line 'AFZ_FAMILYPTT_ONEPLUS_LAN_DIAG_V1'
  Add-Line ('time=' + (Get-Date -Format o))
  Add-Line ('computer=' + $env:COMPUTERNAME)
  Add-Line ('serial=' + $serial)
  Add-Line ('package=' + $package)
  Add-Line ('readOnly=true')
  Add-Line ('networkMutation=false')
  Add-Line ('appRestart=false')

  if (-not $adb) { throw 'adb.exe not found' }

  $devices = Run-Adb @('devices','-l')
  Add-Section 'ADB DEVICES' $devices
  if (($devices -join "`n") -notmatch "(?m)^$([regex]::Escape($serial))\s+device\b") {
    throw "OnePlus serial $serial is not ADB-authorized as device"
  }

  Add-Section 'DEVICE MODEL' (Run-Adb @('-s',$serial,'shell','getprop','ro.product.model'))
  Add-Section 'DEVICE BRAND' (Run-Adb @('-s',$serial,'shell','getprop','ro.product.brand'))

  $pidOut = Run-Adb @('-s',$serial,'shell','pidof',$package)
  Add-Section 'FAMILYPTT PID' $pidOut
  $pid = (($pidOut | Where-Object { $_ -notmatch '^\[exit=' }) -join '').Trim()

  Add-Section 'ANDROID WIFI STATUS' (Run-Adb @('-s',$serial,'shell','cmd','wifi','status'))

  $wifiRaw = Run-Adb @('-s',$serial,'shell','dumpsys','wifi')
  $wifiFiltered = @($wifiRaw | Where-Object {
    $_ -match '(?i)Wi-?Fi|SSID|BSSID|NetworkInfo|Supplicant|connected|internet|validated|score|link speed|frequency|ip address|gateway|dns'
  } | Select-Object -Last 180)
  Add-Section 'ANDROID WIFI DUMPSYS FILTERED' $wifiFiltered

  $connRaw = Run-Adb @('-s',$serial,'shell','dumpsys','connectivity')
  $connFiltered = @($connRaw | Where-Object {
    $_ -match '(?i)NetworkAgentInfo|NetworkCapabilities|LinkProperties|VALIDATED|INTERNET|WIFI|CELLULAR|CAPTIVE_PORTAL|NOT_VPN|NOT_RESTRICTED|DEFAULT|active|DnsAddresses|Routes'
  } | Select-Object -Last 260)
  Add-Section 'ANDROID CONNECTIVITY FILTERED' $connFiltered

  if (-not [string]::IsNullOrWhiteSpace($pid)) {
    $logRaw = Run-Adb @('-s',$serial,'logcat','-d',"--pid=$pid",'-v','time')
    $logFiltered = @($logRaw | Where-Object {
      $_ -match '(?i)TransportPath|Recovery|LiveKit|Network|Connectivity|expo-network|internetReachable|LAN_BACKUP|WIFI_INTERNET|CELLULAR_INTERNET|OFFLINE'
    } | Select-Object -Last 160)
    Add-Section 'FAMILYPTT TRANSPORT LOG' $logFiltered
  } else {
    Add-Section 'FAMILYPTT TRANSPORT LOG' @('PID_NOT_AVAILABLE')
  }

  # Read-only independent reachability probes from the handset. These do not change
  # routing or app state; they only report whether the current Android path can
  # resolve/reach public endpoints while the LAN test condition is active.
  Add-Section 'PHONE DNS/PING PTT API' (Run-Adb @('-s',$serial,'shell','ping','-c','1','-W','2','ptt-api.afzeng.ca'))
  Add-Section 'PHONE PING PUBLIC IP' (Run-Adb @('-s',$serial,'shell','ping','-c','1','-W','2','1.1.1.1'))

  $curlCheck = Run-Adb @('-s',$serial,'shell','sh','-c','if command -v curl >/dev/null 2>&1; then curl -sS -I --connect-timeout 4 --max-time 6 https://connectivitycheck.gstatic.com/generate_204 | head -n 8; else echo CURL_NOT_AVAILABLE; fi')
  Add-Section 'PHONE HTTPS VALIDATION PROBE' $curlCheck

  $pidAfter = Run-Adb @('-s',$serial,'shell','pidof',$package)
  Add-Section 'FAMILYPTT PID AFTER' $pidAfter
  Add-Line ''
  Add-Line 'FINAL=CAPTURED_READ_ONLY'
} catch {
  Add-Line ''
  Add-Line ('ERROR=' + $_.Exception.Message)
  Add-Line 'FINAL=DIAGNOSTIC_FAILED'
}

try {
  $lines | Set-Content -LiteralPath $resultPath -Encoding UTF8
} catch {
  # Last-resort local copy if the OneDrive mirror is unavailable.
  $fallback = 'C:\ProgramData\AFZ\FAMILYPTT-ONEPLUS13R-LAN-DIAG-LATEST.txt'
  $lines | Set-Content -LiteralPath $fallback -Encoding UTF8
}
