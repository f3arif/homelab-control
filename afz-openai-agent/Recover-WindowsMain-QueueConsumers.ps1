#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){
  throw "Windows-main only recovery; host=$env:COMPUTERNAME"
}
if([string]::IsNullOrWhiteSpace($RequestPath)){
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\windowsmain-queue-consumer-recovery.json'
}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){return}

$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
if([int]$req.schema -ne 1 -or [string]$req.status -ne 'ACTIVE' -or [string]$req.action -ne 'start-existing-queue-consumers'){return}
$id=([string]$req.id).Trim()
if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid request id'}

$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\windowsmain-queue-consumer-recovery'
$stateFile=Join-Path $stateRoot ($id+'.json')
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

if(Test-Path -LiteralPath $stateFile -PathType Leaf){
  try{
    $prior=Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$prior.status -eq 'completed'){return}
  }catch{}
}

$queueRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Queue\windows-main'
if(-not(Test-Path -LiteralPath $queueRoot -PathType Container)){
  throw "OneDrive queue root not present locally: $queueRoot"
}

$taskNames=@(
  'AFZ WindowsMain Worker',
  'AFZ Queue AutoRunner',
  'AFZ Queue Safety Watchdog',
  'AFZ OpenAI Agent Push Deploy Watcher'
)

$results=@()
foreach($name in $taskNames){
  $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if(-not $task){
    $results+=[pscustomobject]@{task=$name;exists=$false;before='missing';action='none';after='missing';error=$null}
    continue
  }
  $before=[string]$task.State
  $action='none'
  $err=$null
  if($before -ne 'Running'){
    try{
      Start-ScheduledTask -TaskName $name -ErrorAction Stop
      $action='start'
      Start-Sleep -Milliseconds 500
    }catch{
      $err=$_.Exception.Message
      $action='start-failed'
    }
  }
  $afterTask=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  $after=if($afterTask){[string]$afterTask.State}else{'missing'}
  $results+=[pscustomobject]@{task=$name;exists=$true;before=$before;action=$action;after=$after;error=$err}
}

$critical=@($results|Where-Object{$_.task -in @('AFZ WindowsMain Worker','AFZ Queue AutoRunner')})
$ok=(@($critical|Where-Object{$_.after -eq 'Running'}).Count -ge 1)

$state=[ordered]@{
  schema=1
  requestId=$id
  host=$env:COMPUTERNAME
  status=$(if($ok){'completed'}else{'degraded'})
  queueRoot=$queueRoot
  mutation='START_EXISTING_TASKS_ONLY'
  tasks=$results
  desktopCommanderMutation='NONE'
  schedulerCreation='NONE'
  completedAt=(Get-Date -Format o)
}
[IO.File]::WriteAllText($stateFile,($state|ConvertTo-Json -Depth 10),$utf8)
Write-Output ('AFZ_QUEUE_CONSUMER_RECOVERY='+($state|ConvertTo-Json -Depth 10 -Compress))
if(-not $ok){exit 2}
