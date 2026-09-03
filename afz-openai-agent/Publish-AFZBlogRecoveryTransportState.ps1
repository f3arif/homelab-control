#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$SyncedSha=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$jobId='afz-blog-qwen35b-vs-ridge27b-20260902-r1'
$marker='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-afz-blog-model-comparison-recovery-request\'+$jobId+'-activation-v2.json'
$carrierResult='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-afz-blog-model-comparison-recovery\'+$jobId+'.json'
$taskName='AFZ H3 AFZ Blog Recovery Transport'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-BLOG-COMPARISON-RECOVERY-TRANSPORT-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)

function Read-SafeJson([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return [pscustomobject]@{readError=$_.Exception.Message}}
}

$markerValue=Read-SafeJson $marker
$carrierValue=Read-SafeJson $carrierResult
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$taskInfo=$(if($task){Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue}else{$null})

$out=[ordered]@{
  schema=1
  purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY'
  readOnly=$true
  source='windows-main'
  controlPlane='github'
  jobId=$jobId
  syncedSha=$(if($SyncedSha){$SyncedSha}else{$null})
  activationMarker='activation-v2'
  activationMarkerExists=(Test-Path -LiteralPath $marker -PathType Leaf)
  activation=$markerValue
  carrierResultExists=(Test-Path -LiteralPath $carrierResult -PathType Leaf)
  carrierResult=$carrierValue
  transportTaskExists=($null -ne $task)
  transportTaskState=$(if($task){[string]$task.State}else{'missing'})
  transportTaskLastRunTime=$(if($taskInfo -and $taskInfo.LastRunTime -gt [datetime]'2000-01-01'){$taskInfo.LastRunTime.ToString('o')}else{$null})
  transportTaskLastTaskResult=$(if($taskInfo){[int]$taskInfo.LastTaskResult}else{$null})
  modelReplay35B=$false
  ridgeCallAuthorizedByMirror=$false
  modelActionPerformedByMirror=$false
  observedAt=(Get-Date -Format o)
}
$json=$out|ConvertTo-Json -Depth 20
if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$json,$utf8)}
Write-Output ($out|ConvertTo-Json -Depth 20 -Compress)
