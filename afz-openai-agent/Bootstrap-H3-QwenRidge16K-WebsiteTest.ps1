#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId
)

$ErrorActionPreference='Stop'
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha required'}
if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid JobId'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()

$carrierTaskName='AFZ Edge Backup'
$helper='C:\AFZ\homelab-control\afz-openai-agent\tools\Run-WindowsMain-H3-QwenRidge16K-Carrier.ps1'
$helperResult='C:\Users\Faiz\AppData\Local\AFZ\H3QwenRidge16KCarrier\'+$JobId+'.json'
$siteStateFile='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-site-deploy\request-watcher.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwenridge16k-bootstrap'
$stateFile=Join-Path $stateRoot 'latest.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path)){return $null};try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return $null}}
function Save-State([string]$Status,[string]$Message,$Extra=$null){
  $o=[ordered]@{
    ok=($Status -eq 'completed')
    status=$Status
    message=$Message
    jobId=$JobId
    target='DESKTOP-H3R6CQN'
    transport='github-exact-sha+AFZ Edge Backup interactive carrier+strict-ssh+detached-H3'
    expectedSha=$ExpectedSha
    carrierTask=$carrierTaskName
    updatedAt=(Get-Date -Format o)
  }
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  [IO.File]::WriteAllText($stateFile,($o|ConvertTo-Json -Depth 12 -Compress),$utf8)
}
function Task-IsEnabled($task){return ($task -and [string]$task.State -ne 'Disabled')}
function New-RestoredAction($original){
  $p=@{Execute=[string]$original.Execute}
  if(-not [string]::IsNullOrWhiteSpace([string]$original.Arguments)){$p.Argument=[string]$original.Arguments}
  if(-not [string]::IsNullOrWhiteSpace([string]$original.WorkingDirectory)){$p.WorkingDirectory=[string]$original.WorkingDirectory}
  return New-ScheduledTaskAction @p
}

$carrier=$null;$original=$null;$carrierWasEnabled=$false;$swapped=$false
try{
  if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only bootstrap; host=$env:COMPUTERNAME"}
  if(-not(Test-Path -LiteralPath $helper -PathType Leaf)){throw "Interactive carrier helper missing: $helper"}

  # Do not compete with the Git-to-Pi deployment lane for the same proven interactive carrier.
  $site=Read-Json $siteStateFile
  if($site -and [string]$site.status -in @('arming','deploying')){throw 'AFZ Edge Backup carrier is reserved by active AFZ site deployment; Ridge16K transport retry deferred.'}

  $deadline=(Get-Date).AddMinutes(3)
  do{
    $carrier=Get-ScheduledTask -TaskName $carrierTaskName -ErrorAction SilentlyContinue
    if(-not $carrier){throw "Credential carrier task not found: $carrierTaskName"}
    if($carrier.State -ne 'Running'){break}
    Start-Sleep -Seconds 3
  }while((Get-Date) -lt $deadline)
  if($carrier.State -eq 'Running'){throw 'AFZ Edge Backup carrier remained busy for more than 3 minutes.'}

  $original=$carrier.Actions|Select-Object -First 1
  if(-not $original -or [string]::IsNullOrWhiteSpace([string]$original.Execute)){throw 'AFZ Edge Backup carrier has no restorable action.'}
  $carrierWasEnabled=Task-IsEnabled $carrier
  Remove-Item -LiteralPath $helperResult -Force -ErrorAction SilentlyContinue

  Save-State 'running' 'Borrowing proven AFZ Edge Backup Interactive-logon identity for bounded H3 Ridge16K launch.'
  $argLine="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$helper`" -ExpectedSha `"$ExpectedSha`" -JobId `"$JobId`""
  $newAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
  Set-ScheduledTask -TaskName $carrierTaskName -Action $newAction|Out-Null
  Enable-ScheduledTask -TaskName $carrierTaskName|Out-Null
  $swapped=$true
  Start-ScheduledTask -TaskName $carrierTaskName

  $deadline=(Get-Date).AddMinutes(4)
  do{
    Start-Sleep -Seconds 2
    $r=Read-Json $helperResult
    if($r -and [string]$r.jobId -eq $JobId -and [string]$r.expectedSha -eq $ExpectedSha -and [string]$r.status -in @('completed','failed')){break}
    $current=Get-ScheduledTask -TaskName $carrierTaskName -ErrorAction SilentlyContinue
    if($current -and $current.State -ne 'Running' -and $r){break}
  }while((Get-Date) -lt $deadline)

  $r=Read-Json $helperResult
  if(-not $r){throw "Interactive carrier ended without result: $helperResult"}
  if([string]$r.jobId -ne $JobId -or [string]$r.expectedSha -ne $ExpectedSha){throw 'Interactive carrier result does not match this exact job/SHA.'}
  if(-not [bool]$r.ok -or [string]$r.status -ne 'completed'){throw ('Interactive carrier failed: '+[string]$r.message)}

  Save-State 'completed' 'H3 Ridge16K detached runner launch proved through restored Interactive-logon credential carrier.' $r
  Write-Output ('AFZ_QWENRIDGE16K_BOOTSTRAP_JSON='+((Get-Content $stateFile -Raw|ConvertFrom-Json)|ConvertTo-Json -Depth 12 -Compress))
}catch{
  $msg=$_.Exception.Message
  Save-State 'failed' $msg
  Write-Error $msg
  exit 1
}finally{
  if($swapped -and $original){
    try{
      $restore=New-RestoredAction $original
      Set-ScheduledTask -TaskName $carrierTaskName -Action $restore|Out-Null
      if($carrierWasEnabled){Enable-ScheduledTask -TaskName $carrierTaskName|Out-Null}else{Disable-ScheduledTask -TaskName $carrierTaskName|Out-Null}
    }catch{}
  }
}
