param([switch]$Apply)
$ErrorActionPreference='Stop'
$stage='C:\AFZ\Nuvio-Setup-20260923\onn-tv-private-preview-20261011'
$source='C:\AFZ\Nuvio-Setup-20260923\onn-r2-r3-combined-20261011\stremio_catalog.r2-plus-r3.candidate.py'
$active='C:\AFZ\Stremio-Failover-H3\stremio_catalog.py'
$providerHealth='C:\AFZ\Stremio-Failover-H3\state\provider-health.json'
$python='C:\AFZ\Stremio-Failover-H3\.venv\Scripts\python.exe'
$previewUrl='https://desktop-h3r6cqn.tailc9bb62.ts.net:18886'
$expectedR2R3='2b7a5b73392f21b99ee4b2234062b4d75c7118fd6f7fecc0d841f32691ae6572'
$expectedActive='d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f'
$servicePort=18786
$receipt=Join-Path $stage 'preview-process.json'
$stateRoot=Join-Path $stage 'isolated-state'
function Sha([string]$p) {
  return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
}
function VerifyPreviewManifest {
  try {
    $r=Invoke-RestMethod -Uri 'http://127.0.0.1:18786/manifest.json' -TimeoutSec 5
    return ($r.id -eq 'com.afzengineering.nuvio.tvpreview.r2r3' -and
            $r.version -eq '0.6.244-preview.1' -and
            $r.resources.Count -eq 1 -and
            $r.types.Count -eq 1)
  }catch{return $false}
}
if((Sha $source) -ne $expectedR2R3){throw 'R2+R3 combined source hash mismatch'}
if((Sha $active) -ne $expectedActive){throw 'Production catalog source has changed; require explicit reconciliation'}
if(-not(Test-Path -LiteralPath (Join-Path $stage 'preview_app.py'))){throw 'Missing private stream-only wrapper'}
if(-not(Test-Path -LiteralPath $python)){throw 'Expected Python environment missing'}
if(Test-Path -LiteralPath $receipt){throw 'Existing preview process receipt must be reviewed, not overwritten'}
if(Get-NetTCPConnection -State Listen -LocalPort $servicePort -ErrorAction SilentlyContinue){throw 'Preview port already in use'}
Write-Output 'PREVIEW_GATES=PASS: version, original source unchanged, private port free'
if(-not $Apply){Write-Output 'PREVIEW_DRY_RUN_NO_CHANGE';return}
New-Item -ItemType Directory -Path $stateRoot -Force|Out-Null
$stageSource=Join-Path $stage 'stremio_catalog.py'
if(Test-Path -LiteralPath $stageSource){
  if((Sha $stageSource) -ne $expectedR2R3){throw 'Staged source mismatch; refusing replacement'}
}else{
  [IO.File]::Copy($source,$stageSource,$false)
}
if((Sha $stageSource) -ne $expectedR2R3){throw 'Private staged copy hash mismatch'}
$healthTarget=Join-Path $stateRoot 'provider-health.json'
if(-not(Test-Path -LiteralPath $healthTarget) -and (Test-Path -LiteralPath $providerHealth)){
  [IO.File]::Copy($providerHealth,$healthTarget,$false)
}
# All runtime state and scratch paths are private to the preview.
$env:AFZ_STATE_FILE=Join-Path $stateRoot 'stremio-state.json'
$env:AFZ_STREMIO_FAILOVER_MODE='1'
$env:STREMIO_CONTROL_BRIDGE_URL='http://127.0.0.1:18768'
$env:STREMIO_PUBLIC_BASE_URL=$previewUrl
$env:AFZ_BROWSER_PUBLIC_BASE=$previewUrl
$env:AFZ_NUVIO_PREVIEW_URL=$previewUrl
$empty=Join-Path $stage 'no-media'
$env:STREMIO_MEDIA_ROOT=$empty
$env:STREMIO_MEDIA_STORAGE_ROOT=Join-Path $empty 'Movies'
$env:STREMIO_TV_ROOT=Join-Path $empty 'TV'
$env:STREMIO_TV_STORAGE_ROOT=Join-Path $empty 'TV'
$env:STREMIO_JELLYFIN_ROOT=$empty
$env:SEERR_URL='http://127.0.0.1:9/api/v1'
$env:RADARR_URL='http://127.0.0.1:9/api/v3'
$env:SONARR_URL='http://127.0.0.1:9/api/v3'
$env:JELLYFIN_URL='http://127.0.0.1:9'
$env:SEERR_API_KEY=''
$env:RADARR_API_KEY=''
$env:NTFY_URL='http://127.0.0.1:9'
$env:JELLYFIN_DB=Join-Path $empty 'missing.db'
$env:JELLYSEERR_SETTINGS=Join-Path $empty 'missing.json'
$env:RDT_TORBOX_DB=Join-Path $empty 'missing-rdt.db'
$env:RDT_RD_DB=Join-Path $empty 'missing-rd.db'
$args=@('-m','uvicorn','preview_app:app','--app-dir',$stage,'--host','127.0.0.1','--port','18786','--lifespan','off','--no-access-log','--log-level','error')
$process=Start-Process -FilePath $python -ArgumentList $args -WorkingDirectory $stage -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $stage 'preview-stdout.log') -RedirectStandardError (Join-Path $stage 'preview-stderr.log')
$healthy=$false
try {
  for($i=0;$i -lt 30;$i++){
    if($process.HasExited){throw "Private preview process exited with code $($process.ExitCode)"}
    if(VerifyPreviewManifest){$healthy=$true;break}
    Start-Sleep -Milliseconds 500
  }
  if(-not $healthy){throw 'Private preview manifest failed local health check'}
  $result=[ordered]@{
    kind='AFZ-NUVIO-TV-PRIVATE-PREVIEW-R2R3'
    startedUtc=(Get-Date).ToUniversalTime().ToString('o')
    hostname=$env:COMPUTERNAME
    pid=$process.Id
    port=$servicePort
    localBinding='127.0.0.1'
    tailnetUrl=$previewUrl
    addonId='com.afzengineering.nuvio.tvpreview.r2r3'
    candidateSHA=$expectedR2R3
    productionUntouched=$true
    originalAddonUntouched=$true
    health='PASS'
  }
  [IO.File]::WriteAllText($receipt,($result|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
  Write-Output ('PREVIEW_STARTED_PID='+$process.Id)
  Write-Output ('PREVIEW_LOCAL_MANIFEST_OK='+$healthy)
  Write-Output ('PREVIEW_STATE='+$receipt)
}catch{
  if(-not $process.HasExited){
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
  }
  throw
}
