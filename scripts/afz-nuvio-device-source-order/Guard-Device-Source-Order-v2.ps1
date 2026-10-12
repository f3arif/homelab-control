$ErrorActionPreference='Stop'
$stage='C:\AFZ\Nuvio-Setup-20260923\device-source-order-20261012'
$backend='C:\AFZ\Stremio-Failover-H3\stremio_catalog.py'
$code=Join-Path $stage 'device_source_order_v2.py'
$serve='C:\Program Files\Tailscale\tailscale.exe'
$root='desktop-h3r6cqn.tailc9bb62.ts.net:8445'
$path='/stream/movie'
$media='http://127.0.0.1:18774'
$v1='http://127.0.0.1:18789'
$v2='http://127.0.0.1:18792'
$expectedBackend='d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f'
$expectedV2='1c144432e242c42027eb00dc8841aeb9c5f3930863ea434de326829e447ac3be'
$expectedV1='ed9af3890dec644974ce370eece1dd597b329aae3821844ec68771f55276471d'
$taskV1='AFZ Nuvio Device Sort Guard'
$taskV2='AFZ Nuvio Device Sort V2 Guard'
$status=Join-Path $stage 'v2-guard-status.json'
$lock=New-Object Threading.Mutex($false,'Global\AFZ_DEVICE_SORT_V2_GUARD')
$owned=$false
function Sha([string]$filename){return (Get-FileHash -LiteralPath $filename -Algorithm SHA256).Hash.ToLowerInvariant()}
function Report([string]$state,[string]$reason){
  $obj=[ordered]@{
    updatedUtc=(Get-Date).ToUniversalTime().ToString('o')
    status=$state
    reason=$reason.Substring(0,[math]::Min(180,$reason.Length))
    originalCatalogUntouched=$true
    changedServePathOnly='/stream/movie'
  }
  $temp=$status+'.'+$PID+'.tmp'
  [IO.File]::WriteAllText($temp,($obj|ConvertTo-Json -Depth 3),[Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $temp -Destination $status -Force
  Write-Output ('V2_GUARD='+$state)
}
function TailnetConfig {
  $raw=& $serve serve status --json 2>$null
  if($LASTEXITCODE -ne 0){throw 'Tailscale daemon unavailable'}
  return ($raw|ConvertFrom-Json)
}
function GoodV2 {
  try{
    $h=Invoke-RestMethod 'http://127.0.0.1:18792/health' -TimeoutSec 3
    if(-not $h.ok -or $h.policy -ne 'phone-best-v2'){return $false}
    $r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18792/tt11460992.json' -Headers @{'X-Forwarded-For'='100.99.124.8'} -TimeoutSec 9
    if($r.StatusCode -ne 200 -or $r.Headers['X-AFZ-Sort-Policy'] -ne 'phone-best-v2'){return $false}
    $j=$r.Content|ConvertFrom-Json
    $top=$j.streams[0]
    if($top.name -ne 'AFZ Play Best' -or
       $top.title -notmatch '1080p' -or
       $top.title -notmatch 'Phone optimized' -or
       $top.title -notmatch 'GB'){return $false}
    $tv=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18792/tt11460992.json' -Headers @{'X-Forwarded-For'='100.116.144.59'} -TimeoutSec 9
    $tvlist=$tv.Content|ConvertFrom-Json
    if($tvlist.streams[0].name -ne 'AFZ Play Best' -or
       $tvlist.streams[0].title -notmatch '2160p'){return $false}
    return $true
  }catch{return $false}
}
function GoodV1 {
  try{
    if((Sha (Join-Path $stage 'device_source_order.py')) -ne $expectedV1){return $false}
    $h=Invoke-RestMethod 'http://127.0.0.1:18789/health' -TimeoutSec 4
    return ($h.ok -and $h.policy -eq 'phone-first-v1')
  }catch{return $false}
}
function RestoreV1 {
  $s=TailnetConfig
  $entry=$s.Web.PSObject.Properties[$root]
  if(-not $entry -or $entry.Value.Handlers.'/'.Proxy -ne $media){
    Report 'MANUAL_REVIEW' 'Original Serve root changed; leave it untouched'
    return
  }
  $now=$entry.Value.Handlers.$path.Proxy
  if($now -ne $v2){
    Report 'OUTSIDE_GUARD' 'Current movie path is not owned by V2; no mutation'
    return
  }
  if(GoodV1){
    $out=& $serve serve --bg --https=8445 --set-path=/stream/movie $v1 2>&1
    if($LASTEXITCODE -ne 0){throw 'Failed to switch back to V1'}
    $a=TailnetConfig
    if($a.Web.PSObject.Properties[$root].Value.Handlers.$path.Proxy -ne $v1){throw 'V1 path rollback not verified'}
    Report 'FALLBACK_TO_V1' 'Restored previously working device-order service'
    try{Enable-ScheduledTask -TaskName $taskV1 -ErrorAction Stop|Out-Null}catch{}
  }else{
    # If even V1 is unavailable, restore the unmodified production stream
    # listing by removing only this path handler, not the entire Serve config.
    $out=& $serve serve --https=8445 --set-path=/stream/movie off 2>&1
    if($LASTEXITCODE -ne 0){throw 'Failed to remove unhealthy V2 mapping'}
    $a=TailnetConfig
    if($a.Web.PSObject.Properties[$root].Value.Handlers.PSObject.Properties[$path]){throw 'Path removal not verified'}
    Report 'FALLBACK_TO_ORIGINAL' 'Old H3 catalog listing restored (no device sorting)'
  }
  try{Disable-ScheduledTask -TaskName $taskV2 -ErrorAction Stop|Out-Null}catch{}
}
function RelaunchV2 {
  $listen=Get-NetTCPConnection -State Listen -LocalPort 18792 -ErrorAction SilentlyContinue|
    Where-Object {$_.LocalAddress -eq '127.0.0.1'}|Select-Object -First 1
  if($listen){
    $p=Get-CimInstance Win32_Process -Filter "ProcessId=$($listen.OwningProcess)" -ErrorAction SilentlyContinue
    if(-not $p -or $p.CommandLine -notmatch 'uvicorn device_source_order_v2:app' -or $p.CommandLine -notmatch '18792'){
      Report 'UNKNOWN_PORT_OWNER' 'Refusing to terminate a nonpreview process'
      return $false
    }
    Stop-Process -Id $listen.OwningProcess -Force -ErrorAction Stop
    Start-Sleep -Milliseconds 450
  }
  $python='C:\AFZ\Stremio-Failover-H3\.venv\Scripts\python.exe'
  if(-not(Test-Path -LiteralPath $python)){return $false}
  $args=@('-m','uvicorn','device_source_order_v2:app','--app-dir',$stage,
          '--host','127.0.0.1','--port','18792','--lifespan','off','--no-access-log','--log-level','warning')
  $out=Join-Path $stage 'v2-guard-restarted-stdout.log'
  $err=Join-Path $stage 'v2-guard-restarted-stderr.log'
  $p=Start-Process -FilePath $python -ArgumentList $args -WorkingDirectory $stage -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  for($i=0;$i -lt 20;$i++){
    Start-Sleep -Milliseconds 400
    if($p.HasExited){return $false}
    if(GoodV2){return $true}
  }
  return $false
}
try{
  try{$owned=$lock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
  if(-not $owned){exit 0}
  $r=TailnetConfig
  $current=$r.Web.PSObject.Properties[$root]
  if(-not $current -or $current.Value.Handlers.'/'.Proxy -ne $media){
    Report 'MANUAL_REVIEW' 'Do not touch unexpected production root'
    exit 0
  }
  if($current.Value.Handlers.$path.Proxy -ne $v2){
    Report 'NOT_ACTIVE' 'V2 movie-list path not enabled'
    exit 0
  }
  if(-not(Test-Path $backend) -or -not(Test-Path $code) -or
      (Sha $backend) -ne $expectedBackend -or (Sha $code) -ne $expectedV2){
    RestoreV1
    exit 0
  }
  if(GoodV2){
    Report 'HEALTHY' 'Phone Play Best 1080p; TV Play Best 2160p; local endpoint healthy'
    exit 0
  }
  if(RelaunchV2){
    Report 'RECOVERED' 'Verified restart of only local V2 movie-list server'
    exit 0
  }
  Report 'V2_UNHEALTHY' 'New sorter recovery failed; restoring previous source list'
  RestoreV1
}catch{
  try{Report 'GUARD_EXCEPTION' ($_.Exception.GetType().Name+': '+$_.Exception.Message)}catch{}
  try{RestoreV1}catch{}
}finally{
  if($owned){try{$lock.ReleaseMutex()}catch{}}
  $lock.Dispose()
}
