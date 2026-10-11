param([switch]$Apply)
$ErrorActionPreference='Stop'
$root='C:\AFZ\Stremio-Failover-H3'
$stage='C:\AFZ\Nuvio-Setup-20260923\onn-expired-token-repair-20261011'
$src=Join-Path $root 'stremio_catalog.py'
$candidate=Join-Path $stage 'stremio_catalog.r2.candidate.py'
$backup=Join-Path $root 'stremio_catalog.py.before-onn-expired-token-20261011-r2.bak'
$tmp=Join-Path $root 'stremio_catalog.py.onn-r2.stage.tmp'
$launcher=Join-Path $root 'Start-AFZ-Stremio-H3-Core243.ps1'
$python=Join-Path $root '.venv\Scripts\python.exe'
$expectedOld='d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f'
$expectedNew='3dab113e23725a39401f8ba3c619b9eb0b6cd5eec47a0f677df2dc84404a74a5'
$receipt=[ordered]@{
  createdUtc=(Get-Date).ToUniversalTime().ToString('o')
  mode=$(if($Apply){'apply'}else{'dry-run'})
  baselineSha256=$expectedOld
  candidateSha256=$expectedNew
  status='STARTED'
  backupPath=$backup
  candidateInstalled=$false
  rollbackAttempted=$false
  rollbackSucceeded=$false
  noOtherServicesChanged=$true
}
$installed=$false
function Sha([string]$path) {return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
function CurrentListener {
    return (Get-NetTCPConnection -State Listen -LocalPort 18774 -ErrorAction SilentlyContinue |
      Where-Object { $_.LocalAddress -eq '127.0.0.1' } | Select-Object -First 1)
}
function AssertIdle {
    $sessions=@(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
      Where-Object { $_.LocalPort -in @(18774,8445,10000) })
    if($sessions.Count -gt 0) {
      throw "ACTIVE_STREAM_CLIENT_CONNECTIONS=$($sessions.Count); no deployment"
    }
}
function VerifyManifest {
    try {
       $m=Invoke-RestMethod 'http://127.0.0.1:18774/manifest.json' -TimeoutSec 5
       return ($m.id -eq 'com.afzengineering.releasecatalog' -and $m.version -eq '0.6.243')
    } catch {return $false}
}
function RestartCheckedCatalog {
    $listener=CurrentListener
    if($listener) {
        $catalogPid=[int]$listener.OwningProcess
        $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$catalogPid"
        if(-not $proc -or $proc.Name -notmatch '^python' -or
            $proc.CommandLine -notmatch 'uvicorn stremio_catalog:app' -or
            $proc.CommandLine -notmatch '--port 18774') {
            throw 'UNVERIFIED_PROCESS_OWNS_CATALOG_PORT'
        }
        AssertIdle
        Stop-Process -Id $catalogPid -Force
        $deadline=(Get-Date).AddSeconds(12)
        while((CurrentListener) -and (Get-Date)-lt $deadline) {Start-Sleep -Milliseconds 250}
        if(CurrentListener) {throw 'CATALOG_LISTENER_DID_NOT_RELEASE'}
    }
    $runOutput=@(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher 2>&1)
    $code=$LASTEXITCODE
    if($code -ne 0) { throw "CATALOG_LAUNCHER_EXIT_$code" }
    $deadline=(Get-Date).AddSeconds(30)
    while((Get-Date)-lt $deadline) {
        if(VerifyManifest) {return}
        Start-Sleep -Seconds 2
    }
    throw 'CATALOG_MANIFEST_UNHEALTHY_AFTER_RESTART'
}
try {
    if((Sha $src) -ne $expectedOld){throw 'BASELINE_SHA_MISMATCH'}
    if((Sha $candidate) -ne $expectedNew){throw 'CANDIDATE_SHA_MISMATCH'}
    if((Sha (Join-Path $stage 'stremio_catalog.original.py')) -ne $expectedOld){throw 'PRESERVED_ORIGINAL_HASH_MISMATCH'}
    if(-not(VerifyManifest)){throw 'BASELINE_MANIFEST_UNHEALTHY'}
    if(-not(Test-Path -LiteralPath $launcher)){throw 'LAUNCHER_MISSING'}
    if(-not(Test-Path -LiteralPath $python)){throw 'PYTHON_MISSING'}
    if(Test-Path -LiteralPath $backup){throw 'BACKUP_ALREADY_EXISTS_PREVENT_OVERWRITE'}
    AssertIdle
    Write-Output 'GATE=PASS old-catalog-hash, candidate-hash, baseline-health, zero-connected-streams'
    if(-not $Apply){
        $receipt.status='PREFLIGHT_PASS_NOT_APPLIED'
        Write-Output 'LIVE_CHANGE=NONE'
    } else {
        [IO.File]::Copy($src,$backup,$false)
        if((Sha $backup) -ne $expectedOld){throw 'BACKUP_VERIFICATION_FAILED'}
        [IO.File]::Copy($candidate,$tmp,$true)
        [IO.File]::Replace($tmp,$src,$null)
        $installed=$true
        $receipt.candidateInstalled=$true
        if((Sha $src) -ne $expectedNew){throw 'POST_COPY_CANDIDATE_MISMATCH'}
        Write-Output 'SOURCE_INSTALL=PASS; RESTARTING_ONLY_CATALOG'
        RestartCheckedCatalog
        Write-Output 'MANIFEST_RESTART=PASS'
        & $python (Join-Path $stage 'postdeploy_r2.py')
        if($LASTEXITCODE -ne 0){throw 'POSTDEPLOY_SMOKE_FAILED'}
        $receipt.status='DEPLOYED_AND_SMOKE_VERIFIED'
        Write-Output 'DEPLOY_RESULT=PASS'
    }
} catch {
    $receipt.status='FAILED'
    $receipt.error=$_.Exception.Message
    Write-Output ('DEPLOY_ERROR='+$_.Exception.Message)
    if($installed -and (Test-Path -LiteralPath $backup)) {
       $receipt.rollbackAttempted=$true
       try{
          $restoreTemp=Join-Path $root 'stremio_catalog.py.onn-r2.rollback.tmp'
          [IO.File]::Copy($backup,$restoreTemp,$true)
          [IO.File]::Replace($restoreTemp,$src,$null)
          if((Sha $src) -ne $expectedOld){throw 'ROLLBACK_CONTENT_HASH_MISMATCH'}
          RestartCheckedCatalog
          if(-not(VerifyManifest)){throw 'ROLLBACK_MANIFEST_UNHEALTHY'}
          $receipt.rollbackSucceeded=$true
          $receipt.status='ROLLED_BACK'
          Write-Output 'ROLLBACK_RESULT=VERIFIED'
       } catch {
          $receipt.rollbackError=$_.Exception.Message
          $receipt.status='ROLLBACK_BLOCKED_MANUAL_RECOVERY_REQUIRED'
          Write-Output ('ROLLBACK_ERROR='+$_.Exception.Message)
       }
    }
} finally {
    $receipt.completedUtc=(Get-Date).ToUniversalTime().ToString('o')
    try { $receipt.liveSourceSha256=Sha $src } catch {}
    $outPath=Join-Path $stage $(if($Apply){'r2-deployment-result.json'}else{'r2-deployment-dry-run.json'})
    ($receipt | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $outPath -Encoding UTF8
    Write-Output ('RECEIPT='+$outPath)
    Write-Output ('STATUS='+$receipt.status)
}
if($receipt.status -notin @('PREFLIGHT_PASS_NOT_APPLIED','DEPLOYED_AND_SMOKE_VERIFIED')){
    exit 1
}
