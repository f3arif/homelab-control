from pathlib import Path

p = Path('afz-openai-agent/H3-Hermes-Ollama-LivenessRecovery.ps1')
text = p.read_text(encoding='utf-8')
marker = '# Prove and pre-warm the exact OpenAI-compatible chat path Hermes uses.'
if marker not in text:
    raise SystemExit('chat canary marker missing')
if 'HERMES_R35_MODEL_RUNTIME_CONFIG' not in text:
    block = r'''# HERMES_R35_MODEL_RUNTIME_CONFIG
# Telegram resolves the main model from config.yaml's top-level model block.
# Provider-registry health and a raw REST canary do not prove that runtime route.
$modelConfigBefore=$null
$modelConfigAfter=$null
$modelConfigChanged=$false
$oldHomeCfg=$env:HERMES_HOME
try{
  $env:HERMES_HOME=$hermesRoot
  try{$modelConfigBefore=((& $hermes config get model --json 2>&1|Out-String).Trim())}catch{}
  foreach($setting in @(
    @('model.default',$model),
    @('model.provider','custom'),
    @('model.base_url',$baseUrl),
    @('model.context_length','65536'),
    @('model.api_mode','chat_completions')
  )){
    & $hermes config set $setting[0] $setting[1] *> $null
    if($LASTEXITCODE -ne 0){throw ('config set failed: '+$setting[0])}
  }
  $modelConfigAfter=((& $hermes config get model --json 2>&1|Out-String).Trim())
  if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($modelConfigAfter)){throw 'model readback failed'}
  $mc=$modelConfigAfter|ConvertFrom-Json
  if([string]$mc.default -ne $model -or [string]$mc.provider -ne 'custom' -or ([string]$mc.base_url).TrimEnd('/') -ne $baseUrl.TrimEnd('/') -or [int]$mc.context_length -ne 65536 -or [string]$mc.api_mode -ne 'chat_completions'){
    throw 'model runtime readback mismatch'
  }
  $modelConfigChanged=($modelConfigBefore -ne $modelConfigAfter)
}catch{
  Save-And-Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_MAIN_MODEL_RUNTIME_CONFIG_FAILED';host=$env:COMPUTERNAME;model=$model;baseUrl=$baseUrl;modelConfigChanged=$modelConfigChanged;error=$_.Exception.Message;observedAt=(Get-Date -Format o)}) 38
}finally{
  if($null -eq $oldHomeCfg){Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue}else{$env:HERMES_HOME=$oldHomeCfg}
}

'''
    text = text.replace(marker, block + marker, 1)

marker2 = '# Refresh Telegram gateway only after the exact model route has answered.'
if marker2 not in text:
    raise SystemExit('gateway marker missing')
if 'HERMES_R35_HERMES_CLI_CANARY' not in text:
    block2 = r'''# HERMES_R35_HERMES_CLI_CANARY
# Prove Hermes itself resolves the configured default model to Ollama.
$hermesCliCanaryPassed=$false
$hermesCliCanaryExit=$null
$hermesCliCanarySeconds=$null
$hermesCliCanaryTimedOut=$false
$hermesCliOutFile=Join-Path $env:TEMP ('hermes-r35-cli-'+[guid]::NewGuid().ToString('n')+'.out')
$hermesCliErrFile=Join-Path $env:TEMP ('hermes-r35-cli-'+[guid]::NewGuid().ToString('n')+'.err')
$oldHomeCli=$env:HERMES_HOME
$swCli=[Diagnostics.Stopwatch]::StartNew()
try{
  $env:HERMES_HOME=$hermesRoot
  $cp=Start-Process -FilePath $hermes -ArgumentList @('chat','-q','ping') -RedirectStandardOutput $hermesCliOutFile -RedirectStandardError $hermesCliErrFile -PassThru -WindowStyle Hidden
  $hermesCliCanaryTimedOut=(-not $cp.WaitForExit(300000))
  if($hermesCliCanaryTimedOut){try{$cp.Kill()}catch{};try{$cp.WaitForExit()}catch{}}
  if(-not $hermesCliCanaryTimedOut){$hermesCliCanaryExit=[int]$cp.ExitCode;$hermesCliCanaryPassed=($hermesCliCanaryExit -eq 0)}
}finally{
  $swCli.Stop();$hermesCliCanarySeconds=[math]::Round($swCli.Elapsed.TotalSeconds,2)
  if($null -eq $oldHomeCli){Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue}else{$env:HERMES_HOME=$oldHomeCli}
}
if(-not $hermesCliCanaryPassed){
  $cliErr=''
  try{$cliErr=[IO.File]::ReadAllText($hermesCliErrFile)}catch{}
  $cliErr=[regex]::Replace($cliErr,'\b\d{7,12}:[A-Za-z0-9_-]{20,}\b','<REDACTED_TELEGRAM_TOKEN>')
  if($cliErr.Length -gt 1600){$cliErr=$cliErr.Substring($cliErr.Length-1600)}
  Remove-Item $hermesCliOutFile,$hermesCliErrFile -Force -ErrorAction SilentlyContinue
  Save-And-Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_MAIN_RUNTIME_CLI_CANARY_FAILED';host=$env:COMPUTERNAME;endpointReachable=$true;modelListed=$true;chatCanaryPassed=$true;hermesCliCanaryPassed=$false;hermesCliCanaryTimedOut=$hermesCliCanaryTimedOut;hermesCliCanaryExit=$hermesCliCanaryExit;hermesCliCanarySeconds=$hermesCliCanarySeconds;errorTail=$cliErr;modelConfigChanged=$modelConfigChanged;observedAt=(Get-Date -Format o)}) 39
}
Remove-Item $hermesCliOutFile,$hermesCliErrFile -Force -ErrorAction SilentlyContinue

'''
    text = text.replace(marker2, block2 + marker2, 1)

old = '  chatCanaryPassed=$true\n  chatCanarySeconds=$canarySeconds\n  gatewayLifecycle=$lifecycle'
new = '  chatCanaryPassed=$true\n  chatCanarySeconds=$canarySeconds\n  hermesCliCanaryPassed=$hermesCliCanaryPassed\n  hermesCliCanaryExit=$hermesCliCanaryExit\n  hermesCliCanarySeconds=$hermesCliCanarySeconds\n  modelRuntimeConfigured=$true\n  modelConfigChanged=$modelConfigChanged\n  gatewayLifecycle=$lifecycle'
if old not in text:
    raise SystemExit('final result insertion point missing')
text = text.replace(old, new, 1)
p.write_text(text, encoding='utf-8')

rq = Path('afz-openai-agent/requests/h3-hermes-agent-install.json')
r = rq.read_text(encoding='utf-8')
if 'h3-hermes-chat-gateway-recovery-20260903-r35' not in r:
    if 'h3-hermes-chat-gateway-recovery-20260903-r33' not in r:
        raise SystemExit('expected r33 request id missing')
    r = r.replace('h3-hermes-chat-gateway-recovery-20260903-r33','h3-hermes-chat-gateway-recovery-20260903-r35',1)
rq.write_text(r, encoding='utf-8')
