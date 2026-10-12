param([switch]$Apply)
$ErrorActionPreference='Stop'
$root='desktop-h3r6cqn.tailc9bb62.ts.net:8445'
$prefix='/stream/movie'
$current=tailscale.exe serve status --json|ConvertFrom-Json
$mapping=$current.Web.PSObject.Properties[$root]
if(-not $mapping){throw 'Original H3 HTTPS Serve port is missing'}
if($mapping.Value.Handlers.'/'.Proxy -ne 'http://127.0.0.1:18774'){
  throw 'Original H3 catalog root changed; do not attempt automatic rollback'
}
$proxy=$mapping.Value.Handlers.$prefix
if(-not $proxy){Write-Output 'ROUTE_ALREADY_ABSENT_NO_CHANGE';return}
if($proxy.Proxy -ne 'http://127.0.0.1:18789'){
  throw 'Device source route no longer belongs to expected sidecar; no mutation'
}
Write-Output 'DEVICE_SORT_ROLLBACK_PREFLIGHT=PASS'
if(-not $Apply){Write-Output 'ROUTE_STILL_ACTIVE_DRYRUN';return}
$out=tailscale.exe serve --https=8445 --set-path=/stream/movie off 2>&1
if($LASTEXITCODE -ne 0){throw ('Could not remove only sorting route: '+($out|Out-String))}
$after=tailscale.exe serve status --json|ConvertFrom-Json
$entry=$after.Web.PSObject.Properties[$root]
if(-not $entry -or $entry.Value.Handlers.'/'.Proxy -ne 'http://127.0.0.1:18774'){
  throw 'Original H3 Serve root missing after rollback'
}
if($entry.Value.Handlers.$prefix){throw 'Sorting path still present after rollback'}
$manifest=Invoke-RestMethod 'https://desktop-h3r6cqn.tailc9bb62.ts.net:8445/manifest.json' -TimeoutSec 8
if($manifest.id -ne 'com.afzengineering.releasecatalog'){throw 'Original manifest verification failed'}
Write-Output 'DEVICE_SORT_ROUTE_REMOVED=PASS'
Write-Output 'ORIGINAL_H3_CATALOG_HTTPS_STILL_LIVE=PASS'
