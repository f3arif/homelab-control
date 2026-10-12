$ErrorActionPreference='Stop'
$stage='C:\AFZ\Nuvio-Setup-20260923\device-source-order-20261012'
$backend='C:\AFZ\Stremio-Failover-H3\stremio_catalog.py'
$sorter=Join-Path $stage 'device_source_order.py'
$state=Join-Path $stage 'device-order-guard-status.json'
$serve='C:\Program Files\Tailscale\tailscale.exe'
$root='desktop-h3r6cqn.tailc9bb62.ts.net:8445'
$prefix='/stream/movie'
$sorterTarget='http://127.0.0.1:18789'
$backendTarget='http://127.0.0.1:18774'
$sorterHash='ed9af3890dec644974ce370eece1dd597b329aae3821844ec68771f55276471d'
$backendHash='d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f'
$lock=New-Object System.Threading.Mutex($false,'Global\AFZ_DEVICE_SOURCE_SORT_GUARD_R1')
$owns=$false
function Sha([string]$f){ return (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() }
function Record([string]$status,[string]$why='') {
  $payload=[ordered]@{
    updatedUtc=(Get-Date).ToUniversalTime().ToString('o')
    state=$status
    detail=$why.Substring(0,[math]::Min(180,$why.Length))
    originalMediaEndpointUnaffected=$true
    sourceOrderVersion='phone-first-v1'
  }
  $file=$state+'.'+[string]$PID+'.tmp'
  [IO.File]::WriteAllText($file,($payload|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $file -Destination $state -Force
  Write-Output ('DEVICE_ORDER_GUARD='+$status)
}
function Healthy {
  try {
    $r=Invoke-RestMethod 'http://127.0.0.1:18789/health' -TimeoutSec 3
    if(-not($r.ok -and $r.policy -eq 'phone-first-v1')){return $false}
    $devicePolicy=Get-Content -Raw (Join-Path $stage 'device-policy.json')|ConvertFrom-Json
    $phoneIp=[string](@($devicePolicy.phone)|Select-Object -First 1)
    if(-not $phoneIp){return $false}
    $web=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18789/tt11460992.json' -TimeoutSec 8 -Headers @{'X-Forwarded-For'=$phoneIp}
    if($web.StatusCode -ne 200){return $false}
    $j=$web.Content|ConvertFrom-Json
    return $j.streams.Count -ge 1 -and $j.streams[0].name -eq 'AFZ Recommended for Phone'
  }catch{return $false}
}
function FailBack {
  $all=& $serve serve status --json 2>$null
  if($LASTEXITCODE -ne 0){Record 'TAILNET_UNAVAILABLE_RETRY' 'Local Tailscale daemon did not return a configuration';return}
  $config=$all|ConvertFrom-Json
  $h=$config.Web.PSObject.Properties[$root]
  if(-not $h -or $h.Value.Handlers.'/'.Proxy -ne $backendTarget){
    Record 'UNEXPECTED_SERVE_CONFIG_MANUAL_REVIEW' 'Original catalog route must remain intact'
    return
  }
  if($h.Value.Handlers.$prefix.Proxy -ne $sorterTarget){
    Record 'SORT_ROUTE_NOT_ACTIVE' 'No owned device-aware route to remove'
    return
  }
  $output=& $serve serve --https=8445 --set-path=/stream/movie off 2>&1
  if($LASTEXITCODE -ne 0){
    Record 'ROLLBACK_REQUEST_FAILED' 'Could not remove device-sort path; retry next scheduled run'
    return
  }
  $after=(& $serve serve status --json|ConvertFrom-Json).Web.PSObject.Properties[$root]
  if($after -and $after.Value.Handlers.'/'.Proxy -eq $backendTarget -and
     -not $after.Value.Handlers.$prefix){
    Record 'FALLBACK_TO_ORIGINAL_SORTING' 'Removed only the sorter route after unhealthy sorter'
  }else{
    Record 'ROLLBACK_UNVERIFIED' 'Check Tailscale Serve state manually'
  }
}
try {
  try{$owns=$lock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owns=$true}
  if(-not $owns){Write-Output 'ALREADY_RUNNING';exit 0}
  if(-not(Test-Path $sorter) -or -not(Test-Path $backend) -or
      (Sha $sorter) -ne $sorterHash -or (Sha $backend) -ne $backendHash){
    FailBack
    exit 0
  }
  $all=& $serve serve status --json 2>$null
  if($LASTEXITCODE -ne 0){Record 'TAILNET_UNAVAILABLE_RETRY' 'Daemon not ready';exit 0}
  $current=$all|ConvertFrom-Json
  $h=$current.Web.PSObject.Properties[$root]
  if(-not $h -or $h.Value.Handlers.'/'.Proxy -ne $backendTarget){
    Record 'UNEXPECTED_SERVE_CONFIG_MANUAL_REVIEW' 'Original catalog route changed'
    exit 0
  }
  if($h.Value.Handlers.$prefix.Proxy -ne $sorterTarget){
    Record 'SORT_ROUTE_NOT_ACTIVE' 'Manual rollback or route absent; no automatic reenable'
    exit 0
  }
  if(Healthy){Record 'HEALTHY' 'Original catalog and phone recommendation working';exit 0}

  # Recover only the known sorter, never any AFZ production uvicorn process.
  $listener=Get-NetTCPConnection -State Listen -LocalPort 18789 -ErrorAction SilentlyContinue|
     Where-Object {$_.LocalAddress -eq '127.0.0.1'}|Select-Object -First 1
  if($listener){
     $process=Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction SilentlyContinue
     if($process -and $process.CommandLine -match 'uvicorn device_source_order:app' -and $process.CommandLine -match '18789'){
       Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
       Start-Sleep -Milliseconds 500
     }else{
       Record 'UNKNOWN_SORTER_PORT_OWNER' 'Refusing to stop unknown process'
       FailBack
       exit 0
     }
  }
  $receipt=Join-Path $stage 'device-order-process.json'
  if(Test-Path $receipt){
     $archive=Join-Path $stage ('device-order-process.guard-archive-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json')
     Move-Item -LiteralPath $receipt -Destination $archive
  }
  $start=Join-Path $stage 'Start-Device-Order-Sidecar.ps1'
  $output=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $start -Apply 2>&1|Out-String
  if($LASTEXITCODE -eq 0 -and (Healthy)){
    Record 'RESTARTED_SORTER' 'Recovered private sidecar while preserving media routes'
    exit 0
  }
  Record 'SORTER_RECOVERY_FAILED' 'Attempted private process restart; reverting only source-order overlay'
  FailBack
}catch{
  try{Record 'GUARD_EXCEPTION' ($_.Exception.GetType().Name+': '+$_.Exception.Message)}catch{}
  try{FailBack}catch{}
}finally{
  if($owns){try{$lock.ReleaseMutex()}catch{}}
  $lock.Dispose()
}
