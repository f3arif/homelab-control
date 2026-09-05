#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalSeconds=5
)

$ErrorActionPreference='Stop'
$IntervalSeconds=[math]::Max(3,[math]::Min($IntervalSeconds,30))
$requestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\stremio-organize.json'
$runner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-Stremio-Organize.ps1'
$sourceState='C:\ProgramData\AFZ\OpenAIAgent\source-state.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\stremio-organize-request'
$stateFile=Join-Path $stateRoot 'latest.json'
$logFile=Join-Path $stateRoot 'watcher.log'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Log([string]$Message){
  Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8
}
function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json}catch{return $null}
}
function Save-State($Values){
  $o=[ordered]@{
    updatedAt=(Get-Date -Format o)
    transport='github-pull-typed-request'
    requestFile='afz-openai-agent/requests/stremio-organize.json'
  }
  foreach($k in $Values.Keys){$o[$k]=$Values[$k]}
  $o | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $stateFile -Encoding UTF8
}
function Current-Sha{
  $s=Read-Json $sourceState
  if($s -and ([string]$s.remoteSha) -match '^[0-9a-fA-F]{40}$'){return ([string]$s.remoteSha).ToLowerInvariant()}
  return ''
}
function Valid-Request($r){
  if(-not $r){return $false}
  if(-not [bool]$r.enabled){return $false}
  if([int]$r.schema -ne 1){return $false}
  if([string]$r.project -ne 'stremio-organize'){return $false}
  if([string]$r.action -notin @('audit','apply')){return $false}
  if(([string]$r.job_id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){return $false}
  return $true
}
function Get-Summary($Result){
  $view=$(if($Result.after){$Result.after}else{$Result.before})
  if(-not $view){$view=[pscustomobject]@{}}
  return [ordered]@{
    ok=[bool]$Result.ok
    action=[string]$Result.action
    changed=$(if($null -ne $Result.changed){[bool]$Result.changed}else{$false})
    count=$(if($null -ne $view.count){[int]$view.count}else{$null})
    afzVersion=[string]$view.afzVersion
    homeRowCount=$(if($null -ne $Result.homeRowCount){[int]$Result.homeRowCount}else{$null})
    order=@($view.order)
    traktCatalogs=@($view.traktCatalogs)
    debridioTvCatalogs=@($view.debridioTvCatalogs)
  }
}
function Handle-Request{
  $req=Read-Json $requestFile
  if(-not(Valid-Request $req)){return}

  $job=[string]$req.job_id
  $action=([string]$req.action).ToLowerInvariant()
  $state=Read-Json $stateFile
  if($state -and [string]$state.jobId -eq $job -and [string]$state.status -in @('completed','failed')){return}

  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable'}
  if(-not(Test-Path -LiteralPath $runner -PathType Leaf)){throw "Stremio organizer runner missing: $runner"}

  Save-State ([ordered]@{
    ok=$true;status='running';jobId=$job;action=$action;sourceSha=$sha
    message='Executing typed Stremio organizer request locally on windows-main.'
  })
  Log "START job=$job action=$action sha=$sha"

  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -Action $action -InstallRoot $InstallRoot 2>&1 | Out-String).Trim()
  $exitCode=$LASTEXITCODE
  if($exitCode -ne 0){
    $msg=$raw
    if($msg.Length -gt 800){$msg=$msg.Substring(0,800)}
    Save-State ([ordered]@{ok=$false;status='failed';jobId=$job;action=$action;sourceSha=$sha;message=("Organizer exited $exitCode: "+$msg)})
    Log "FAIL job=$job action=$action exit=$exitCode"
    return
  }

  $parsed=$null
  foreach($line in @($raw -split "[\r\n]+")){
    $t=$line.Trim()
    if($t.StartsWith('{')){
      try{$candidate=$t|ConvertFrom-Json;if($candidate -and $null -ne $candidate.ok){$parsed=$candidate}}catch{}
    }
  }
  if(-not $parsed){
    $msg=$raw
    if($msg.Length -gt 800){$msg=$msg.Substring(0,800)}
    Save-State ([ordered]@{ok=$false;status='failed';jobId=$job;action=$action;sourceSha=$sha;message=('Organizer returned no parseable JSON: '+$msg)})
    Log "FAIL job=$job action=$action reason=no-json"
    return
  }
  if(-not [bool]$parsed.ok){
    Save-State ([ordered]@{ok=$false;status='failed';jobId=$job;action=$action;sourceSha=$sha;message='Organizer returned ok=false.'})
    Log "FAIL job=$job action=$action reason=ok-false"
    return
  }

  $summary=Get-Summary $parsed
  Save-State ([ordered]@{
    ok=$true;status='completed';jobId=$job;action=$action;sourceSha=$sha
    result=$summary
    message='Typed Stremio organizer request completed locally on windows-main.'
  })
  Log "DONE job=$job action=$action count=$($summary.count) afz=$($summary.afzVersion)"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZStremioOrganizeRequestWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "WATCHER_START interval=$IntervalSeconds"
  while($true){
    try{Handle-Request}catch{
      $msg=$_.Exception.Message
      Log "ERROR $msg"
      $req=Read-Json $requestFile
      Save-State ([ordered]@{
        ok=$false;status='failed';jobId=$(if($req){[string]$req.job_id}else{''});action=$(if($req){[string]$req.action}else{''})
        sourceSha=(Current-Sha);message=$msg
      })
    }
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
