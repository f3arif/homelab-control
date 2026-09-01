#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$ExpectedTarget='coolyo@100.71.26.69'
$ExpectedProvider='openai-codex'
$ExpectedModel='gpt-5.6-luna'
$ExpectedContext=65536
$ExpectedAction='verify-and-configure-primary'
$TaskName='HP Envy Hermes OpenAI Codex Primary'
$SystemStateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\hpenvy-hermes-openai-codex-primary'
$UserStateRoot='C:\Users\Faiz\AppData\Local\AFZ\CodexPrimary'
$MirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$MirrorPath=Join-Path $MirrorRoot 'HPENVY-HERMES-OPENAI-CODEX-PRIMARY-LATEST.txt'
$HookMirror='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius\HPENVY-HERMES-OPENAI-CODEX-PRIMARY-HOOK-LATEST.txt'

$currentName=''
try{$currentName=[Security.Principal.WindowsIdentity]::GetCurrent().Name}catch{$currentName="$env:USERDOMAIN\$env:USERNAME"}
$isSystem=($currentName -match '(?i)(^|\\)SYSTEM$' -or [string]$env:USERNAME -ieq 'SYSTEM')
$StateRoot=$(if($isSystem){$SystemStateRoot}else{$UserStateRoot})
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

function Write-State([object]$Object,[string]$Path){
  $json=$Object | ConvertTo-Json -Depth 12
  try{$json | Set-Content -LiteralPath $Path -Encoding UTF8}catch{}
  try{if(Test-Path -LiteralPath $MirrorRoot -PathType Container){$json | Set-Content -LiteralPath $MirrorPath -Encoding UTF8}}catch{}
  try{$d=Split-Path -Parent $HookMirror;if(Test-Path -LiteralPath $d -PathType Container){$json | Set-Content -LiteralPath $HookMirror -Encoding UTF8}}catch{}
}
function SshClass([string]$Text,[int]$Code){
  if($Code -eq 0){return 'SSH_OK'}
  $t=([string]$Text).ToLowerInvariant()
  if($t -match 'host key verification failed|remote host identification has changed'){return 'SSH_HOST_KEY_REJECTED'}
  if($t -match 'permission denied|no supported authentication methods available|bad permissions'){return 'SSH_AUTH_REJECTED'}
  if($t -match 'connection timed out|operation timed out'){return 'SSH_CONNECT_TIMEOUT'}
  if($t -match 'connection refused'){return 'SSH_CONNECTION_REFUSED'}
  if($t -match 'no route to host|network is unreachable'){return 'SSH_NETWORK_UNREACHABLE'}
  return 'SSH_EXIT_'+$Code
}
function Get-JsonObject([string]$Text){
  if([string]::IsNullOrWhiteSpace($Text)){return $null}
  $a=$Text.IndexOf('{');$b=$Text.LastIndexOf('}')
  if($a -lt 0 -or $b -le $a){return $null}
  try{return ($Text.Substring($a,$b-$a+1)|ConvertFrom-Json)}catch{return $null}
}
function Get-Prop($Object,[string]$Name){
  if($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name){return $Object.$Name}
  return $null
}

if([string]::IsNullOrWhiteSpace($RequestPath)){throw 'RequestPath is required'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw 'Request missing'}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid request identity'}
if(([string]$req.taskName).Trim() -ne $TaskName -or ([string]$req.target).Trim() -ne $ExpectedTarget){throw 'Request target mismatch'}
if(([string]$req.action).Trim().ToLowerInvariant() -ne $ExpectedAction -or ([string]$req.provider).Trim().ToLowerInvariant() -ne $ExpectedProvider -or ([string]$req.model).Trim() -ne $ExpectedModel -or [int]$req.context_length -ne $ExpectedContext){throw 'Request model/provider mismatch'}
if(-not [bool]$req.allow_provider_switch -or [bool]$req.allow_generation -or [bool]$req.allow_gateway_start -or [bool]$req.allow_firewall_change -or [bool]$req.allow_tailscale_change){throw 'Unsafe request flags'}
if(([string]$req.status).Trim().ToLowerInvariant() -ne 'active'){throw 'Request is not active'}

$statePath=Join-Path $StateRoot ($id+'.json')
if(Test-Path -LiteralPath $statePath -PathType Leaf){
  try{
    $prior=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$prior.classification -eq 'HP_HERMES_CODEX_PRIMARY_CONFIGURED'){
      Write-State $prior $statePath;Write-Output ($prior|ConvertTo-Json -Depth 12 -Compress);exit 0
    }
  }catch{}
}

if($isSystem){
  if([string]$env:AFZ_CODEX_USER_WORKER -eq '1'){
    $r=[ordered]@{schema=1;requestId=$id;classification='HP_HERMES_CODEX_USER_WORKER_WRONG_IDENTITY';authVerified=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;executionIdentity='SYSTEM';time=(Get-Date -Format o)}
    Write-State $r $statePath;Write-Output ($r|ConvertTo-Json -Compress);exit 49
  }
  $queueDir='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Queue\windows-main'
  $workerResultDir='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
  $taskId=('000-hpenvy-hermes-codex-faiz-'+$id)
  $taskPath=Join-Path $queueDir ($taskId+'.ps1')
  $workerResultPath=Join-Path $workerResultDir ($taskId+'.txt')
  New-Item -ItemType Directory -Force -Path $queueDir | Out-Null
  if(-not(Test-Path -LiteralPath $taskPath -PathType Leaf) -and -not(Test-Path -LiteralPath $workerResultPath -PathType Leaf)){
    $task=@"
`$ErrorActionPreference='Stop'
`$env:AFZ_CODEX_USER_WORKER='1'
`$runner='$InstallRoot\afz-openai-agent\Invoke-HPEnvy-Hermes-OpenAICodexPrimary.ps1'
`$request='$InstallRoot\afz-openai-agent\requests\hpenvy-hermes-openai-codex-primary.json'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `$runner -InstallRoot '$InstallRoot' -RequestPath `$request
`$code=`$LASTEXITCODE
if(`$code -ne 0){exit `$code}
exit 0
"@
    $tmp=Join-Path $queueDir ('.'+$taskId+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
    [IO.File]::WriteAllText($tmp,$task,(New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $taskPath -Force
  }
  $r=[ordered]@{schema=1;requestId=$id;taskName=$TaskName;target=$ExpectedTarget;provider=$ExpectedProvider;model=$ExpectedModel;classification='HP_HERMES_CODEX_QUEUED_FAIZ_WORKER';authVerified=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;executionIdentity='SYSTEM';worker='windows-main';queueTask=$taskId;privateKeyCopied=$false;globalKnownHostsModified=$false;rawOutputPersistedInResult=$false;githubControl=$true;oneDriveRole='execution-bridge-existing-worker';time=(Get-Date -Format o)}
  Write-State $r $statePath;Write-Output ($r|ConvertTo-Json -Depth 12 -Compress);exit 0
}

$ssh=(Get-Command ssh.exe -ErrorAction SilentlyContinue).Source
if(-not $ssh){$ssh=(Get-Command ssh -ErrorAction SilentlyContinue).Source}
if(-not $ssh){throw 'OpenSSH client not found'}

$old=$ErrorActionPreference;$ErrorActionPreference='Continue'
$resolved=(& $ssh -G hpenvy-restic 2>&1 | Out-String).Trim();$resolveExit=$LASTEXITCODE
$ErrorActionPreference=$old
$mh=[regex]::Match($resolved,'(?im)^hostname\s+(\S+)\s*$')
$mu=[regex]::Match($resolved,'(?im)^user\s+(\S+)\s*$')
$resolvedHost=$(if($mh.Success){$mh.Groups[1].Value.Trim()}else{$null})
$resolvedUser=$(if($mu.Success){$mu.Groups[1].Value.Trim()}else{$null})
if($resolveExit -ne 0 -or $resolvedHost -ne '100.71.26.69' -or $resolvedUser -ne 'coolyo'){
  $r=[ordered]@{schema=1;requestId=$id;classification='HP_HERMES_CODEX_SSH_ALIAS_MISMATCH';authVerified=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;executionIdentity=$currentName;sshAlias='hpenvy-restic';resolvedHost=$resolvedHost;resolvedUser=$resolvedUser;time=(Get-Date -Format o)}
  Write-State $r $statePath;Write-Output ($r|ConvertTo-Json -Compress);exit 48
}

function Invoke-HpSsh([string]$Command){
  $save=$ErrorActionPreference;$ErrorActionPreference='Continue'
  $text=(& $ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes hpenvy-restic $Command 2>&1 | Out-String).Trim()
  $code=$LASTEXITCODE
  $ErrorActionPreference=$save
  return [pscustomobject]@{Text=$text;Code=$code;Class=(SshClass $text $code)}
}

$probe=Invoke-HpSsh 'printf "AFZ_REMOTE_REACHED=true\n"; hostname; id -un'
if($probe.Code -ne 0){
  $r=[ordered]@{schema=1;requestId=$id;classification=$probe.Class;remoteReached=$false;authVerified=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;sshExitCode=$probe.Code;sshClassification=$probe.Class;sshAlias='hpenvy-restic';executionIdentity=$currentName;rawOutputPersistedInResult=$false;time=(Get-Date -Format o)}
  Write-State $r $statePath;Write-Output ($r|ConvertTo-Json -Compress);exit 47
}
$pl=@($probe.Text -split "`r?`n" | ForEach-Object {$_.Trim()} | Where-Object {$_})
$remoteReached=($pl -contains 'AFZ_REMOTE_REACHED=true')
$targetOk=($pl -contains 'hpenvy' -and $pl -contains 'coolyo')
if(-not $remoteReached -or -not $targetOk){
  $r=[ordered]@{schema=1;requestId=$id;classification='HP_HERMES_CODEX_WRONG_TARGET';remoteReached=$remoteReached;authVerified=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;sshExitCode=0;sshClassification='SSH_OK';sshAlias='hpenvy-restic';executionIdentity=$currentName;rawOutputPersistedInResult=$false;time=(Get-Date -Format o)}
  Write-State $r $statePath;Write-Output ($r|ConvertTo-Json -Compress);exit 47
}

$authCmd='A="$HOME/.hermes/auth.json"; if [ -r "$A" ] && grep -q "\"openai-codex\"" "$A" && grep -q "\"access_token\"" "$A" && grep -q "\"refresh_token\"" "$A"; then printf "AUTH_VERIFIED=true\n"; else printf "AUTH_VERIFIED=false\n"; fi'
$authProbe=Invoke-HpSsh $authCmd
$authVerified=($authProbe.Code -eq 0 -and $authProbe.Text -match '(?m)^AUTH_VERIFIED=true\s*$')
if(-not $authVerified){
  $r=[ordered]@{schema=1;requestId=$id;classification='HP_HERMES_CODEX_AUTH_NOT_VERIFIED';remoteReached=$true;authVerified=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;sshExitCode=$authProbe.Code;sshClassification=$authProbe.Class;sshAlias='hpenvy-restic';executionIdentity=$currentName;rawOutputPersistedInResult=$false;time=(Get-Date -Format o)}
  Write-State $r $statePath;Write-Output ($r|ConvertTo-Json -Compress);exit 47
}

$configCmd='H="$HOME/.local/bin/hermes"; if [ ! -x "$H" ]; then exit 42; fi; "$H" config get model --json'
function Read-ModelConfig{
  $p=Invoke-HpSsh $configCmd
  if($p.Code -ne 0){return [pscustomobject]@{Ok=$false;Probe=$p;Provider=$null;Model=$null;Context=$null;BaseUrl=$null}}
  $cfg=Get-JsonObject $p.Text
  if($null -eq $cfg){return [pscustomobject]@{Ok=$false;Probe=$p;Provider=$null;Model=$null;Context=$null;BaseUrl=$null}}
  $m=$cfg
  if($cfg.PSObject.Properties.Name -contains 'model' -and $null -ne $cfg.model){$m=$cfg.model}
  $provider=Get-Prop $m 'provider';$model=Get-Prop $m 'default';$ctx=Get-Prop $m 'context_length';$base=Get-Prop $m 'base_url'
  return [pscustomobject]@{Ok=$true;Probe=$p;Provider=$(if($null -eq $provider){$null}else{[string]$provider});Model=$(if($null -eq $model){$null}else{[string]$model});Context=$(if($null -eq $ctx){$null}else{[string]$ctx});BaseUrl=$(if($null -eq $base){$null}else{[string]$base})}
}

$before=Read-ModelConfig
if(-not $before.Ok){
  $r=[ordered]@{schema=1;requestId=$id;classification='HP_HERMES_CODEX_CONFIG_READ_FAILED';remoteReached=$true;authVerified=$true;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;sshExitCode=$before.Probe.Code;sshClassification=$before.Probe.Class;sshAlias='hpenvy-restic';executionIdentity=$currentName;rawOutputPersistedInResult=$false;time=(Get-Date -Format o)}
  Write-State $r $statePath;Write-Output ($r|ConvertTo-Json -Compress);exit 47
}
$beforeCorrect=($before.Provider -eq $ExpectedProvider -and $before.Model -eq $ExpectedModel -and $before.Context -eq [string]$ExpectedContext -and [string]::IsNullOrWhiteSpace($before.BaseUrl))
if($beforeCorrect){
  $r=[ordered]@{schema=1;requestId=$id;taskName=$TaskName;target=$ExpectedTarget;provider=$ExpectedProvider;model=$ExpectedModel;classification='HP_HERMES_CODEX_PRIMARY_CONFIGURED';remoteReached=$true;authVerified=$true;configuredProvider=$before.Provider;configuredModel=$before.Model;contextLength=$before.Context;baseUrlPresent=$false;configurationChanged=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;sshExitCode=0;sshClassification='SSH_OK';sshAlias='hpenvy-restic';executionIdentity=$currentName;globalKnownHostsModified=$false;privateKeyCopied=$false;rawOutputPersistedInResult=$false;githubControl=$true;oneDriveRole='observability-only';time=(Get-Date -Format o)}
  Write-State $r $statePath;Write-Output ($r|ConvertTo-Json -Depth 12 -Compress);exit 0
}

$gateway=Invoke-HpSsh 'if pgrep -af "[h]ermes.*gateway" >/dev/null 2>&1; then printf "GATEWAY_RUNNING=true\n"; else printf "GATEWAY_RUNNING=false\n"; fi'
$gatewayRunning=($gateway.Code -eq 0 -and $gateway.Text -match '(?m)^GATEWAY_RUNNING=true\s*$')
if($gatewayRunning){
  $r=[ordered]@{schema=1;requestId=$id;classification='HP_HERMES_CODEX_GATEWAY_ALREADY_RUNNING_SAFE_STOP';remoteReached=$true;authVerified=$true;configuredProvider=$before.Provider;configuredModel=$before.Model;contextLength=$before.Context;baseUrlPresent=(-not [string]::IsNullOrWhiteSpace($before.BaseUrl));configurationChanged=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;sshExitCode=0;sshClassification='SSH_OK';sshAlias='hpenvy-restic';executionIdentity=$currentName;time=(Get-Date -Format o)}
  Write-State $r $statePath;Write-Output ($r|ConvertTo-Json -Compress);exit 47
}

$mutateCmd='C="$HOME/.hermes/config.yaml"; H="$HOME/.local/bin/hermes"; B="$HOME/.hermes/config.yaml.afz-pre-codex-r7.bak"; if [ ! -x "$H" ] || [ ! -r "$C" ]; then printf "CONFIG_MUTATION_OK=false\n"; exit 42; fi; cp -p "$C" "$B" || exit 45; if "$H" config set model.default gpt-5.6-luna >/dev/null 2>&1 && "$H" config set model.provider openai-codex >/dev/null 2>&1 && "$H" config set model.context_length 65536 >/dev/null 2>&1; then "$H" config unset model.base_url >/dev/null 2>&1 || true; printf "CONFIG_MUTATION_OK=true\n"; exit 0; else cp -p "$B" "$C"; printf "CONFIG_MUTATION_OK=false\n"; exit 45; fi'
$mutation=Invoke-HpSsh $mutateCmd
$mutationOk=($mutation.Code -eq 0 -and $mutation.Text -match '(?m)^CONFIG_MUTATION_OK=true\s*$')
if(-not $mutationOk){
  $r=[ordered]@{schema=1;requestId=$id;classification='HP_HERMES_CODEX_CONFIG_SET_FAILED_ROLLED_BACK';remoteReached=$true;authVerified=$true;configuredProvider=$before.Provider;configuredModel=$before.Model;contextLength=$before.Context;baseUrlPresent=(-not [string]::IsNullOrWhiteSpace($before.BaseUrl));configurationChanged=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;sshExitCode=$mutation.Code;sshClassification=$mutation.Class;sshAlias='hpenvy-restic';executionIdentity=$currentName;rawOutputPersistedInResult=$false;time=(Get-Date -Format o)}
  Write-State $r $statePath;Write-Output ($r|ConvertTo-Json -Compress);exit 47
}

$after=Read-ModelConfig
$afterCorrect=($after.Ok -and $after.Provider -eq $ExpectedProvider -and $after.Model -eq $ExpectedModel -and $after.Context -eq [string]$ExpectedContext -and [string]::IsNullOrWhiteSpace($after.BaseUrl))
if(-not $afterCorrect){
  $rollback=Invoke-HpSsh 'C="$HOME/.hermes/config.yaml"; B="$HOME/.hermes/config.yaml.afz-pre-codex-r7.bak"; if [ -r "$B" ]; then cp -p "$B" "$C" && printf "ROLLBACK_OK=true\n"; else printf "ROLLBACK_OK=false\n"; fi'
  $r=[ordered]@{schema=1;requestId=$id;classification='HP_HERMES_CODEX_CONFIG_VERIFY_FAILED_ROLLED_BACK';remoteReached=$true;authVerified=$true;configuredProvider=$(if($after.Ok){$after.Provider}else{$null});configuredModel=$(if($after.Ok){$after.Model}else{$null});contextLength=$(if($after.Ok){$after.Context}else{$null});baseUrlPresent=$(if($after.Ok){-not [string]::IsNullOrWhiteSpace($after.BaseUrl)}else{$false});configurationChanged=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;rollbackConfirmed=($rollback.Code -eq 0 -and $rollback.Text -match '(?m)^ROLLBACK_OK=true\s*$');sshAlias='hpenvy-restic';executionIdentity=$currentName;rawOutputPersistedInResult=$false;time=(Get-Date -Format o)}
  Write-State $r $statePath;Write-Output ($r|ConvertTo-Json -Compress);exit 47
}

$r=[ordered]@{schema=1;requestId=$id;taskName=$TaskName;target=$ExpectedTarget;provider=$ExpectedProvider;model=$ExpectedModel;classification='HP_HERMES_CODEX_PRIMARY_CONFIGURED';remoteReached=$true;authVerified=$true;configuredProvider=$after.Provider;configuredModel=$after.Model;contextLength=$after.Context;baseUrlPresent=$false;configurationChanged=$true;providerSwitched=$true;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;sshExitCode=0;sshClassification='SSH_OK';sshAlias='hpenvy-restic';executionIdentity=$currentName;globalKnownHostsModified=$false;privateKeyCopied=$false;rawOutputPersistedInResult=$false;githubControl=$true;oneDriveRole='observability-only';time=(Get-Date -Format o)}
Write-State $r $statePath
Write-Output ($r|ConvertTo-Json -Depth 12 -Compress)
exit 0
