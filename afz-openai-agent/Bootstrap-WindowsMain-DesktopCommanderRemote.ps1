#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha required'}
if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid JobId'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()

$expectedComputer='DESKTOP-10SKF0M'
$sourceTask='AFZ Edge Backup'
$taskName='AFZ Desktop Commander Remote Pairing'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\desktop-commander-remote-pairing'
$stateFile=Join-Path $stateRoot 'latest.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Save-State([string]$Status,[string]$Message,$Extra=$null){
  $o=[ordered]@{
    ok=($Status -notin @('failed','error'))
    status=$Status
    message=$Message
    jobId=$JobId
    host=$expectedComputer
    expectedSha=$ExpectedSha
    taskName=$taskName
    command='npx --yes @wonderwhy-er/desktop-commander@latest remote'
    authMaterialCaptured=$false
    persistentStartupInstalled=$false
    updatedAt=(Get-Date -Format o)
  }
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  [IO.File]::WriteAllText($stateFile,($o|ConvertTo-Json -Depth 12 -Compress),$utf8)
}

try{
  if($env:COMPUTERNAME -ne $expectedComputer){throw "windows-main-only pairing launcher; host=$env:COMPUTERNAME"}
  $node=(Get-Command node.exe -ErrorAction Stop).Source
  $npx=(Get-Command npx.cmd -ErrorAction Stop).Source
  $nodeVersion=(& $node -v 2>&1 | Out-String).Trim()
  if($nodeVersion -notmatch '^v(\d+)\.'){throw "Unexpected Node version: $nodeVersion"}
  if([int]$Matches[1] -lt 18){throw "Node 18+ required; found $nodeVersion"}

  $principalSource=Get-ScheduledTask -TaskName $sourceTask -ErrorAction SilentlyContinue
  if(-not $principalSource){throw "Interactive principal source task missing: $sourceTask"}
  $principal=$principalSource.Principal
  if(-not $principal -or [string]::IsNullOrWhiteSpace([string]$principal.UserId)){throw "$sourceTask has no usable principal"}
  if(([string]$principal.LogonType) -notmatch 'Interactive'){throw "$sourceTask principal is not interactive"}

  $existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if($existing -and [string]$existing.State -eq 'Running'){
    Save-State 'awaiting-user-authorization' 'Desktop Commander pairing process is already running in the interactive Windows-main session.' ([pscustomobject]@{node=$node;nodeVersion=$nodeVersion;npx=$npx;taskState='Running'})
    Write-Output 'DESKTOP_COMMANDER_PAIRING=ALREADY_RUNNING'
    exit 0
  }
  if($existing){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue}

  $cmdArgs='/d /s /c ""'+$npx+'" --yes @wonderwhy-er/desktop-commander@latest remote"'
  $action=New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $cmdArgs
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
  Start-Sleep -Seconds 2
  $state=[string](Get-ScheduledTask -TaskName $taskName -ErrorAction Stop).State
  if($state -ne 'Running'){throw "Pairing task did not remain running; state=$state"}

  Save-State 'awaiting-user-authorization' 'Interactive Desktop Commander Remote MCP pairing was launched on Windows-main. Verification URL/code remain only in the local console; no authentication material is written to GitHub or OneDrive.' ([pscustomobject]@{node=$node;nodeVersion=$nodeVersion;npx=$npx;taskState=$state;principalUser=[string]$principal.UserId})
  Write-Output 'DESKTOP_COMMANDER_PAIRING=LAUNCHED'
  exit 0
}catch{
  $msg=$_.Exception.Message
  Save-State 'failed' $msg
  Write-Error $msg
  exit 1
}
