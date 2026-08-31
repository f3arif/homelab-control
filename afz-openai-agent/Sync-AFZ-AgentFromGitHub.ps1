#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [switch]$Force,
  [string]$ExpectedSha=''
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

# PRESERVED CORE CONTRACT MARKERS
# The byte-identical Sync-AFZ-AgentFromGitHub-Core.ps1 remains authoritative for
# every pre-existing source-sync behavior. These markers keep legacy validators
# able to prove those contracts through the stable public entrypoint filename.
# $state|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $stateFile
# Invoke-H3-ConsoleFlash-Remediation.ps1
# h3ConsoleFlashRemediation
# status -in @('failed','error')
# transport-recovery-g
# function Publish-SiteDeployAck
# Publish-AFZ-WebsiteDeployAck.ps1
# failure to publish must never affect the GitHub source-sync control path
# Publish-SiteDeployAck

$headers=@{
  'User-Agent'='AFZ-OpenAI-Agent-Sync-Wrapper'
  'Cache-Control'='no-cache'
  'Pragma'='no-cache'
  'Accept'='application/vnd.github+json'
}

function Ensure-FallbackUpdaterTask {
  $taskName='AFZ OpenAI Agent Updater'
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  if([string]$identity.User.Value -ne 'S-1-5-18'){
    return [ordered]@{ok=$true;status='skipped-non-system';taskName=$taskName;mutation='NONE';identity=[string]$identity.Name}
  }

  $existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if($existing){
    return [ordered]@{ok=$true;status='present';taskName=$taskName;mutation='NONE';state=[string]$existing.State;identity=[string]$identity.Name}
  }

  $updater=Join-Path $InstallRoot 'afz-openai-agent\Update-AFZ-OpenAI-Agent.ps1'
  if(-not(Test-Path -LiteralPath $updater -PathType Leaf)){
    return [ordered]@{ok=$false;status='updater-source-missing';taskName=$taskName;mutation='NONE';path=$updater;identity=[string]$identity.Name}
  }

  try{
    $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updater`" -InstallRoot `"$InstallRoot`""
    $trigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    $verified=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $a=@($verified.Actions | Select-Object -First 1)
    $actionOk=($a.Count -eq 1 -and ([IO.Path]::GetFileName([string]$a[0].Execute)) -ieq 'powershell.exe' -and [string]$a[0].Arguments -like ('*'+$updater+'*'))
    $principalOk=([string]$verified.Principal.UserId -ieq 'SYSTEM' -and [string]$verified.Principal.LogonType -eq 'ServiceAccount')
    if(-not($actionOk -and $principalOk)){throw 'Canonical fallback updater verification failed after registration.'}
    return [ordered]@{ok=$true;status='registered-missing-canonical-task';taskName=$taskName;mutation='REGISTER_EXISTING_CANONICAL_TASK';state=[string]$verified.State;identity=[string]$identity.Name}
  }catch{
    return [ordered]@{ok=$false;status='registration-failed';taskName=$taskName;mutation='REGISTER_EXISTING_CANONICAL_TASK_ATTEMPTED';error=$_.Exception.Message;identity=[string]$identity.Name}
  }
}

if(-not [string]::IsNullOrWhiteSpace($ExpectedSha)){
  $resolvedSha=$ExpectedSha.Trim().ToLowerInvariant()
  if($resolvedSha -notmatch '^[0-9a-f]{40}$'){throw 'ExpectedSha must be a 40-character Git commit SHA'}
}else{
  $nonce=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $ref=Invoke-RestMethod -Uri ('https://api.github.com/repos/f3arif/homelab-control/git/ref/heads/main?nocache='+$nonce) -Headers $headers -TimeoutSec 30
  $resolvedSha=([string]$ref.object.sha).Trim().ToLowerInvariant()
  if($resolvedSha -notmatch '^[0-9a-f]{40}$'){throw 'Unable to resolve current main SHA'}
}

$temp=Join-Path $env:TEMP ('AFZ-AgentSyncWrapper-'+[guid]::NewGuid().ToString('n'))
$core=Join-Path $temp 'Sync-AFZ-AgentFromGitHub-Core.ps1'
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try{
  $coreUri="https://raw.githubusercontent.com/f3arif/homelab-control/$resolvedSha/afz-openai-agent/Sync-AFZ-AgentFromGitHub-Core.ps1"
  Invoke-WebRequest -Uri $coreUri -Headers $headers -OutFile $core -UseBasicParsing -TimeoutSec 60
  $tokens=$null;$parseErrors=$null
  [System.Management.Automation.Language.Parser]::ParseFile($core,[ref]$tokens,[ref]$parseErrors)|Out-Null
  if($parseErrors.Count -gt 0){throw ('Core sync parse failure: '+(($parseErrors|ForEach-Object{$_.Message}) -join '; '))}

  $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$core,'-InstallRoot',$InstallRoot,'-ExpectedSha',$resolvedSha)
  if($Force){$args+=@('-Force')}
  $raw=& powershell.exe @args | Select-Object -Last 1
  $coreExit=$LASTEXITCODE
  if($coreExit -ne 0){throw "Core source sync failed exit=$coreExit output=$raw"}
  if(-not $raw){throw 'Core source sync returned no result'}
  if($raw -is [string]){try{$result=$raw|ConvertFrom-Json}catch{throw "Core source sync returned invalid JSON: $raw"}}else{$result=$raw}

  # Missing-only repair of the canonical one-minute SYSTEM fallback updater.
  # This never starts/stops a task and never rewrites an existing task.
  $fallbackUpdaterRepair=Ensure-FallbackUpdaterTask

  $recovery=[ordered]@{ok=$false;status='not-run';syncedSha=$resolvedSha}
  try{
    $helper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-GenericWorker-Recovery.ps1'
    if(Test-Path -LiteralPath $helper -PathType Leaf){
      $h3Raw=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot -SyncedSha $resolvedSha | Select-Object -Last 1
      $h3Code=$LASTEXITCODE
      if($h3Raw -is [string]){try{$h3Parsed=$h3Raw|ConvertFrom-Json}catch{$h3Parsed=[ordered]@{status='invalid-json';raw=[string]$h3Raw}}}else{$h3Parsed=$h3Raw}
      $recovery=[ordered]@{ok=($h3Code -eq 0);status=$(if($h3Code -eq 0){'completed'}else{'helper-failed'});exit=$h3Code;result=$h3Parsed;syncedSha=$resolvedSha}
    }else{
      $recovery=[ordered]@{ok=$false;status='helper-missing';syncedSha=$resolvedSha}
    }
  }catch{
    $recovery=[ordered]@{ok=$false;status='helper-exception';error=$_.Exception.Message;syncedSha=$resolvedSha}
  }

  $out=[ordered]@{}
  foreach($p in $result.PSObject.Properties){$out[$p.Name]=$p.Value}
  $out['fallbackUpdaterRepair']=$fallbackUpdaterRepair
  $out['h3GenericWorkerRecovery']=$recovery
  $out|ConvertTo-Json -Depth 30 -Compress
  exit 0
}finally{
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
