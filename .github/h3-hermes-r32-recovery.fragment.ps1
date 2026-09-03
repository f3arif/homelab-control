# R32: prove the exact OpenAI-compatible chat path Hermes uses, then refresh the
# Telegram gateway only after that path has answered. This is a bounded two-token
# canary; it does not pull a model, expose an API, or change provider/network settings.
if([bool]$result.ok){
  $recoveryPath=Join-Path $InstallRoot 'afz-openai-agent\H3-Hermes-Ollama-LivenessRecovery.ps1'
  if(-not(Test-Path -LiteralPath $recoveryPath -PathType Leaf)){
    $fail=[ordered]@{schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';controlPlane='github';source='windows-main';target='h3';host='DESKTOP-H3R6CQN';jobId=$id;ok=$false;classification='HERMES_R32_CHAT_RECOVERY_SCRIPT_MISSING';retryable=$true;deployment='native';transport=[string]$chosen.transport;routeDiagnostics=$routeDiagnostics;observedAt=(Get-Date -Format o)}
    Save-Result $fail;exit 1
  }
  $recoveryScript=Get-Content -LiteralPath $recoveryPath -Raw -Encoding UTF8
  $recoveryRun=Invoke-RemoteScript $chosen.target $chosen.extra $recoveryScript 360000
  $recoveryParsed=Parse-JsonResult $recoveryRun
  if($null -eq $recoveryParsed){
    $fail=[ordered]@{schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';controlPlane='github';source='windows-main';target='h3';host='DESKTOP-H3R6CQN';jobId=$id;ok=$false;classification='HERMES_R32_CHAT_RECOVERY_INVALID_RESULT';retryable=$true;deployment='native';transport=[string]$chosen.transport;recoveryTimedOut=[bool]$recoveryRun.timedOut;recoveryExit=$recoveryRun.exit;routeDiagnostics=$routeDiagnostics;observedAt=(Get-Date -Format o)}
    Save-Result $fail;exit 1
  }
  if(-not [bool]$recoveryParsed.ok){
    $fail=[ordered]@{schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';controlPlane='github';source='windows-main';target='h3';host='DESKTOP-H3R6CQN';jobId=$id;ok=$false;classification=[string]$recoveryParsed.classification;retryable=$true;deployment='native';transport=[string]$chosen.transport;chatCanaryIssued=$(if($recoveryParsed.PSObject.Properties.Name -contains 'chatCanaryIssued'){[bool]$recoveryParsed.chatCanaryIssued}else{$false});chatCanaryPassed=$(if($recoveryParsed.PSObject.Properties.Name -contains 'chatCanaryPassed'){[bool]$recoveryParsed.chatCanaryPassed}else{$false});gatewayLifecycle=$(if($recoveryParsed.PSObject.Properties.Name -contains 'gatewayLifecycle'){[string]$recoveryParsed.gatewayLifecycle}else{$null});routeDiagnostics=$routeDiagnostics;observedAt=(Get-Date -Format o)}
    Save-Result $fail;exit 1
  }
  $ready=[ordered]@{
    schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';controlPlane='github';source='windows-main';target='h3';host='DESKTOP-H3R6CQN';jobId=$id
    ok=$true;classification=[string]$recoveryParsed.classification;retryable=$false;deployment='native';transport=[string]$chosen.transport
    freshProbe=$true;providerName='ollama';providerIdentity='custom:ollama';providerConfigured=$true;providerApi='http://127.0.0.1:11434/v1';providerTransport='openai_chat'
    runtimeResolved=$true;runtimeProvider='custom';runtimeBaseUrl='http://127.0.0.1:11434/v1';runtimeApiMode='chat_completions'
    ollamaReachable=$true;selectedModel='qwen3.6:35b-a3b';contextLength=65536;modelListed=$true
    endpointReachableBefore=$(if($recoveryParsed.PSObject.Properties.Name -contains 'endpointReachableBefore'){[bool]$recoveryParsed.endpointReachableBefore}else{$null})
    ollamaServerStarted=$(if($recoveryParsed.PSObject.Properties.Name -contains 'ollamaServerStarted'){[bool]$recoveryParsed.ollamaServerStarted}else{$false})
    chatCanaryIssued=$true;chatCanaryPassed=$true;chatCanarySeconds=$(if($recoveryParsed.PSObject.Properties.Name -contains 'chatCanarySeconds'){$recoveryParsed.chatCanarySeconds}else{$null})
    messagingGatewayTouched=$true;gatewayLifecycle=$(if($recoveryParsed.PSObject.Properties.Name -contains 'gatewayLifecycle'){[string]$recoveryParsed.gatewayLifecycle}else{$null});gatewayLifecycleExit=$(if($recoveryParsed.PSObject.Properties.Name -contains 'gatewayLifecycleExit'){$recoveryParsed.gatewayLifecycleExit}else{$null})
    beforeGatewayPids=$(if($recoveryParsed.PSObject.Properties.Name -contains 'beforeGatewayPids'){@($recoveryParsed.beforeGatewayPids)}else{@()});afterGatewayPids=$(if($recoveryParsed.PSObject.Properties.Name -contains 'afterGatewayPids'){@($recoveryParsed.afterGatewayPids)}else{@()})
    generationTestStarted=$true;generationTestPurpose='bounded-chat-canary';generationMaxTokens=2;modelPullStarted=$false;ollamaMutationStarted=$false;networkChanged=$false;routeDiagnostics=$routeDiagnostics;observedAt=(Get-Date -Format o)
  }
  Save-Result $ready;exit 0
}
