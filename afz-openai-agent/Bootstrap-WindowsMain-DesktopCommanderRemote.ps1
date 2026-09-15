#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId,
  [switch]$ForceReauth
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
$logDir='C:\Users\Faiz\AppData\Local\AFZ\DesktopCommander'
$logFile=Join-Path $logDir 'remote-alt-account.log'
$credentialFile=Join-Path $env:USERPROFILE '.desktop-commander-device\device.json'
$privateRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Control Hub\Commander'
$privateResult=Join-Path $privateRoot 'PAIRING-WINDOWSMAIN-LATEST.json'
$verifyUrl='https://mcp.desktopcommander.app/device/verify'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot,$logDir | Out-Null

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
    forceReauth=[bool]$ForceReauth
    authMaterialEmittedToGitHub=$false
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
  if($ForceReauth){
    if($existing -and [string]$existing.State -eq 'Running'){
      Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    }
    $remoteProcs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      ([string]$_.CommandLine) -match '(?i)@wonderwhy-er/desktop-commander.*remote|desktop-commander.*remote'
    })
    foreach($p in $remoteProcs){try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue}catch{}}
    Start-Sleep -Seconds 2

    $logoutText=(& $npx --yes @wonderwhy-er/desktop-commander@latest remote --logout 2>&1 | Out-String).Trim()
    $logoutExit=$LASTEXITCODE
    if($logoutExit -ne 0){throw "Desktop Commander official logout failed exit=$logoutExit"}
    if(Test-Path -LiteralPath $credentialFile -PathType Leaf){throw 'Desktop Commander local credential file remained after official logout'}
    Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
  }elseif($existing -and [string]$existing.State -eq 'Running'){
    Save-State 'awaiting-user-authorization' 'Desktop Commander pairing process is already running in the interactive Windows-main session.' ([pscustomobject]@{node=$node;nodeVersion=$nodeVersion;npx=$npx;taskState='Running'})
    Write-Output 'DESKTOP_COMMANDER_PAIRING=ALREADY_RUNNING'
    exit 0
  }

  if($existing){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue}

  $cmdArgs='/d /s /c ""'+$npx+'" --yes @wonderwhy-er/desktop-commander@latest remote >> "'+$logFile+'" 2>&1"'
  $action=New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $cmdArgs
  $trigger=New-ScheduledTaskTrigger -AtLogOn -User ([string]$principal.UserId)
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

  $deadline=(Get-Date).AddSeconds($(if($ForceReauth){90}else{12}))
  $code=$null
  do{
    Start-Sleep -Seconds 2
    if(Test-Path -LiteralPath $logFile -PathType Leaf){
      $txt=Get-Content -LiteralPath $logFile -Raw -ErrorAction SilentlyContinue
      if($txt){
        $m=[regex]::Match($txt,'(?im)^\s*([A-Z0-9]{4}-[A-Z0-9]{4})\s*$')
        if($m.Success){$code=$m.Groups[1].Value;break}
      }
    }
  }while((Get-Date) -lt $deadline)

  $state=[string](Get-ScheduledTask -TaskName $taskName -ErrorAction Stop).State
  if($state -ne 'Running'){throw "Pairing task did not remain running; state=$state"}

  if($ForceReauth){
    if(-not $code){throw 'Fresh Desktop Commander device code was not observed in the bounded local log window'}
    New-Item -ItemType Directory -Force -Path $privateRoot | Out-Null
    $private=[ordered]@{
      schema=1
      host=$expectedComputer
      status='AUTHORIZATION_REQUIRED'
      verifyUrl=$verifyUrl
      deviceCode=$code
      codeExpiresMinutes=15
      oldLocalCredentialsRemoved=(-not(Test-Path -LiteralPath $credentialFile -PathType Leaf))
      taskName=$taskName
      taskState=$state
      generatedAt=(Get-Date -Format o)
      note='Sign into the target Commander account and approve this exact device code.'
    }
    [IO.File]::WriteAllText($privateResult,($private|ConvertTo-Json -Depth 8),$utf8)
    Save-State 'awaiting-user-authorization' 'Fresh Desktop Commander pairing code created after official local logout. Code is stored only in the private OneDrive Control Hub result.' ([pscustomobject]@{
      node=$node
      nodeVersion=$nodeVersion
      npx=$npx
      taskState=$state
      principalUser=[string]$principal.UserId
      oldLocalCredentialsRemoved=$true
      privatePairingResult=$privateResult
      deviceCodeWrittenPrivate=$true
      persistentStartupInstalled=$true
    })
    Write-Output 'DESKTOP_COMMANDER_FORCE_REAUTH=READY'
    Write-Output ('PRIVATE_PAIRING_RESULT='+$privateResult)
    exit 0
  }

  Save-State 'awaiting-user-authorization' 'Interactive Desktop Commander Remote MCP pairing was launched on Windows-main. Verification URL/code remain only in the local log; no authentication material is written to GitHub.' ([pscustomobject]@{
    node=$node
    nodeVersion=$nodeVersion
    npx=$npx
    taskState=$state
    principalUser=[string]$principal.UserId
    persistentStartupInstalled=$true
  })
  Write-Output 'DESKTOP_COMMANDER_PAIRING=LAUNCHED'
  exit 0
}catch{
  $msg=$_.Exception.Message
  Save-State 'failed' $msg
  Write-Error $msg
  exit 1
}
