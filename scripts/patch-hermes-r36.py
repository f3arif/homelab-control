from pathlib import Path

p = Path('afz-openai-agent/Invoke-H3-HermesAgent-Install.ps1')
text = p.read_text(encoding='utf-8')

old = """    Register-ScheduledTask -TaskName $watchdogTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force|Out-Null
    $wt=Get-ScheduledTask -TaskName $watchdogTask -ErrorAction Stop
    $watchdogInstalled=$true;$watchdogTaskState=[string]$wt.State
"""
new = """    Register-ScheduledTask -TaskName $watchdogTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force|Out-Null
    # R36: launch the detached Task Scheduler guard immediately. Starting ollama
    # directly inside an SSH-hosted PowerShell process can die with that SSH job;
    # the task is the persistent owner and must be exercised before readiness.
    Start-ScheduledTask -TaskName $watchdogTask -ErrorAction Stop
    Start-Sleep -Seconds 3
    $wt=Get-ScheduledTask -TaskName $watchdogTask -ErrorAction Stop
    $wti=Get-ScheduledTaskInfo -TaskName $watchdogTask -ErrorAction SilentlyContinue
    $watchdogInstalled=$true;$watchdogTaskState=[string]$wt.State
    $watchdogTaskLastResult=$(if($wti){$wti.LastTaskResult}else{$null})
    $watchdogTaskLastRunTime=$(if($wti){$wti.LastRunTime.ToString('o')}else{$null})
"""
if old not in text:
    raise SystemExit('watchdog registration block not found')
text = text.replace(old, new, 1)

old2 = """  watchdogInstalled=$watchdogInstalled;watchdogTask=$watchdogTask;watchdogTaskState=$watchdogTaskState;watchdogError=$watchdogError;
"""
new2 = """  watchdogInstalled=$watchdogInstalled;watchdogTask=$watchdogTask;watchdogTaskState=$watchdogTaskState;watchdogTaskLastResult=$watchdogTaskLastResult;watchdogTaskLastRunTime=$watchdogTaskLastRunTime;watchdogError=$watchdogError;
"""
if old2 not in text:
    raise SystemExit('watchdog result block not found')
text = text.replace(old2, new2, 1)

marker = """  if(-not [bool]$recoveryParsed.ok){
"""
pos = text.find(marker)
if pos < 0:
    raise SystemExit('recovery failure marker missing')
# insert post-return proof AFTER the recoveryParsed failure block. Use a stable
# anchor at the start of $ready, which comes immediately after it.
anchor = """  $ready=[ordered]@{
"""
if anchor not in text:
    raise SystemExit('ready anchor missing')
if 'HERMES_R36_POST_RETURN_PERSISTENCE' not in text:
    block = r'''  # HERMES_R36_POST_RETURN_PERSISTENCE
  # The first SSH session can make Ollama look healthy while its child process is
  # still tied to the SSH job. Close that session, wait, then open a fresh session
  # that is strictly read-only with respect to process state and prove both models
  # and inference remain available. This is the readiness criterion Telegram needs.
  Start-Sleep -Seconds 12
  $postReturnProbe=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
$model='qwen3.6:35b-a3b'
$base='http://127.0.0.1:11434/v1'
$taskName='AFZ H3 Ollama Liveness'
function Emit($o,[int]$code){$o|ConvertTo-Json -Depth 10 -Compress;exit $code}
try{
  $m=Invoke-RestMethod -Uri ($base+'/models') -Method Get -TimeoutSec 8
  $ids=@($m.data|ForEach-Object{[string]$_.id})
  if($model -notin $ids){Emit ([ordered]@{ok=$false;classification='HERMES_POST_RETURN_MODEL_MISSING';endpointReachable=$true;modelListed=$false}) 61}
}catch{Emit ([ordered]@{ok=$false;classification='HERMES_POST_RETURN_ENDPOINT_DOWN';endpointReachable=$false;errorType=$_.Exception.GetType().Name}) 60}
$payload=@{model=$model;messages=@(@{role='user';content='ping'});max_tokens=1;temperature=0}|ConvertTo-Json -Depth 6 -Compress
$sw=[Diagnostics.Stopwatch]::StartNew()
try{
  $c=Invoke-RestMethod -Uri ($base+'/chat/completions') -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 180
  $sw.Stop()
  $chatOk=($null -ne $c -and $null -ne $c.choices -and @($c.choices).Count -gt 0)
  if(-not $chatOk){Emit ([ordered]@{ok=$false;classification='HERMES_POST_RETURN_CHAT_INVALID';endpointReachable=$true;modelListed=$true;chatSeconds=[math]::Round($sw.Elapsed.TotalSeconds,2)}) 62}
}catch{$sw.Stop();Emit ([ordered]@{ok=$false;classification='HERMES_POST_RETURN_CHAT_FAILED';endpointReachable=$true;modelListed=$true;chatSeconds=[math]::Round($sw.Elapsed.TotalSeconds,2);errorType=$_.Exception.GetType().Name}) 63}
$task=$null;$info=$null
try{$task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop;$info=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue}catch{}
Emit ([ordered]@{ok=$true;classification='HERMES_POST_RETURN_PERSISTENCE_READY';endpointReachable=$true;modelListed=$true;chatPassed=$true;chatSeconds=[math]::Round($sw.Elapsed.TotalSeconds,2);watchdogExists=($null -ne $task);watchdogState=$(if($task){[string]$task.State}else{$null});watchdogLastResult=$(if($info){$info.LastTaskResult}else{$null});watchdogLastRunTime=$(if($info){$info.LastRunTime.ToString('o')}else{$null});observedAt=(Get-Date -Format o)}) 0
'@
  $postReturnRun=Invoke-RemoteScript $chosen.target $chosen.extra $postReturnProbe 240000
  $postReturnParsed=Parse-JsonResult $postReturnRun
  if($null -eq $postReturnParsed -or -not [bool]$postReturnParsed.ok){
    $postClass=$(if($postReturnParsed -and $postReturnParsed.PSObject.Properties.Name -contains 'classification'){[string]$postReturnParsed.classification}else{'HERMES_POST_RETURN_PERSISTENCE_INVALID_RESULT'})
    $fail=[ordered]@{schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';controlPlane='github';source='windows-main';target='h3';host='DESKTOP-H3R6CQN';jobId=$id;ok=$false;classification=$postClass;retryable=$true;deployment='native';transport=[string]$chosen.transport;postReturnTimedOut=[bool]$postReturnRun.timedOut;postReturnExit=$postReturnRun.exit;postReturnPersisted=$false;routeDiagnostics=$routeDiagnostics;observedAt=(Get-Date -Format o)}
    Save-Result $fail;exit 1
  }
'''
    text = text.replace(anchor, block + anchor, 1)

# Surface R35 and R36 proof fields into the authoritative ready result.
old3 = """    chatCanaryIssued=$true;chatCanaryPassed=$true;chatCanarySeconds=$(if($recoveryParsed.PSObject.Properties.Name -contains 'chatCanarySeconds'){$recoveryParsed.chatCanarySeconds}else{$null})
    messagingGatewayTouched=$true;gatewayLifecycle=$(if($recoveryParsed.PSObject.Properties.Name -contains 'gatewayLifecycle'){[string]$recoveryParsed.gatewayLifecycle}else{$null});gatewayLifecycleExit=$(if($recoveryParsed.PSObject.Properties.Name -contains 'gatewayLifecycleExit'){$recoveryParsed.gatewayLifecycleExit}else{$null})
"""
new3 = """    chatCanaryIssued=$true;chatCanaryPassed=$true;chatCanarySeconds=$(if($recoveryParsed.PSObject.Properties.Name -contains 'chatCanarySeconds'){$recoveryParsed.chatCanarySeconds}else{$null})
    modelRuntimeConfigured=$(if($recoveryParsed.PSObject.Properties.Name -contains 'modelRuntimeConfigured'){[bool]$recoveryParsed.modelRuntimeConfigured}else{$false});modelConfigChanged=$(if($recoveryParsed.PSObject.Properties.Name -contains 'modelConfigChanged'){[bool]$recoveryParsed.modelConfigChanged}else{$false})
    hermesCliCanaryPassed=$(if($recoveryParsed.PSObject.Properties.Name -contains 'hermesCliCanaryPassed'){[bool]$recoveryParsed.hermesCliCanaryPassed}else{$false});hermesCliCanaryExit=$(if($recoveryParsed.PSObject.Properties.Name -contains 'hermesCliCanaryExit'){$recoveryParsed.hermesCliCanaryExit}else{$null});hermesCliCanarySeconds=$(if($recoveryParsed.PSObject.Properties.Name -contains 'hermesCliCanarySeconds'){$recoveryParsed.hermesCliCanarySeconds}else{$null})
    postReturnPersisted=$true;postReturnChatPassed=[bool]$postReturnParsed.chatPassed;postReturnChatSeconds=$postReturnParsed.chatSeconds;watchdogExists=$(if($postReturnParsed.PSObject.Properties.Name -contains 'watchdogExists'){[bool]$postReturnParsed.watchdogExists}else{$false});watchdogState=$(if($postReturnParsed.PSObject.Properties.Name -contains 'watchdogState'){[string]$postReturnParsed.watchdogState}else{$null});watchdogLastResult=$(if($postReturnParsed.PSObject.Properties.Name -contains 'watchdogLastResult'){$postReturnParsed.watchdogLastResult}else{$null})
    messagingGatewayTouched=$true;gatewayLifecycle=$(if($recoveryParsed.PSObject.Properties.Name -contains 'gatewayLifecycle'){[string]$recoveryParsed.gatewayLifecycle}else{$null});gatewayLifecycleExit=$(if($recoveryParsed.PSObject.Properties.Name -contains 'gatewayLifecycleExit'){$recoveryParsed.gatewayLifecycleExit}else{$null})
"""
if old3 not in text:
    raise SystemExit('ready proof insertion block missing')
text = text.replace(old3, new3, 1)

p.write_text(text, encoding='utf-8')

rq = Path('afz-openai-agent/requests/h3-hermes-agent-install.json')
r = rq.read_text(encoding='utf-8')
if 'h3-hermes-chat-gateway-recovery-20260903-r35' not in r:
    raise SystemExit('r35 request id missing')
r = r.replace('h3-hermes-chat-gateway-recovery-20260903-r35','h3-hermes-chat-gateway-recovery-20260903-r36',1)
rq.write_text(r, encoding='utf-8')
