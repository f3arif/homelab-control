param([string]$CoreRoot='C:\AFZ\Stremio-Failover-H3',[Parameter(Mandatory=$true)][string]$RecoveryDir)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=$CoreRoot
$rec=$RecoveryDir
$launcher=Join-Path $root 'Start-AFZ-Stremio-H3-Core243.ps1'
$candidate=Join-Path $rec 'Start-AFZ-Stremio-H3-Core243.restored-requests.ps1'
$backup=Join-Path $rec 'Start-AFZ-Stremio-H3-Core243.before-requests.ps1'
$pre=Get-Content (Join-Path $rec 'h3-launcher-preflight.json') -Raw | ConvertFrom-Json
if((Get-FileHash $launcher).Hash.ToLowerInvariant() -ne $pre.before_sha256){throw 'LAUNCHER_CHANGED_SINCE_PREFLIGHT'}
if((Get-FileHash (Join-Path $root 'stremio_catalog.py')).Hash.ToLowerInvariant() -ne $pre.source_sha256){throw 'SOURCE_CHANGED_SINCE_PREFLIGHT'}
$tokens=$null; $parseErrors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($candidate,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'CANDIDATE_SYNTAX_INVALID'}
function Restart-Core {
  $listeners=@(Get-NetTCPConnection -State Listen -LocalPort 18774 -ErrorAction SilentlyContinue)
  foreach($listener in $listeners){
    $servicePid=[int]$listener.OwningProcess
    $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$servicePid"
    if(-not $proc -or $proc.Name -notmatch '^python' -or $proc.CommandLine -notmatch 'uvicorn stremio_catalog:app'){throw 'UNEXPECTED_CORE_PROCESS'}
    Stop-Process -Id $servicePid -Force
  }
  Start-ScheduledTask -TaskName 'AFZ Stremio H3 Failover'
}
Copy-Item -LiteralPath $candidate -Destination $launcher -Force
try {
  Restart-Core
  $deadline=(Get-Date).AddSeconds(150)
  $passed=$false
  do {
    Start-Sleep -Seconds 3
    try {
      $m=Invoke-RestMethod 'http://127.0.0.1:18774/manifest.json' -TimeoutSec 8
      $routing=Invoke-RestMethod 'http://127.0.0.1:18774/download-routing.json' -TimeoutSec 25
      if($m.version -eq '0.6.243' -and $routing.qBittorrent.ready -and $routing.spilloverActive){$passed=$true;break}
    } catch {}
  } while((Get-Date) -lt $deadline)
  if(-not $passed){throw 'RESTORED_REQUESTS_ROUTING_NOT_READY'}
  $receipt=[ordered]@{status='CONNECTED';checkedUtc=(Get-Date).ToUniversalTime().ToString('o');version=$m.version;sourceUnchanged=((Get-FileHash (Join-Path $root 'stremio_catalog.py')).Hash.ToLowerInvariant() -eq $pre.source_sha256);qBittorrentReady=$routing.qBittorrent.ready;selectedPath=$routing.selectedPermanentDownloadPath;spilloverActive=$routing.spilloverActive;launcherSha256=(Get-FileHash $launcher).Hash.ToLowerInvariant();backup=$backup}
  $receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $rec 'h3-requests-activation.json') -Encoding UTF8
  $receipt | ConvertTo-Json -Compress
} catch {
  Copy-Item -LiteralPath $backup -Destination $launcher -Force
  Restart-Core
  throw
}
