#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\prospect-astra-review-all'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-PROSPECT-ASTRA-REVIEW-LATEST.json'
$sharedMirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$sharedMirrorPath=Join-Path $sharedMirrorRoot 'AFZ-PROSPECT-ASTRA-REVIEW-LATEST.json'
$endpoint='http://127.0.0.1:8796'
$prospectAuditPath='C:\\ProgramData\\AFZ\\OpenAIAgent\\ProspectEngine\\audit.ndjson'
if([string]::IsNullOrWhiteSpace($RequestPath)){
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\prospect-astra-review-all.json'
}

function Write-AstraState($State,[string]$StatePath){
  $json=$State|ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($StatePath,$json,(New-Object Text.UTF8Encoding($false)))
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,(New-Object Text.UTF8Encoding($false)))}}catch{}
  try{if(Test-Path -LiteralPath $sharedMirrorRoot -PathType Container){[IO.File]::WriteAllText($sharedMirrorPath,$json,(New-Object Text.UTF8Encoding($false)))}}catch{}
}

function Get-HttpErrorBody($ErrorRecord){
  try{
    $message=[string]$ErrorRecord.ErrorDetails.Message
    if(-not [string]::IsNullOrWhiteSpace($message)){return $message|ConvertFrom-Json}
  }catch{}
  try{
    $response=$ErrorRecord.Exception.Response
    if($response){
      $stream=$response.GetResponseStream()
      if($stream){
        $reader=New-Object IO.StreamReader($stream)
        try{$message=$reader.ReadToEnd()}finally{$reader.Dispose();$stream.Dispose()}
        if(-not [string]::IsNullOrWhiteSpace($message)){return $message|ConvertFrom-Json}
      }
    }
  }catch{}
  return $null
}

function Get-HttpErrorStatus($ErrorRecord){
  try{
    $response=$ErrorRecord.Exception.Response
    if($response -and $null -ne $response.StatusCode){
      try{return [int]$response.StatusCode}catch{}
      try{return [int]$response.StatusCode.value__}catch{}
    }
  }catch{}
  try{
    $message=([string]$ErrorRecord.Exception.Message)
    if($message -match '(?<!\\d)(409|429)(?!\\d)'){return [int]$Matches[1]}
  }catch{}
  try{
    $rendered=($ErrorRecord|Out-String)
    if($rendered -match '(?<!\\d)(409|429)(?!\\d)'){return [int]$Matches[1]}
  }catch{}
  return 0
}


function Get-LatestAstraFailure{
  if(-not(Test-Path -LiteralPath $prospectAuditPath -PathType Leaf)){return ''}
  try{
    $lines=@(Get-Content -LiteralPath $prospectAuditPath -Tail 100 -Encoding UTF8)
    [array]::Reverse($lines)
    foreach($line in $lines){
      try{
        $entry=$line|ConvertFrom-Json -ErrorAction Stop
        if([string]$entry.action -eq 'astra-review' -and -not [bool]$entry.ok){
          $detail=([string]$entry.detail).Trim()
          if($detail.Length -gt 500){$detail=$detail.Substring(0,500)}
          return $detail
        }
      }catch{}
    }
  }catch{}
  return ''
}

function Get-ProspectSnapshot{
  return Invoke-RestMethod -Method Get -Uri ($endpoint+'/api/prospects') -TimeoutSec 30
}

function Get-DraftCount($Snapshot){
  if(-not $Snapshot -or -not $Snapshot.store){return 0}
  return @($Snapshot.store.leads|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_.outlookDraftId)}).Count
}

if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "Astra request is missing: $RequestPath"}
$request=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$request.id).Trim()
if([int]$request.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid Astra request identity.'}
if([string]$request.status -ne 'ACTIVE' -or [string]$request.action -ne 'review-all-eligible-leads'){throw 'Astra request is not active or allowlisted.'}
if([string]$request.target -ne 'windows-main' -or [string]$request.endpoint -ne $endpoint){throw 'Astra request target contract mismatch.'}
if([int]$request.batch_limit -ne 3 -or [int]$request.max_batches -lt 1 -or [int]$request.max_batches -gt 50 -or [int]$request.max_transient_retries -lt 0 -or [int]$request.max_transient_retries -gt 30 -or [int]$request.inter_batch_delay_seconds -lt 1 -or [int]$request.inter_batch_delay_seconds -gt 10){throw 'Astra request batch contract is invalid.'}
if(-not [bool]$request.preserve_original_research -or -not [bool]$request.preserve_original_drafts){throw 'Astra request must preserve original lead content.'}
if([bool]$request.create_outlook_drafts -or [bool]$request.send_email){throw 'Astra one-shot cannot create Outlook drafts or send email.'}

$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if([string]$identity.User.Value -ne 'S-1-5-18'){throw 'Astra one-shot must run as SYSTEM.'}
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
$statePath=Join-Path $stateRoot ($id+'.json')
if(Test-Path -LiteralPath $statePath -PathType Leaf){
  try{
    $existing=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$existing.status -eq 'completed'){$existing|ConvertTo-Json -Depth 20 -Compress;exit 0}
  }catch{}
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZProspectAstraReviewAll')
$locked=$false
$state=$null
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){
    [ordered]@{ok=$true;status='already-running';requestId=$id}|ConvertTo-Json -Compress
    exit 0
  }

  $started=Get-Date
  $state=[ordered]@{
    schema=1;purpose='PROSPECT_ASTRA_REVIEW_ALL_RESULT';source='windows-main';requestId=$id
    action='review-all-eligible-leads';agent='Astra';model='configured-gpt-5.6-sol'
    status='waiting-for-engine';ok=$false;batchesCompleted=0;leadsChecked=0
    approved=0;revise=0;hold=0;remaining=$null;beforeOutlookDrafts=$null;afterOutlookDrafts=$null
    originalResearchPreserved=$true;originalDraftsPreserved=$true;outlookDraftCreationAllowed=$false;emailSendingAllowed=$false
    transientRetries=0;errorClass=$null;upstreamError=$null
    startedAt=$started.ToString('o');updatedAt=$started.ToString('o');finishedAt=$null;error=$null
  }
  Write-AstraState $state $statePath

  $snapshot=$null
  for($attempt=1;$attempt -le 30;$attempt++){
    try{$snapshot=Get-ProspectSnapshot;break}catch{Start-Sleep -Seconds 2}
  }
  if(-not $snapshot){throw 'Prospect Engine did not become available on localhost:8796.'}
  $state.beforeOutlookDrafts=Get-DraftCount $snapshot
  $state.status='running'
  $state.updatedAt=(Get-Date -Format o)
  Write-AstraState $state $statePath

  $transientRetries=0
  for($batch=1;$batch -le [int]$request.max_batches;$batch++){
    try{
      $body=[Text.Encoding]::UTF8.GetBytes((@{limit=[int]$request.batch_limit}|ConvertTo-Json -Compress))
      $result=Invoke-RestMethod -Method Post -Uri ($endpoint+'/api/prospects/astra-review') -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 300
      if(-not [bool]$result.ok){throw 'Astra endpoint returned an unsuccessful result.'}
      $transientRetries=0
      $state.batchesCompleted=[int]$state.batchesCompleted+1
      $state.leadsChecked=[int]$state.leadsChecked+[int]$result.checked
      $state.approved=[int]$result.approved
      $state.revise=[int]$result.revise
      $state.hold=[int]$result.hold
      $state.remaining=[int]$result.remaining
      $state.updatedAt=(Get-Date -Format o)
      Write-AstraState $state $statePath
      if([bool]$result.complete){break}
      Start-Sleep -Seconds ([math]::Max(1,[math]::Min(10,[int]$request.inter_batch_delay_seconds)))
    }catch{
      $caught=$_
      $errorBody=Get-HttpErrorBody $caught
      $httpStatus=Get-HttpErrorStatus $caught
      $exceptionMessage=([string]$caught.Exception.Message)
      $messageHas429=$exceptionMessage.Contains('(429)')
      $code=if($errorBody){[string]$errorBody.code}else{''}
      $upstreamError=Get-LatestAstraFailure
      $state.upstreamError=$upstreamError
      $quotaBlocked=($code -eq 'openai_quota') -or ($upstreamError -match '(?i)quota|billing|credit balance|insufficient[_ ]quota')
      if($quotaBlocked){
        $state.errorClass='openai_quota'
        if([string]::IsNullOrWhiteSpace($upstreamError)){$upstreamError='OpenAI API quota or billing is blocking Astra verification.'}
        throw $upstreamError
      }
      $retryable=($code -in @('openai_rate_limit','research_in_progress')) -or ($httpStatus -in @(409,429)) -or $messageHas429
      if(-not $retryable -or $transientRetries -ge [int]$request.max_transient_retries){throw}
      $transientRetries++
      $state.transientRetries=$transientRetries
      $state.errorClass='openai_rate_limit'
      $delay=10
      if($errorBody -and $errorBody.PSObject.Properties.Name -contains 'retryAfterSeconds' -and [int]$errorBody.retryAfterSeconds -gt 0){$delay=[math]::Min(90,[int]$errorBody.retryAfterSeconds)}
      $state.status='waiting-to-retry'
      $state.updatedAt=(Get-Date -Format o)
      $state.error="Transient HTTP $httpStatus $code; retry $transientRetries after $delay seconds."
      Write-AstraState $state $statePath
      Start-Sleep -Seconds $delay
      $batch--
    }
  }

  $snapshot=Get-ProspectSnapshot
  $state.afterOutlookDrafts=Get-DraftCount $snapshot
  if($null -eq $state.remaining -or [int]$state.remaining -ne 0){throw "Astra stopped with $($state.remaining) eligible leads remaining."}
  $state.status='completed';$state.ok=$true;$state.error=$null;$state.updatedAt=(Get-Date -Format o);$state.finishedAt=$state.updatedAt
  Write-AstraState $state $statePath
  $state|ConvertTo-Json -Depth 20 -Compress
  exit 0
}catch{
  if(-not $state){$state=[ordered]@{schema=1;purpose='PROSPECT_ASTRA_REVIEW_ALL_RESULT';source='windows-main';requestId=$id}}
  $state.status='failed';$state.ok=$false;$state.error=$_.Exception.Message;$state.updatedAt=(Get-Date -Format o);$state.finishedAt=$state.updatedAt
  Write-AstraState $state $statePath
  $state|ConvertTo-Json -Depth 20 -Compress
  exit 1
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
