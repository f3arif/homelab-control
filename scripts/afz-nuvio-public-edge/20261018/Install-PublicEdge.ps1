# Restore the existing Nuvio transport without changing Funnel, the core, or provider configuration.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$taskName='AFZ Nuvio Public Edge'
$runner=Join-Path $root 'Run-PublicEdge.ps1'
$coreRoot='C:\AFZ\Stremio-Failover-H3'
$source=Join-Path $coreRoot 'afz_public_proxy.py'
$ts='C:\Program Files\Tailscale\tailscale.exe'
if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){throw 'TASK_EXISTS_REVIEW_CURRENT_INSTALLATION'}
if(Get-NetTCPConnection -State Listen -LocalPort 18773 -ErrorAction SilentlyContinue){throw 'PUBLIC_EDGE_PORT_ALREADY_IN_USE'}
if(-not(Test-Path -LiteralPath $runner -PathType Leaf)){throw 'RUNNER_MISSING'}
$token=(Get-Content -LiteralPath (Join-Path $coreRoot 'state\public-transport-token.txt') -Raw).Trim()
if($token -notmatch '^[A-Za-z0-9_-]{24,256}$'){throw 'PUBLIC_EDGE_TOKEN_INVALID'}
$core=Invoke-RestMethod 'http://127.0.0.1:18774/manifest.json' -TimeoutSec 8
if([string]$core.id -ne 'com.afzengineering.releasecatalog'){throw 'UNEXPECTED_CORE'}
$beforeText=(& $ts serve status --json | Out-String)
if($LASTEXITCODE -ne 0){throw 'SERVE_STATUS_FAILED'}
$before=$beforeText | ConvertFrom-Json
$key='desktop-h3r6cqn.tailc9bb62.ts.net:10000'
if([string]$before.Web.$key.Handlers.'/'.Proxy -ne 'http://127.0.0.1:18773'){throw 'EXISTING_FUNNEL_TARGET_CHANGED'}
if(-not $before.AllowFunnel.$key){throw 'ORIGINAL_PUBLIC_ROUTE_NOT_ENABLED'}
$sourceHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $root 'serve-before-private.json'),$beforeText,(New-Object Text.UTF8Encoding($false)))
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$runner+'"')
$user=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
$triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -AtLogOn -User $user))
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description 'Maintains the existing protected AFZ Nuvio public edge on loopback 18773; no Funnel or catalog changes.' | Out-Null
try {
 Start-ScheduledTask -TaskName $taskName
 $ready=$false
 for($i=0;$i -lt 30;$i++){
  try {
   $m=Invoke-RestMethod -Uri ('http://127.0.0.1:18773/'+$token+'/manifest.json') -TimeoutSec 3
   if([string]$m.id -eq [string]$core.id -and [string]$m.version -eq [string]$core.version){$ready=$true;break}
  }catch{}
  Start-Sleep -Milliseconds 400
 }
 if(-not $ready){throw 'PUBLIC_EDGE_NOT_READY'}
 $after=(& $ts serve status --json | Out-String | ConvertFrom-Json)
 if($LASTEXITCODE -ne 0){throw 'SERVE_RECHECK_FAILED'}
 if(($before | ConvertTo-Json -Depth 40 -Compress) -ne ($after | ConvertTo-Json -Depth 40 -Compress)){throw 'SERVE_CONFIGURATION_CHANGED_DURING_INSTALL'}
 if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash){throw 'PROXY_SOURCE_CHANGED_DURING_INSTALL'}
 $report=@{ok=$true;utc=[DateTime]::UtcNow.ToString('o');task=$taskName;state=[string](Get-ScheduledTask -TaskName $taskName).State;sourceSha256=$sourceHash;manifestId=[string]$m.id;manifestVersion=[string]$m.version;existingMappingsPreserved=$true;coreRestarted=$false;previousDisabledTaskPreserved=$true}
 [IO.File]::WriteAllText((Join-Path $root 'rollout-summary.json'),($report | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
 $report | ConvertTo-Json -Compress
}catch{
 $failure=$_
 & (Join-Path $root 'Rollback-PublicEdge.ps1') | Out-Null
 throw $failure
}
