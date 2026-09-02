#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalSeconds=5
)

$ErrorActionPreference='Stop'
$IntervalSeconds=[math]::Max(3,[math]::Min($IntervalSeconds,30))
$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\afz-blog-git-migration.json'
$Executor=Join-Path $InstallRoot 'afz-openai-agent\Invoke-AFZ-Blog-GitMigration.ps1'
$StateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-blog-git-migration-watcher'
$StatePath=Join-Path $StateRoot 'latest.json'
$LogPath=Join-Path $StateRoot 'watcher.log'
$CarrierTask='AFZ Edge Backup'
$MigrationResult='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-blog-git-migration\latest.json'
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

function Log([string]$Message){Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) $Message" -Encoding UTF8}
function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}}
function Save-State([hashtable]$Values){
  $o=[ordered]@{schema=1;component='AFZ Blog Git Migration Request Watcher';project='afz-blog';updatedAt=(Get-Date -Format o)}
  foreach($k in $Values.Keys){$o[$k]=$Values[$k]}
  $o|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $StatePath -Encoding UTF8
}
function Test-Request($r){
  if(-not $r){return $false}
  if([string]$r.schema -ne 'afz.blog.git-migration.request.v1'){return $false}
  if(-not [bool]$r.enabled){return $false}
  if([string]$r.action -ne 'apply'){return $false}
  if([string]$r.projectId -ne 'afz-blog'){return $false}
  if([string]$r.targetHost -ne 'DESKTOP-10SKF0M'){return $false}
  if([string]$r.sourceRoot -ne 'C:\docker\afz-blog-manager'){return $false}
  if([string]$r.desiredRepository -ne 'f3arif/AFZ-Blog'){return $false}
  if([string]$r.desiredVisibility -ne 'private'){return $false}
  if([string]$r.defaultBranch -ne 'main'){return $false}
  if(-not [bool]$r.preserveDirtyTree -or -not [bool]$r.excludeSecrets){return $false}
  if([bool]$r.replaceProductionGit -or [bool]$r.publishWebsite -or [bool]$r.restartBlog){return $false}
  if(([string]$r.id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){return $false}
  return $true
}
function New-RestoreAction($s){
  $p=@{Execute=[string]$s.originalExecute}
  if(-not [string]::IsNullOrWhiteSpace([string]$s.originalArguments)){$p.Argument=[string]$s.originalArguments}
  if(-not [string]::IsNullOrWhiteSpace([string]$s.originalWorkingDirectory)){$p.WorkingDirectory=[string]$s.originalWorkingDirectory}
  return New-ScheduledTaskAction @p
}
function Restore-Carrier($s){
  if(-not $s -or [string]::IsNullOrWhiteSpace([string]$s.originalExecute)){throw 'Carrier restoration metadata missing'}
  Set-ScheduledTask -TaskName $CarrierTask -Action (New-RestoreAction $s) | Out-Null
  if([bool]$s.originalEnabled){Enable-ScheduledTask -TaskName $CarrierTask|Out-Null}else{Disable-ScheduledTask -TaskName $CarrierTask|Out-Null}
}
function Handle-Request {
  if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){return}
  if(-not(Test-Path -LiteralPath $Executor -PathType Leaf)){throw "Migration executor missing: $Executor"}
  $req=Read-Json $RequestPath
  if(-not(Test-Request $req)){throw 'AFZ Blog Git migration request failed fixed-contract validation'}
  $id=[string]$req.id
  $state=Read-Json $StatePath

  if($state -and [string]$state.requestId -eq $id -and [string]$state.status -in @('completed','blocked')){return}

  if($state -and [string]$state.requestId -eq $id -and [string]$state.status -eq 'running'){
    $carrier=Get-ScheduledTask -TaskName $CarrierTask -ErrorAction SilentlyContinue
    if($carrier -and [string]$carrier.State -eq 'Running'){return}
    $result=Read-Json $MigrationResult
    try{Restore-Carrier $state}catch{
      Save-State @{requestId=$id;status='blocked';ok=$false;message=('Migration carrier finished but restoration failed: '+$_.Exception.Message)}
      return
    }
    if($result -and [string]$result.requestId -eq $id){
      Save-State @{requestId=$id;status=$(if([bool]$result.ok){'completed'}else{'blocked'});ok=[bool]$result.ok;migrationState=[string]$result.state;repo=$result.repo;next=[string]$result.next;error=[string]$result.error;carrierRestored=$true}
      Log "DONE request=$id migrationState=$([string]$result.state) ok=$([bool]$result.ok)"
    }else{
      Save-State @{requestId=$id;status='blocked';ok=$false;message='Carrier finished without a matching migration result';carrierRestored=$true}
    }
    return
  }

  if($state -and [string]$state.status -eq 'arming'){
    try{Restore-Carrier $state}catch{}
    Save-State @{requestId=$id;status='blocked';ok=$false;message='Recovered an interrupted arming state; change request id to retry.'}
    return
  }

  $carrier=Get-ScheduledTask -TaskName $CarrierTask -ErrorAction SilentlyContinue
  if(-not $carrier){throw "Interactive carrier task missing: $CarrierTask"}
  if([string]$carrier.State -eq 'Running'){
    Save-State @{requestId=$id;status='waiting';ok=$true;message='Waiting for AFZ Edge Backup carrier to become idle.'}
    return
  }
  $a=$carrier.Actions|Select-Object -First 1
  if(-not $a -or [string]::IsNullOrWhiteSpace([string]$a.Execute)){throw 'Carrier has no restorable action'}
  $enabled=([string]$carrier.State -ne 'Disabled')
  Remove-Item -LiteralPath $MigrationResult -Force -ErrorAction SilentlyContinue
  Save-State @{requestId=$id;status='arming';ok=$true;originalEnabled=$enabled;originalExecute=[string]$a.Execute;originalArguments=[string]$a.Arguments;originalWorkingDirectory=[string]$a.WorkingDirectory}

  $args="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Executor`" -Action apply -RequestId `"$id`""
  Set-ScheduledTask -TaskName $CarrierTask -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args)|Out-Null
  Enable-ScheduledTask -TaskName $CarrierTask|Out-Null
  Start-ScheduledTask -TaskName $CarrierTask
  Save-State @{requestId=$id;status='running';ok=$true;originalEnabled=$enabled;originalExecute=[string]$a.Execute;originalArguments=[string]$a.Arguments;originalWorkingDirectory=[string]$a.WorkingDirectory;message='Guarded Blog Git migration started under interactive carrier.'}
  Log "START request=$id"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZBlogGitMigrationRequestWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "WATCHER_START interval=$IntervalSeconds"
  while($true){
    try{Handle-Request}catch{$m=$_.Exception.Message;Log "ERROR $m";Save-State @{status='error';ok=$false;message=$m}}
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
