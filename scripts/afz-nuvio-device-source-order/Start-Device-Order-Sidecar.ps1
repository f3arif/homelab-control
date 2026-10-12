param([switch]$Apply)
$ErrorActionPreference='Stop'
$stage='C:\AFZ\Nuvio-Setup-20260923\device-source-order-20261012'
$backend='C:\AFZ\Stremio-Failover-H3\stremio_catalog.py'
$source=Join-Path $stage 'device_source_order.py'
$policy=Join-Path $stage 'device-policy.json'
$python='C:\AFZ\Stremio-Failover-H3\.venv\Scripts\python.exe'
$receipt=Join-Path $stage 'device-order-process.json'
$original='d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f'
function Sha([string]$path){return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
if((Sha $backend) -ne $original){throw 'Underlying production backend changed; require explicit reconciliation'}
if(-not(Test-Path $source) -or -not(Test-Path $policy)){throw 'Source or policy is missing'}
if(-not(Test-Path $python)){throw 'Pinned Python environment unavailable'}
if(Test-Path $receipt){throw 'Existing sidecar receipt present; do not create overlapping process'}
if(Get-NetTCPConnection -State Listen -LocalPort 18789 -ErrorAction SilentlyContinue){throw 'Sidecar port 18789 already bound'}
Write-Output 'SIDECAR_PRECHECK=PASS'
if(-not $Apply){Write-Output 'SIDECAR_NOT_STARTED_DRYRUN';return}
$runArgs=@('-m','uvicorn','device_source_order:app','--app-dir',$stage,'--host','127.0.0.1','--port','18789','--lifespan','off','--no-access-log','--log-level','warning')
$proc=Start-Process -FilePath $python -ArgumentList $runArgs -WorkingDirectory $stage -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $stage 'sidecar-stdout.log') -RedirectStandardError (Join-Path $stage 'sidecar-stderr.log')
$ready=$false
try {
  for($j=0;$j -lt 30;$j++){
    if($proc.HasExited){throw "Sidecar quit during startup ($($proc.ExitCode))"}
    try{
      $health=Invoke-RestMethod 'http://127.0.0.1:18789/health' -TimeoutSec 3
      if($health.ok -and $health.policy -eq 'phone-first-v1'){$ready=$true;break}
    }catch{}
    Start-Sleep -Milliseconds 500
  }
  if(-not $ready){throw 'Sidecar health probe did not succeed'}
  $status=[ordered]@{
    kind='AFZ-DEVICE-ORDER-V1'
    startedUtc=(Get-Date).ToUniversalTime().ToString('o')
    port=18789
    bind='127.0.0.1'
    pid=$proc.Id
    sourceSha256=Sha $source
    productionSha256=$original
    state='RUNNING'
    originalMediaCodeUnchanged=$true
  }
  [IO.File]::WriteAllText($receipt,($status|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
  Write-Output "SIDECAR_START_PID=$($proc.Id)"
  Write-Output "SIDECAR_LISTEN=127.0.0.1:18789"
}catch{
  if(-not $proc.HasExited){Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue}
  throw
}
