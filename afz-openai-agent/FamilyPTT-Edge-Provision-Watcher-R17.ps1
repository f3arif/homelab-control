#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalSeconds=5
)
$ErrorActionPreference='Stop'
$IntervalSeconds=[math]::Max(3,[math]::Min($IntervalSeconds,30))
$requestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\familyptt-edge-provision-r17.json'
$executor=Join-Path $InstallRoot 'afz-openai-agent\FamilyPTT-Edge-Provision-R17.ps1'
$preflightFile='C:\Users\Faiz\AppData\Local\AFZ\FamilyPTTEdgePreflight\latest.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\familyptt-edge-provision-r17'
$stateFile=Join-Path $stateRoot 'latest.json'
$logFile=Join-Path $stateRoot 'watcher.log'
$resultFile='C:\Users\Faiz\AppData\Local\AFZ\FamilyPTTEdgeProvision\latest.json'
$carrierTaskName='AFZ Edge Backup'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Log([string]$m){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $m" -Encoding UTF8}
function Read-Json([string]$p){if(-not(Test-Path -LiteralPath $p)){return $null};try{return Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}}
function Save-State($o){$o|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $stateFile -Encoding UTF8}
function Valid-Request($r){return ($r -and [int]$r.schema -eq 1 -and [string]$r.project -eq 'familyptt' -and [string]$r.action -eq 'edge-provision' -and [int]$r.issue -eq 17 -and ([string]$r.job_id) -match '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$' -and ([string]$r.preflight_job_id) -match '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$')}
function Task-IsEnabled($t){return ($t -and [string]$t.State -ne 'Disabled')}
function New-RestoreAction($s){$p=@{Execute=[string]$s.originalExecute};if($s.originalArguments){$p.Argument=[string]$s.originalArguments};if($s.originalWorkingDirectory){$p.WorkingDirectory=[string]$s.originalWorkingDirectory};New-ScheduledTaskAction @p}
function Restore-Carrier($s){if(-not $s -or -not $s.originalExecute){throw 'Carrier restore metadata missing'};$a=New-RestoreAction $s;Set-ScheduledTask -TaskName $carrierTaskName -Action $a|Out-Null;if([bool]$s.carrierWasEnabled){Enable-ScheduledTask -TaskName $carrierTaskName|Out-Null}else{Disable-ScheduledTask -TaskName $carrierTaskName|Out-Null}}
function Publish-Issue($r){
  $gh=Get-Command gh.exe -ErrorAction SilentlyContinue;if(-not $gh){return $false}
  $body=@"
### FamilyPTT production edge provisioning R17

Job: ``$($r.jobId)``
Preflight: ``$($r.preflightJobId)``
Classification: ``$($r.classification)``
Success: $($r.ok)
Public API HTTPS health: $($r.public.apiHealth200)
Public token issued: $($r.public.tokenIssued)
Token server URL: $($r.public.serverUrl)
Public LiveKit TLS valid: $($r.public.liveKitTlsValid)
Token service running: $($r.hp.tokenServiceRunning)

No JWT, participant token, API key, private key, or credential value is included in this result. DNS and firewall configuration were not changed by R17.
"@
  $tmp=Join-Path $env:TEMP ('familyptt-r17-'+[guid]::NewGuid().ToString('n')+'.json')
  try{[ordered]@{body=$body}|ConvertTo-Json -Depth 3|Set-Content -LiteralPath $tmp -Encoding UTF8;& $gh.Source api --method POST 'repos/f3arif/homelab-control/issues/17/comments' --input $tmp *> $null;return ($LASTEXITCODE -eq 0)}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
}

function Handle-Request{
  $req=Read-Json $requestFile;if(-not(Valid-Request $req)){return}
  $job=[string]$req.job_id;$preflightJob=[string]$req.preflight_job_id
  $state=Read-Json $stateFile
  if($state -and [string]$state.jobId -eq $job -and [string]$state.status -eq 'completed'){return}
  $pre=Read-Json $preflightFile
  if(-not $pre -or [string]$pre.jobId -ne $preflightJob -or -not [bool]$pre.ok -or [string]$pre.classification -ne 'EDGE_PREFLIGHT_READY_FOR_NARROW_PROVISIONING'){
    return
  }
  if($state -and [string]$state.jobId -eq $job -and [string]$state.status -eq 'running'){
    $carrier=Get-ScheduledTask -TaskName $carrierTaskName -ErrorAction SilentlyContinue
    if($carrier -and $carrier.State -eq 'Running'){return}
    $result=Read-Json $resultFile
    try{Restore-Carrier $state}catch{Save-State ([ordered]@{jobId=$job;status='failed';message=('Carrier restore failed: '+$_.Exception.Message);updatedAt=(Get-Date -Format o)});return}
    if($result -and [string]$result.jobId -eq $job){
      $published=Publish-Issue $result
      Save-State ([ordered]@{jobId=$job;status='completed';classification=[string]$result.classification;ok=[bool]$result.ok;published=$published;updatedAt=(Get-Date -Format o)})
      Log "DONE job=$job class=$($result.classification)"
    }else{Save-State ([ordered]@{jobId=$job;status='failed';message='Carrier ended without matching provision result';updatedAt=(Get-Date -Format o)})}
    return
  }
  if(-not(Test-Path -LiteralPath $executor -PathType Leaf)){throw 'R17 executor missing'}
  $carrier=Get-ScheduledTask -TaskName $carrierTaskName -ErrorAction SilentlyContinue;if(-not $carrier){throw 'AFZ Edge Backup carrier missing'}
  if($carrier.State -eq 'Running'){return}
  $orig=$carrier.Actions|Select-Object -First 1;if(-not $orig -or -not $orig.Execute){throw 'Carrier has no restorable action'}
  Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
  $snapshot=[ordered]@{jobId=$job;preflightJobId=$preflightJob;status='arming';carrierWasEnabled=(Task-IsEnabled $carrier);originalExecute=[string]$orig.Execute;originalArguments=[string]$orig.Arguments;originalWorkingDirectory=[string]$orig.WorkingDirectory;updatedAt=(Get-Date -Format o)};Save-State $snapshot
  $args="-NoProfile -ExecutionPolicy Bypass -File `"$executor`" -JobId `"$job`" -PreflightJobId `"$preflightJob`" -ResultFile `"$resultFile`""
  $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args
  Set-ScheduledTask -TaskName $carrierTaskName -Action $action|Out-Null;Enable-ScheduledTask -TaskName $carrierTaskName|Out-Null;Start-ScheduledTask -TaskName $carrierTaskName
  $snapshot.status='running';$snapshot.updatedAt=(Get-Date -Format o);Save-State $snapshot;Log "START job=$job preflight=$preflightJob"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZFamilyPTTEdgeProvisionR17')
$locked=$false
try{$locked=$mutex.WaitOne(0);if(-not $locked){exit 0};Log 'WATCHER_START';while($true){try{Handle-Request}catch{Log ('ERROR '+$_.Exception.Message)};Start-Sleep -Seconds $IntervalSeconds}}finally{if($locked){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
