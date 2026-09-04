$ErrorActionPreference='Continue'
$JobId='9d9eea1b7618'
$BaseModel='qwen3.8-ridge:27b-64k'
$TargetModel='qwen3.8-ridge:27b-64k-rh1'
$Ollama='C:\Users\Faiz\AppData\Local\Programs\Ollama\ollama.exe'
$Hermes='C:\Users\Faiz\AppData\Local\hermes\bin\hermes.exe'
Write-Output '=== RADIOHILAL H3 RIDGE64K RH1 REPAIR START ==='
Write-Output ('HOST='+$env:COMPUTERNAME)
Write-Output ('JOB='+$JobId)
Write-Output ('BASE='+$BaseModel)
Write-Output ('TARGET='+$TargetModel)

if(-not(Test-Path $Ollama)){ Write-Output 'FAIL=OLLAMA_MISSING'; exit 20 }
if(-not(Test-Path $Hermes)){ Write-Output 'FAIL=HERMES_MISSING'; exit 21 }

$show = (& $Ollama show $BaseModel 2>&1 | Out-String)
Write-Output '--- BASE_SHOW_KEYLINES ---'
($show -split '\r?\n' | Where-Object { $_ -match 'architecture|parameters|context length|num_ctx|quantization' }) | Write-Output
if($show -notmatch 'context length\s+262144'){ Write-Output 'FAIL=BASE_ARCH_CONTEXT_NOT_262144'; exit 22 }
if($show -notmatch 'num_ctx\s+65536'){ Write-Output 'FAIL=BASE_NUM_CTX_NOT_65536'; exit 23 }

$modelfile = (& $Ollama show $BaseModel --modelfile 2>&1 | Out-String)
if([string]::IsNullOrWhiteSpace($modelfile)){ Write-Output 'FAIL=MODEFILE_EMPTY'; exit 24 }
$patched=$modelfile
$before=$patched
$patched=[regex]::Replace($patched,"reasoning_effort\s*==\s*'xhigh'","(reasoning_effort == 'xhigh' or reasoning_effort == 'high')")
$patched=[regex]::Replace($patched,'reasoning_effort\s*==\s*"xhigh"','(reasoning_effort == "xhigh" or reasoning_effort == "high")')
$patched=[regex]::Replace($patched,"'xhigh'\s*,\s*'medium'\s*,\s*'low'","'xhigh', 'high', 'medium', 'low'")
$patched=[regex]::Replace($patched,'"xhigh"\s*,\s*"medium"\s*,\s*"low"','"xhigh", "high", "medium", "low"')
if($patched -eq $before){
  Write-Output 'FAIL=NO_RECOGNIZED_REASONING_TEMPLATE_PATTERN'
  Write-Output 'MUTATION=NONE'
  exit 25
}
Write-Output 'PATCH_PATTERN=APPLIED'

$tmp=Join-Path $env:TEMP ('radiohilal-ridge64k-rh1-'+[guid]::NewGuid().ToString('N')+'.Modelfile')
[IO.File]::WriteAllText($tmp,$patched,(New-Object Text.UTF8Encoding($false)))
try {
  $existing = (& $Ollama list 2>&1 | Out-String)
  if($existing -match [regex]::Escape($TargetModel)){
    Write-Output 'TARGET_ALREADY_EXISTS=YES'
  } else {
    Write-Output '--- CREATE_TARGET ---'
    $create = (& $Ollama create $TargetModel -f $tmp 2>&1 | Out-String)
    Write-Output $create
    Write-Output ('CREATE_EXIT='+$LASTEXITCODE)
    if($LASTEXITCODE -ne 0){ Write-Output 'FAIL=OLLAMA_CREATE'; exit 26 }
  }

  $targetShow=(& $Ollama show $TargetModel 2>&1 | Out-String)
  Write-Output '--- TARGET_SHOW_KEYLINES ---'
  ($targetShow -split '\r?\n' | Where-Object { $_ -match 'architecture|parameters|context length|num_ctx|quantization' }) | Write-Output
  if($targetShow -notmatch 'context length\s+262144' -or $targetShow -notmatch 'num_ctx\s+65536'){
    Write-Output 'FAIL=TARGET_CONTEXT_VERIFY'
    exit 27
  }

  Write-Output '--- OLLAMA_HIGH_EFFORT_SMOKE ---'
  $body=[ordered]@{
    model=$TargetModel
    messages=@(@{role='user';content='Reply only OK'})
    max_tokens=8
    stream=$false
    reasoning_effort='high'
  } | ConvertTo-Json -Depth 8 -Compress
  try {
    $resp=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/v1/chat/completions' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 120
    $content=[string]$resp.choices[0].message.content
    Write-Output ('SMOKE_CONTENT='+($content -replace '[\r\n]+',' '))
    Write-Output 'SMOKE=PASS'
  } catch {
    Write-Output ('SMOKE=FAIL '+($_.Exception.Message -replace '[\r\n]+',' '))
    Write-Output 'CRON_MUTATION=NONE'
    exit 28
  }

  Write-Output '--- CRON_REPIN_WHILE_PAUSED ---'
  $edit=(& $Hermes cron edit $JobId --schedule 'every 30m' --provider ollama --model $TargetModel 2>&1 | Out-String)
  Write-Output $edit
  Write-Output ('EDIT_EXIT='+$LASTEXITCODE)
  if($LASTEXITCODE -ne 0){ Write-Output 'FAIL=CRON_EDIT'; exit 29 }

  Write-Output '--- RESUME_FOR_BOUNDED_TEST ---'
  $resume=(& $Hermes cron resume $JobId 2>&1 | Out-String)
  Write-Output $resume
  Write-Output ('RESUME_EXIT='+$LASTEXITCODE)
  if($LASTEXITCODE -ne 0){ Write-Output 'FAIL=CRON_RESUME'; exit 30 }

  Write-Output '--- BOUNDED_CRON_TEST ---'
  $run=(& $Hermes cron run $JobId 2>&1 | Out-String)
  Write-Output $run
  $runExit=$LASTEXITCODE
  Write-Output ('RUN_EXIT='+$runExit)
  $failed=($runExit -ne 0 -or $run -match 'Ran now:\s*failed' -or $run -match '(?i)RuntimeError|ValueError|HTTP 500')
  if($failed){
    Write-Output 'TEST=FAIL_REPAUSE'
    & $Hermes cron pause $JobId 2>&1 | Out-String | Write-Output
    Write-Output 'FINAL_STATE=PAUSED'
    exit 31
  }
  Write-Output 'TEST=PASS'

  Write-Output '--- GATEWAY_STATUS ---'
  $status=(& $Hermes cron status 2>&1 | Out-String)
  Write-Output $status
  if($status -match '(?i)Gateway is not running'){
    Write-Output 'GATEWAY_START=ATTEMPT'
    try { Start-Process -FilePath $Hermes -ArgumentList @('gateway') -WindowStyle Hidden | Out-Null } catch { Write-Output ('GATEWAY_START_ERR='+$_.Exception.Message) }
    Start-Sleep -Seconds 4
    & $Hermes cron status 2>&1 | Out-String | Write-Output
  }

  Write-Output '--- FINAL_CRON ---'
  & $Hermes cron list --all 2>&1 | Out-String | Write-Output
  Write-Output 'FINAL_STATE=RESUMED'
  Write-Output 'PINNED_PROVIDER=ollama'
  Write-Output ('PINNED_MODEL='+$TargetModel)
  Write-Output 'GLOBAL_HERMES_CONFIG_MUTATION=NONE'
  Write-Output 'BASE_MODELS_MUTATION=NONE'
} finally {
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
Write-Output '=== RADIOHILAL H3 RIDGE64K RH1 REPAIR END ==='
