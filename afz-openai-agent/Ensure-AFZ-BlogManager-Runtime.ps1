#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$expectedHost='DESKTOP-10SKF0M'
$taskName='AFZ Blog Manager'
$root='C:\docker\afz-blog-manager'
$startScript=Join-Path $root 'scripts\start-blog-manager-3015.ps1'
$buildId=Join-Path $root '.next\BUILD_ID'
$controlRoot='C:\AFZ\homelab-control'
$dbExternalizeRunner=Join-Path $controlRoot 'afz-openai-agent\Invoke-AFZBlog-DatabaseExternalize.ps1'
$dbExternalizeRequest=Join-Path $controlRoot 'afz-openai-agent\requests\afz-blog-database-externalize.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-blog-runtime-ensure'
$statePath=Join-Path $stateRoot 'latest.json'
$mirror='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results\AFZ-BLOG-RUNTIME-ENSURE-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-Result($Object){
  $json=$Object|ConvertTo-Json -Depth 24
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{[IO.File]::WriteAllText($mirror,$json,$utf8)}catch{}
  Write-Output ($Object|ConvertTo-Json -Depth 24 -Compress)
}
function Invoke-NativeGit([string[]]$ArgumentVector,[switch]$AllowFailure){
  $gitCommand=Get-Command git.exe -ErrorAction Stop | Select-Object -First 1
  $gitPath=$(if($gitCommand.Source){[string]$gitCommand.Source}else{[string]$gitCommand.Path})
  if([string]::IsNullOrWhiteSpace($gitPath)){throw 'Unable to resolve git.exe path'}
  $effectiveArgs=@('-c',('safe.directory='+$root))+$ArgumentVector
  $old=$ErrorActionPreference
  try{$ErrorActionPreference='Continue';$lines=@(& $gitPath @effectiveArgs 2>&1|ForEach-Object{[string]$_});$code=$LASTEXITCODE}
  finally{$ErrorActionPreference=$old}
  if(-not $AllowFailure -and $code -ne 0){throw ('git failed exit='+$code+' command='+($ArgumentVector -join ' ')+' output='+(($lines|Select-Object -Last 3) -join ' | '))}
  [pscustomobject]@{exit=[int]$code;lines=$lines;text=($lines -join "`n")}
}
function Get-ListenerCount{
  try{return @((Get-NetTCPConnection -LocalPort 3015 -State Listen -ErrorAction SilentlyContinue)).Count}catch{return 0}
}
function Get-TaskProof($Task){
  if(-not $Task){return $null}
  $actions=@($Task.Actions)
  $triggers=@($Task.Triggers)
  $triggerTypes=@($triggers|ForEach-Object{[string]$_.CimClass.CimClassName})
  $execute=$(if($actions.Count -eq 1){[string]$actions[0].Execute}else{$null})
  $arguments=$(if($actions.Count -eq 1){[string]$actions[0].Arguments}else{$null})
  $workingDirectory=$(if($actions.Count -eq 1){[string]$actions[0].WorkingDirectory}else{$null})
  $actionOk=($actions.Count -eq 1 -and ([IO.Path]::GetFileName($execute)) -ieq 'powershell.exe' -and $arguments -like ('*'+$startScript+'*') -and $workingDirectory -eq $root)
  $principalUser=[string]$Task.Principal.UserId
  $principalOk=($principalUser -in @('SYSTEM','NT AUTHORITY\SYSTEM') -and [string]$Task.Principal.LogonType -eq 'ServiceAccount' -and [string]$Task.Principal.RunLevel -eq 'Highest')
  $startupTriggerOk=($triggerTypes -contains 'MSFT_TaskBootTrigger')
  $settingsOk=([string]$Task.Settings.MultipleInstances -eq 'IgnoreNew' -and [bool]$Task.Settings.StartWhenAvailable)
  [ordered]@{
    valid=($actionOk -and $principalOk -and $startupTriggerOk -and $settingsOk)
    actionOk=$actionOk
    execute=$execute
    arguments=$arguments
    workingDirectory=$workingDirectory
    principalUser=$principalUser
    logonType=[string]$Task.Principal.LogonType
    runLevel=[string]$Task.Principal.RunLevel
    principalOk=$principalOk
    triggerTypes=$triggerTypes
    startupTriggerOk=$startupTriggerOk
    multipleInstances=[string]$Task.Settings.MultipleInstances
    startWhenAvailable=[bool]$Task.Settings.StartWhenAvailable
    settingsOk=$settingsOk
  }
}

$result=[ordered]@{
  schema=1
  purpose='AFZ_BLOG_RUNTIME_ENSURE'
  ok=$false
  classification='STARTING'
  host=$env:COMPUTERNAME
  taskName=$taskName
  root=$root
  taskCreated=$false
  serviceStarted=$false
  databaseExternalization=$null
  sourceModified=$false
  gitMetadataModified=$false
  websitePublished=$false
  credentialsEmitted=$false
  time=(Get-Date -Format o)
}
try{
  if($env:COMPUTERNAME -ne $expectedHost){throw 'Wrong host'}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  $result.identity=[string]$identity.Name
  if([string]$identity.User.Value -ne 'S-1-5-18'){
    $result.ok=$true;$result.classification='AFZ_BLOG_RUNTIME_ENSURE_SKIPPED_NON_SYSTEM';$result.time=(Get-Date -Format o);Save-Result $result;exit 0
  }
  if(-not(Test-Path -LiteralPath $root -PathType Container)){throw 'Production root missing'}
  if(-not(Test-Path -LiteralPath $startScript -PathType Leaf)){throw 'Canonical Blog start script missing'}
  if(-not(Test-Path -LiteralPath $buildId -PathType Leaf)){throw 'Production .next BUILD_ID missing; refusing runtime start without successful build'}
  if(-not(Get-Command git.exe -ErrorAction SilentlyContinue)){throw 'git.exe missing'}

  $head=(Invoke-NativeGit @('-C',$root,'rev-parse','HEAD')).text.Trim().ToLowerInvariant()
  $branch=(Invoke-NativeGit @('-C',$root,'branch','--show-current')).text.Trim()
  $origin=(Invoke-NativeGit @('-C',$root,'remote','get-url','origin')).text.Trim()
  $dirty=@((Invoke-NativeGit @('-C',$root,'status','--porcelain=v1','-uall')).lines|Where-Object{$_}).Count
  $result.git=[ordered]@{head=$head;branch=$branch;origin=$origin;dirtyCount=$dirty}
  if($branch -ne 'main' -or $origin.TrimEnd('/').ToLowerInvariant() -ne 'https://github.com/f3arif/afz-blog.git' -or $dirty -ne 0){
    $result.classification='AFZ_BLOG_RUNTIME_ENSURE_BLOCKED_GIT_STATE';$result.time=(Get-Date -Format o);Save-Result $result;exit 40
  }

  $beforeListeners=Get-ListenerCount
  $result.before=[ordered]@{port3015Listeners=$beforeListeners;taskExists=$false;taskState=$null;taskProof=$null}
  $existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if($existing){
    $result.before.taskExists=$true;$result.before.taskState=[string]$existing.State
    $beforeProof=Get-TaskProof $existing
    $result.before.taskProof=$beforeProof
    if(-not [bool]$beforeProof.valid){$result.classification='AFZ_BLOG_RUNTIME_ENSURE_BLOCKED_EXISTING_TASK_MISMATCH';$result.time=(Get-Date -Format o);Save-Result $result;exit 41}
  }else{
    $arg="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$startScript`""
    $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory $root
    $trigger=New-ScheduledTaskTrigger -AtStartup
    $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force|Out-Null
    $result.taskCreated=$true
  }

  # AFZ_BLOG_DATABASE_EXTERNALIZE_RUNTIME_HOOK_V1
  # Fixed request + SYSTEM-only helper. Failure is recorded by both helpers and
  # never weakens the independent production deploy DB/schema block.
  if((Test-Path -LiteralPath $dbExternalizeRunner -PathType Leaf) -and (Test-Path -LiteralPath $dbExternalizeRequest -PathType Leaf)){
    try{
      $raw=@(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $dbExternalizeRunner -InstallRoot $controlRoot -RequestPath $dbExternalizeRequest 2>&1|ForEach-Object{[string]$_})
      $code=$LASTEXITCODE
      $parsed=$null
      foreach($line in @($raw|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})){try{$parsed=$line|ConvertFrom-Json}catch{}}
      $result.databaseExternalization=[ordered]@{ok=($code -eq 0 -and $null -ne $parsed -and [bool]$parsed.ok);exit=$code;classification=$(if($parsed){[string]$parsed.classification}else{'NO_JSON'});result=$parsed}
    }catch{
      $result.databaseExternalization=[ordered]@{ok=$false;classification='HOOK_EXCEPTION';error=$_.Exception.Message}
    }
  }

  if($beforeListeners -eq 0 -and $result.taskCreated){
    Start-ScheduledTask -TaskName $taskName
    $result.serviceStarted=$true
  }

  $httpStatus=$null;$httpError=$null;$listenerPid=$null
  for($i=0;$i -lt 30;$i++){
    $con=@(Get-NetTCPConnection -LocalPort 3015 -State Listen -ErrorAction SilentlyContinue|Select-Object -First 1)
    if($con.Count -gt 0){
      $listenerPid=[int]$con[0].OwningProcess
      try{$w=Invoke-WebRequest -Uri 'http://127.0.0.1:3015/' -UseBasicParsing -TimeoutSec 5;$httpStatus=[int]$w.StatusCode;if($httpStatus -ge 200 -and $httpStatus -lt 500){break}}catch{$httpError=$_.Exception.Message}
    }
    Start-Sleep -Seconds 2
  }
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  $taskInfo=$(if($task){Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue}else{$null})
  $taskProof=Get-TaskProof $task
  $result.after=[ordered]@{port3015Listeners=(Get-ListenerCount);listenerPid=$listenerPid;httpStatus=$httpStatus;httpError=$httpError;taskExists=[bool]$task;taskState=$(if($task){[string]$task.State}else{$null});lastTaskResult=$(if($taskInfo){[int64]$taskInfo.LastTaskResult}else{$null});taskProof=$taskProof}
  if($taskProof -and [bool]$taskProof.valid -and $result.after.port3015Listeners -gt 0 -and $null -ne $httpStatus -and $httpStatus -ge 200 -and $httpStatus -lt 500){$result.ok=$true;$result.classification='AFZ_BLOG_RUNTIME_PERSISTENCE_VERIFIED'}
  elseif($task -and -not [bool]$taskProof.valid){$result.ok=$false;$result.classification='AFZ_BLOG_RUNTIME_TASK_PERSISTENCE_MISMATCH'}
  elseif($existing -and $beforeListeners -eq 0){$result.ok=$false;$result.classification='AFZ_BLOG_RUNTIME_TASK_PRESENT_BUT_NOT_RUNNING'}
  else{$result.ok=$false;$result.classification='AFZ_BLOG_RUNTIME_ENSURE_FAILED_HEALTH'}
}catch{
  $result.ok=$false
  if($result.classification -eq 'STARTING'){$result.classification='AFZ_BLOG_RUNTIME_ENSURE_EXCEPTION'}
  $result.error=$_.Exception.Message
}
$result.time=(Get-Date -Format o)
Save-Result $result
if(-not $result.ok){exit 20}
