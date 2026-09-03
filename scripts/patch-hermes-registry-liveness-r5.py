from pathlib import Path

remote = Path('afz-openai-agent/Read-H3-Hermes-RegistryLiveness.ps1')
text = remote.read_text(encoding='utf-8')
anchor = "$gateway=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {"
if anchor not in text:
    raise SystemExit('gateway anchor missing')
if 'HERMES_R5_READONLY_RUNTIME_AUDIT' not in text:
    block = r'''# HERMES_R5_READONLY_RUNTIME_AUDIT
# Read-only evidence for the actual Telegram model dependency. No provider/config,
# process, task, gateway, network, or model-generation mutation occurs here.
$ollamaReachable=$false;$ollamaModelListed=$false;$ollamaModelCount=0;$ollamaError=$null
try{
  $m=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/v1/models' -Method Get -TimeoutSec 8
  $ids=@($m.data|ForEach-Object{[string]$_.id})
  $ollamaReachable=$true;$ollamaModelListed=('qwen3.6:35b-a3b' -in $ids);$ollamaModelCount=$ids.Count
}catch{$ollamaError=$_.Exception.GetType().Name}

$ollamaProcs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{([string]$_.CommandLine) -match '(?i)ollama(?:[.]exe)?\s+serve'}|ForEach-Object{[ordered]@{pid=[int]$_.ProcessId;name=[string]$_.Name;parentPid=[int]$_.ParentProcessId}})

$watchdogName='AFZ H3 Ollama Liveness'
$watchdog=$null;$watchdogInfo=$null;$watchdogError=$null
try{$watchdog=Get-ScheduledTask -TaskName $watchdogName -ErrorAction Stop;$watchdogInfo=Get-ScheduledTaskInfo -TaskName $watchdogName -ErrorAction SilentlyContinue}catch{$watchdogError=$_.Exception.GetType().Name}

$modelConfig=[ordered]@{readable=$false;default=$null;provider=$null;baseUrl=$null;contextLength=$null;apiMode=$null;error=$null}
$hermes=Join-Path $root 'bin\hermes.exe'
if(Test-Path -LiteralPath $hermes -PathType Leaf){
  $oldHome=$env:HERMES_HOME
  try{
    $env:HERMES_HOME=$root
    $rawModel=((& $hermes config get model --json 2>&1|Out-String).Trim())
    if($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($rawModel)){
      $mc=$rawModel|ConvertFrom-Json
      $modelConfig.readable=$true
      if($mc.PSObject.Properties.Name -contains 'default'){$modelConfig.default=[string]$mc.default}
      if($mc.PSObject.Properties.Name -contains 'provider'){$modelConfig.provider=[string]$mc.provider}
      if($mc.PSObject.Properties.Name -contains 'base_url'){$modelConfig.baseUrl=[string]$mc.base_url}
      if($mc.PSObject.Properties.Name -contains 'context_length'){$modelConfig.contextLength=$mc.context_length}
      if($mc.PSObject.Properties.Name -contains 'api_mode'){$modelConfig.apiMode=[string]$mc.api_mode}
    }else{$modelConfig.error='CONFIG_GET_FAILED'}
  }catch{$modelConfig.error=$_.Exception.GetType().Name}
  finally{if($null -eq $oldHome){Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue}else{$env:HERMES_HOME=$oldHome}}
}else{$modelConfig.error='HERMES_EXE_MISSING'}

'''
    text = text.replace(anchor, block + anchor, 1)

old = """  gatewayProcesses=$gateway
  providerTouched=$false
"""
new = """  gatewayProcesses=$gateway
  ollamaReachable=$ollamaReachable
  ollamaModelListed=$ollamaModelListed
  ollamaModelCount=$ollamaModelCount
  ollamaError=$ollamaError
  ollamaServeProcesses=$ollamaProcs
  ollamaWatchdog=[ordered]@{exists=($null -ne $watchdog);state=$(if($watchdog){[string]$watchdog.State}else{$null});lastTaskResult=$(if($watchdogInfo){$watchdogInfo.LastTaskResult}else{$null});lastRunTime=$(if($watchdogInfo){$watchdogInfo.LastRunTime.ToString('o')}else{$null});nextRunTime=$(if($watchdogInfo){$watchdogInfo.NextRunTime.ToString('o')}else{$null});error=$watchdogError}
  modelConfig=$modelConfig
  providerTouched=$false
"""
if old not in text:
    raise SystemExit('remote emit anchor missing')
text = text.replace(old, new, 1)
remote.write_text(text,encoding='utf-8')

runner = Path('afz-openai-agent/Invoke-H3-Hermes-RegistryLivenessAudit.ps1')
r = runner.read_text(encoding='utf-8')
oldr = """    entries=$safeEntries;gatewayProcesses=$safeGateway
    providerTouched=$false;modelGenerationStarted=$false;ollamaMutationStarted=$false;networkChanged=$false;gatewayRestarted=$false;registryMutated=$false
"""
newr = """    entries=$safeEntries;gatewayProcesses=$safeGateway
    ollamaReachable=$(if($result.PSObject.Properties.Name -contains 'ollamaReachable'){[bool]$result.ollamaReachable}else{$false})
    ollamaModelListed=$(if($result.PSObject.Properties.Name -contains 'ollamaModelListed'){[bool]$result.ollamaModelListed}else{$false})
    ollamaModelCount=$(if($result.PSObject.Properties.Name -contains 'ollamaModelCount'){$result.ollamaModelCount}else{$null})
    ollamaError=$(if($result.PSObject.Properties.Name -contains 'ollamaError'){[string]$result.ollamaError}else{$null})
    ollamaServeProcesses=$(if($result.PSObject.Properties.Name -contains 'ollamaServeProcesses'){@($result.ollamaServeProcesses)}else{@()})
    ollamaWatchdog=$(if($result.PSObject.Properties.Name -contains 'ollamaWatchdog'){$result.ollamaWatchdog}else{$null})
    modelConfig=$(if($result.PSObject.Properties.Name -contains 'modelConfig'){$result.modelConfig}else{$null})
    providerTouched=$false;modelGenerationStarted=$false;ollamaMutationStarted=$false;networkChanged=$false;gatewayRestarted=$false;registryMutated=$false
"""
if oldr not in r:
    raise SystemExit('runner safe object anchor missing')
r = r.replace(oldr,newr,1)
runner.write_text(r,encoding='utf-8')

req=Path('afz-openai-agent/requests/h3-hermes-registry-liveness-audit.json')
q=req.read_text(encoding='utf-8')
if 'h3-hermes-registry-liveness-audit-20260903-r4' not in q:
    raise SystemExit('r4 audit id missing')
q=q.replace('h3-hermes-registry-liveness-audit-20260903-r4','h3-hermes-registry-liveness-audit-20260903-r5',1)
req.write_text(q,encoding='utf-8')
