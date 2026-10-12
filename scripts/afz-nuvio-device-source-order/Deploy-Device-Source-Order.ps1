param([switch]$Apply)
$ErrorActionPreference='Stop'
$stage='C:\AFZ\Nuvio-Setup-20260923\device-source-order-20261012'
$rootUrl='desktop-h3r6cqn.tailc9bb62.ts.net:8445'
$target='http://127.0.0.1:18789'
$mediaRoot='http://127.0.0.1:18774'
$path='/stream/movie'
$originalSHA='d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f'
$sorterSHA='ed9af3890dec644974ce370eece1dd597b329aae3821844ec68771f55276471d'
if(((Get-FileHash 'C:\AFZ\Stremio-Failover-H3\stremio_catalog.py' -Algorithm SHA256).Hash.ToLowerInvariant()) -ne $originalSHA){
  throw 'Baseline production catalog SHA drift; reconcile before routing'
}
if(((Get-FileHash (Join-Path $stage 'device_source_order.py') -Algorithm SHA256).Hash.ToLowerInvariant()) -ne $sorterSHA){
  throw 'Device sort application SHA drift; reconcile before routing'
}
$r=Invoke-RestMethod 'http://127.0.0.1:18789/health' -TimeoutSec 4
if(-not $r.ok -or $r.policy -ne 'phone-first-v1'){throw 'Device sorter not healthy'}
$old=tailscale.exe serve status --json | ConvertFrom-Json
$web=$old.Web.PSObject.Properties[$rootUrl]
if(-not $web){throw 'H3 production HTTPS Serve route not found'}
$handlers=$web.Value.Handlers
if($handlers.'/'.Proxy -ne $mediaRoot){throw 'Original Serve / route changed'}
if($handlers.PSObject.Properties[$path]){throw 'Device-sort path already exists; do not overwrite'}
# Test prefix stripping is handled, and URL/transformed data are valid.
$devicePolicy=Get-Content -Raw (Join-Path $stage 'device-policy.json')|ConvertFrom-Json
$phoneIp=[string](@($devicePolicy.phone)|Select-Object -First 1)
$tvIp=[string](@($devicePolicy.tv)|Select-Object -First 1)
if(-not $phoneIp -or -not $tvIp){throw 'Private device-class policy is incomplete'}
$phone=Invoke-WebRequest -UseBasicParsing -TimeoutSec 9 -Uri 'http://127.0.0.1:18789/tt11460992.json' -Headers @{'X-Forwarded-For'=$phoneIp}
$tv=Invoke-WebRequest -UseBasicParsing -TimeoutSec 9 -Uri 'http://127.0.0.1:18789/tt11460992.json' -Headers @{'X-Forwarded-For'=$tvIp}
if($phone.StatusCode -ne 200 -or $tv.StatusCode -ne 200){throw 'Test source response unavailable'}
if(($phone.Content|ConvertFrom-Json).streams[0].name -ne 'AFZ Recommended for Phone'){throw 'Mobile first source incorrect'}
if(($tv.Content|ConvertFrom-Json).streams[0].name -ne 'AFZ Play Best'){throw 'TV first source incorrectly changed'}
Write-Output 'DEVICE_SORT_DEPLOY_PREFLIGHT=PASS'
if(-not $Apply){Write-Output 'NO_SERVE_MUTATION_DRY_RUN';return}
$updated=$false
try {
  $output=tailscale.exe serve --bg --https=8445 --set-path=/stream/movie $target 2>&1
  if($LASTEXITCODE -ne 0){throw ('Tailscale Serve route addition failed: '+($output|Out-String))}
  $updated=$true
  $now=tailscale.exe serve status --json|ConvertFrom-Json
  $entry=$now.Web.PSObject.Properties[$rootUrl]
  if(-not $entry -or $entry.Value.Handlers.'/'.Proxy -ne $mediaRoot -or
     $entry.Value.Handlers.$path.Proxy -ne $target){
    throw 'Tailscale routing did not preserve original root and add sorter path'
  }
  foreach($b in $old.Web.PSObject.Properties){
    if($b.Name -eq $rootUrl){continue}
    $later=$now.Web.PSObject.Properties[$b.Name]
    if(-not $later -or ($later.Value|ConvertTo-Json -Compress -Depth 7) -ne ($b.Value|ConvertTo-Json -Compress -Depth 7)){
      throw ('Unexpected mutation to unrelated Tailscale Serve mapping '+$b.Name)
    }
  }
  $url='https://desktop-h3r6cqn.tailc9bb62.ts.net:8445'
  $manifest=Invoke-RestMethod "$url/manifest.json" -TimeoutSec 8
  if($manifest.id -ne 'com.afzengineering.releasecatalog'){throw 'Original manifest changed'}
  $response=Invoke-WebRequest -UseBasicParsing -Uri "$url/stream/movie/tt11460992.json" -TimeoutSec 10
  if($response.StatusCode -ne 200 -or $response.Headers['X-AFZ-Sort-Policy'] -ne 'phone-first-v1'){
    throw 'New private stream-list overlay not returning valid response'
  }
  $row=($response.Content|ConvertFrom-Json).streams[0]
  if(-not $row){throw 'Empty stream list after routing'}
  $check=[ordered]@{
    activatedUtc=(Get-Date).ToUniversalTime().ToString('o')
    serveRoot=$rootUrl
    prefix=$path
    proxyTarget=$target
    baselineManifest='com.afzengineering.releasecatalog'
    sorterCodeSHA=$sorterSHA
    coreCatalogCodeUnchanged=$true
    liveMediaURLsUnchanged=$true
    allExistingTailscaleRoutesPreserved=$true
    status='LIVE_PHONE_SORTING_OVERLAY'
  }
  $file=Join-Path $stage 'device-order-deployment.json'
  [IO.File]::WriteAllText($file,($check|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
  Write-Output 'DEVICE_SORT_ROUTE_APPLIED=PASS'
  Write-Output ('DEVICE_SORT_NEW_ROUTE='+$path)
}catch{
  $err=$_.Exception.Message
  if($updated){
    # Remove ONLY the new path, never reset the whole Serve config.
    $rollback=tailscale.exe serve --https=8445 --set-path=/stream/movie off 2>&1
    Write-Output ('DEVICE_SORT_PATH_ROLLBACK_EXIT='+$LASTEXITCODE)
  }
  throw $err
}
