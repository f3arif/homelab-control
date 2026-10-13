param([string]$CoreRoot='C:\AFZ\Stremio-Failover-H3',[Parameter(Mandatory=$true)][string]$RecoveryDir)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$launcher=Join-Path $CoreRoot 'Start-AFZ-Stremio-H3-Core243.ps1'
$candidate=Join-Path $RecoveryDir 'Start-AFZ-Stremio-H3-Core243.SONARR-PROPOSED.ps1'
$backup=Join-Path $RecoveryDir 'Start-AFZ-Stremio-H3-Core243.before-sonarr.ps1'
$source=Join-Path $CoreRoot 'stremio_catalog.py'
$expectedSource='d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f'
if((Get-FileHash $launcher).Hash.ToLowerInvariant() -ne 'c95c13e3c94d0493f3ac0dc9bd670c372a36f122a04349ed529d6a7b050fba6d'){throw 'LAUNCHER_CHANGED_SINCE_APPROVAL'}
if((Get-FileHash $candidate).Hash.ToLowerInvariant() -ne 'bffec35f5e14a7550b5417e17978b7697b7d4b18d9e1ba0537a1b543dd43d695'){throw 'PROPOSAL_CHANGED_SINCE_APPROVAL'}
if((Get-FileHash $source).Hash.ToLowerInvariant() -ne $expectedSource){throw 'CORE_SOURCE_CHANGED'}
if(Test-Path -LiteralPath $backup){throw 'SONARR_BACKUP_ALREADY_EXISTS_INSPECT_FIRST'}
$pre=Get-Content (Join-Path $RecoveryDir 'h3-sonarr-tunnel-verified.json') -Raw | ConvertFrom-Json
if($pre.systemStatus -ne 200 -or $pre.seriesStatus -ne 200 -or $pre.queueStatus -ne 200){throw 'TUNNEL_NOT_VERIFIED'}
$listeners=@(Get-NetTCPConnection -State Listen -LocalPort 18801 -ErrorAction Stop)
if(-not $listeners.Count -or @($listeners | Where-Object {$_.LocalAddress -ne '127.0.0.1'}).Count){throw 'TUNNEL_IS_NOT_LOOPBACK_ONLY'}
$tokens=$null; $parseErrors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($candidate,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'CANDIDATE_SYNTAX_INVALID'}
function Restart-Core {
  $coreListeners=@(Get-NetTCPConnection -State Listen -LocalPort 18774 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
  foreach($servicePid in $coreListeners){
    $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$servicePid"
    if(-not $proc -or $proc.Name -notmatch '^python' -or $proc.CommandLine -notmatch 'uvicorn stremio_catalog:app'){throw 'UNEXPECTED_CORE_PROCESS'}
    Stop-Process -Id $servicePid -Force
  }
  Start-ScheduledTask -TaskName 'AFZ Stremio H3 Failover'
}
Copy-Item -LiteralPath $launcher -Destination $backup
Copy-Item -LiteralPath $candidate -Destination $launcher -Force
try {
  Restart-Core
  Write-Output 'CORE_RESTARTED_WITH_APPROVED_SONARR_URL'
  $deadline=(Get-Date).AddSeconds(180)
  $passed=$false
  do {
    Start-Sleep -Seconds 3
    try {
      $manifest=Invoke-RestMethod 'http://127.0.0.1:18774/manifest.json' -TimeoutSec 8
      $routing=Invoke-RestMethod 'http://127.0.0.1:18774/download-routing.json' -TimeoutSec 30
      $health=Invoke-RestMethod 'http://127.0.0.1:18774/system-health.json' -TimeoutSec 45
      $tv=@($health.services | Where-Object {$_.name -eq 'Sonarr'})
      if($manifest.version -eq '0.6.243' -and $routing.qBittorrent.ready -and $routing.spilloverActive -and $tv.Count -eq 1 -and $tv[0].ok -and $tv[0].version -eq '4.0.20.3014' -and $null -ne $health.queues.tv){$passed=$true;break}
    } catch {}
  } while((Get-Date) -lt $deadline)
  if(-not $passed){throw 'H3_SONARR_OR_EXISTING_ROUTING_NOT_READY'}
  $receipt=[ordered]@{
    status='CONNECTED'
    checkedUtc=(Get-Date).ToUniversalTime().ToString('o')
    version=$manifest.version
    sourceUnchanged=((Get-FileHash $source).Hash.ToLowerInvariant() -eq $expectedSource)
    launcherSha256=(Get-FileHash $launcher).Hash.ToLowerInvariant()
    sonarrUrl='http://127.0.0.1:18801/api/v3'
    sonarr=$tv[0]
    tvQueueCount=$health.queues.tv
    services=$health.services
    overallHealthy=$health.overallHealthy
    qBittorrentReady=$routing.qBittorrent.ready
    selectedPath=$routing.selectedPermanentDownloadPath
    spilloverActive=$routing.spilloverActive
    backup=$backup
  }
  $receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $RecoveryDir 'h3-sonarr-activation.json') -Encoding UTF8
  $receipt | ConvertTo-Json -Depth 6
} catch {
  Copy-Item -LiteralPath $backup -Destination $launcher -Force
  Restart-Core
  [ordered]@{status='ROLLED_BACK';checkedUtc=(Get-Date).ToUniversalTime().ToString('o');reason=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RecoveryDir 'h3-sonarr-activation.json') -Encoding UTF8
  throw
}
