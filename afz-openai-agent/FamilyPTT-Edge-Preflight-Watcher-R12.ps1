#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalSeconds=5
)
$ErrorActionPreference='Stop'
$IntervalSeconds=[math]::Max(3,[math]::Min($IntervalSeconds,30))
$requestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\familyptt-edge-preflight-r12.json'
$executor=Join-Path $InstallRoot 'afz-openai-agent\FamilyPTT-Edge-Preflight-R12.ps1'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\familyptt-edge-preflight-r12'
$stateFile=Join-Path $stateRoot 'latest.json'
$logFile=Join-Path $stateRoot 'watcher.log'
$resultFile='C:\Users\Faiz\AppData\Local\AFZ\FamilyPTTEdgePreflight\latest.json'
$carrierTaskName='AFZ Edge Backup'
$staleCarrierSeconds=180
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Log([string]$m){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $m" -Encoding UTF8}
function Read-Json([string]$p){if(-not(Test-Path -LiteralPath $p)){return $null};try{return Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}}
function Save-State($o){$o|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $stateFile -Encoding UTF8}
function Valid-Request($r){return ($r -and [int]$r.schema -eq 1 -and [string]$r.project -eq 'familyptt' -and [string]$r.action -eq 'edge-preflight' -and [int]$r.issue -eq 17 -and ([string]$r.job_id) -match '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$')}
function Task-IsEnabled($t){return ($t -and [string]$t.State -ne 'Disabled')}
function New-RestoreAction($s){$p=@{Execute=[string]$s.originalExecute};if($s.originalArguments){$p.Argument=[string]$s.originalArguments};if($s.originalWorkingDirectory){$p.WorkingDirectory=[string]$s.originalWorkingDirectory};New-ScheduledTaskAction @p}
function Restore-Carrier($s){if(-not $s -or -not $s.originalExecute){throw 'Carrier restore metadata missing'};$a=New-RestoreAction $s;Set-ScheduledTask -TaskName $carrierTaskName -Action $a|Out-Null;if([bool]$s.carrierWasEnabled){Enable-ScheduledTask -TaskName $carrierTaskName|Out-Null}else{Disable-ScheduledTask -TaskName $carrierTaskName|Out-Null}}
function State-AgeSeconds($s){
  if(-not $s -or -not $s.updatedAt){return [double]::PositiveInfinity}
  try{return [math]::Max(0,((Get-Date)-([datetimeoffset]::Parse([string]$s.updatedAt)).LocalDateTime).TotalSeconds)}catch{return [double]::PositiveInfinity}
}
function Carrier-IsR12ForJob($carrier,[string]$job){
  if(-not $carrier){return $false}
  $a=$carrier.Actions|Select-Object -First 1
  if(-not $a){return $false}
  $args=[string]$a.Arguments
  return ($args -and $args.IndexOf($executor,[StringComparison]::OrdinalIgnoreCase) -ge 0 -and $args.IndexOf($job,[StringComparison]::OrdinalIgnoreCase) -ge 0)
}
function Recover-SupersededCarrier($state,[string]$newJob){
  if(-not $state -or [string]$state.jobId -eq $newJob -or [string]$state.status -notin @('arming','running')){return $true}
  $oldJob=[string]$state.jobId
  $age=State-AgeSeconds $state
  if($age -lt $staleCarrierSeconds){Log "DEFER new=$newJob prior=$oldJob age=$([int]$age)s";return $false}
  $carrier=Get-ScheduledTask -TaskName $carrierTaskName -ErrorAction SilentlyContinue
  if(-not $carrier){throw 'AFZ Edge Backup carrier missing during stale recovery'}
  if(-not(Carrier-IsR12ForJob $carrier $oldJob)){
    Log "REFUSE_STALE_RECOVERY prior=$oldJob reason=carrier-action-mismatch"
    return $false
  }
  if($carrier.State -eq 'Running'){
    Log "STOP_STALE prior=$oldJob age=$([int]$age)s"
    Stop-ScheduledTask -TaskName $carrierTaskName -ErrorAction Stop
    for($i=0;$i -lt 20;$i++){
      Start-Sleep -Milliseconds 500
      $carrier=Get-ScheduledTask -TaskName $carrierTaskName -ErrorAction SilentlyContinue
      if($carrier -and $carrier.State -ne 'Running'){break}
    }
    if($carrier -and $carrier.State -eq 'Running'){
      Log "REFUSE_STALE_RECOVERY prior=$oldJob reason=carrier-did-not-stop"
      return $false
    }
  }
  Restore-Carrier $state
  Save-State ([ordered]@{jobId=$oldJob;status='failed';message=('Superseded stale R12 carrier recovered before '+$newJob);supersededBy=$newJob;updatedAt=(Get-Date -Format o)})
  Log "RECOVERED_STALE prior=$oldJob next=$newJob"
  return $true
}
function Publish-Issue($r){
  $gh=Get-Command gh.exe -ErrorAction SilentlyContinue;if(-not $gh){return $false}
  $pi=$r.pi;$hp=$r.hp
  $body=@"
### FamilyPTT edge preflight R12

Read-only preflight completed through the established Windows-main -> AFZ Edge Backup -> Pi/HP path.

Job: ``$($r.jobId)``
Pi -> token/API reachable: $($pi.reachesApi)
Pi -> LiveKit 7880 reachable: $($pi.reachesLiveKit)
NPM container: $($pi.npmContainer)
NPM ports: $($pi.npmPorts)
NPM custom http include available: $($pi.customHttpIncluded)
NPM custom http file already exists: $($pi.customHttpExists)
Certbot available: $($pi.certbotAvailable)
Existing Certbot account present: $($pi.certbotAccountPresent)
ACME webroot present: $($pi.acmeWebrootPresent)
LiveKit running: $($hp.liveKitRunning)
Token service running: $($hp.tokenRunning)
LiveKit network mode: $($hp.liveKitNetworkMode)
LiveKit published ports: $($hp.liveKitPortBindings)
Sanitized RTC settings: $($hp.rtcSettings)
Token LIVEKIT_URL scheme: $($hp.tokenUrlScheme)

Classification: ``$($r.classification)``

No secret values were read or logged. No DNS, proxy, certificate, backend, service, firewall, or application mutation occurred.
"@
  $tmp=Join-Path $env:TEMP ('familyptt-r12-'+[guid]::NewGuid().ToString('n')+'.json')
  try{[ordered]@{body=$body}|ConvertTo-Json -Depth 3|Set-Content -LiteralPath $tmp -Encoding UTF8;& $gh.Source api --method POST 'repos/f3arif/homelab-control/issues/17/comments' --input $tmp *> $null;return ($LASTEXITCODE -eq 0)}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
}

function Handle-Request{
  $req=Read-Json $requestFile;if(-not(Valid-Request $req)){return}
  $job=[string]$req.job_id;$state=Read-Json $stateFile
  if($state -and [string]$state.jobId -eq $job -and [string]$state.status -eq 'completed'){return}
  if($state -and [string]$state.jobId -ne $job){if(-not(Recover-SupersededCarrier $state $job)){return};$state=Read-Json $stateFile}
  if($state -and [string]$state.jobId -eq $job -and [string]$state.status -eq 'running'){
    $carrier=Get-ScheduledTask -TaskName $carrierTaskName -ErrorAction SilentlyContinue
    if($carrier -and $carrier.State -eq 'Running'){return}
    $result=Read-Json $resultFile
    try{Restore-Carrier $state}catch{Save-State ([ordered]@{jobId=$job;status='failed';message=('Carrier restore failed: '+$_.Exception.Message);updatedAt=(Get-Date -Format o)});return}
    if($result -and [string]$result.jobId -eq $job){$published=Publish-Issue $result;Save-State ([ordered]@{jobId=$job;status='completed';classification=[string]$result.classification;ok=[bool]$result.ok;published=$published;updatedAt=(Get-Date -Format o)});Log "DONE job=$job class=$($result.classification)"}else{Save-State ([ordered]@{jobId=$job;status='failed';message='Carrier ended without matching result';updatedAt=(Get-Date -Format o)})}
    return
  }
  if(-not(Test-Path -LiteralPath $executor -PathType Leaf)){throw 'R12 executor missing'}
  $carrier=Get-ScheduledTask -TaskName $carrierTaskName -ErrorAction SilentlyContinue;if(-not $carrier){throw 'AFZ Edge Backup carrier missing'}
  if($carrier.State -eq 'Running'){return}
  $orig=$carrier.Actions|Select-Object -First 1;if(-not $orig -or -not $orig.Execute){throw 'Carrier has no restorable action'}
  Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
  $snapshot=[ordered]@{jobId=$job;status='arming';carrierWasEnabled=(Task-IsEnabled $carrier);originalExecute=[string]$orig.Execute;originalArguments=[string]$orig.Arguments;originalWorkingDirectory=[string]$orig.WorkingDirectory;updatedAt=(Get-Date -Format o)};Save-State $snapshot
  $args="-NoProfile -ExecutionPolicy Bypass -File `"$executor`" -JobId `"$job`" -ResultFile `"$resultFile`""
  $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args
  Set-ScheduledTask -TaskName $carrierTaskName -Action $action|Out-Null;Enable-ScheduledTask -TaskName $carrierTaskName|Out-Null;Start-ScheduledTask -TaskName $carrierTaskName
  $snapshot.status='running';$snapshot.updatedAt=(Get-Date -Format o);Save-State $snapshot;Log "START job=$job"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZFamilyPTTEdgePreflightR12')
$locked=$false
try{$locked=$mutex.WaitOne(0);if(-not $locked){exit 0};Log 'WATCHER_START';while($true){try{Handle-Request}catch{Log ('ERROR '+$_.Exception.Message)};Start-Sleep -Seconds $IntervalSeconds}}finally{if($locked){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
