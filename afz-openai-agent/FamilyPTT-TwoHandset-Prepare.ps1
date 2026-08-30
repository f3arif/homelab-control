#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath='',
  [string]$ResultPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\familyptt-two-handset-prepare\latest.json'
)
$ErrorActionPreference='Stop'

$package='ca.afzeng.familyptt'
$component='ca.afzeng.familyptt/.MainActivity'
$defaultRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\familyptt-two-handset-prepare.json'
if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=$defaultRequest}
$stateRoot=Split-Path -Parent $ResultPath
$logFile=Join-Path $stateRoot 'prepare.log'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'FAMILYPTT-TWO-HANDSET-PREPARE-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Log([string]$m){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $m" -Encoding UTF8}
function Read-Json([string]$p){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){return $null};try{return Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}}
function Save-Result($o){$o|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $ResultPath -Encoding UTF8}
function Mirror-Result($o){
  try{
    if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){return $false}
    $mirror=[ordered]@{
      purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';controlPlane='github';source='windows-main';project='familyptt';jobId=$o.jobId
      status=$o.status;ok=$o.ok;classification=$o.classification;startedAt=$o.startedAt;finishedAt=$o.finishedAt
      deviceA=$o.deviceA;deviceB=$o.deviceB;apk=$o.apk;error=$o.error;mirroredAt=(Get-Date -Format o)
    }
    [IO.File]::WriteAllText($diagFile,($mirror|ConvertTo-Json -Depth 12),$utf8)
    return $true
  }catch{return $false}
}
function Publish-Issue($o){
  try{
    $gh=Get-Command gh.exe -ErrorAction SilentlyContinue
    if(-not $gh){return $false}
    $body=@"
### FamilyPTT physical two-handset preparation

Job: ``$($o.jobId)``
Classification: ``$($o.classification)``
Success: $($o.ok)
Pixel 6 Pro endpoint: ``$($o.deviceA.serial)``
Pixel 8 endpoint: ``$($o.deviceB.serial)``
Pixel 6 Pro PID: ``$($o.deviceA.pid)``
Pixel 8 PID: ``$($o.deviceB.pid)``
APK count: $($o.apk.count)
APK SHA-256: ``$($o.apk.primarySha256)``
Pixel 8 install result: ``$($o.deviceB.installResult)``
Record-audio grant A/B: $($o.deviceA.recordAudioGranted) / $($o.deviceB.recordAudioGranted)

The two physical handsets are prepared and launched from the same APK package set. Physical speaker audibility is still intentionally manual and must be confirmed A→B and B→A before the rollback container is removed.
"@
    $tmp=Join-Path $env:TEMP ('familyptt-two-handset-'+[guid]::NewGuid().ToString('n')+'.json')
    try{[ordered]@{body=$body}|ConvertTo-Json -Depth 3|Set-Content -LiteralPath $tmp -Encoding UTF8;& $gh.Source api --method POST 'repos/f3arif/homelab-control/issues/17/comments' --input $tmp *> $null;return ($LASTEXITCODE -eq 0)}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
  }catch{return $false}
}
function Find-Adb{
  $c=Get-Command adb.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @(
    'C:\Users\Faiz\AppData\Local\Android\Sdk\platform-tools\adb.exe',
    'C:\Android\platform-tools\adb.exe',
    'C:\Program Files\Android\Android Studio\platform-tools\adb.exe'
  )){if(Test-Path -LiteralPath $p -PathType Leaf){return $p}}
  return $null
}
function Invoke-Adb([string]$adb,[string[]]$a,[switch]$AllowFailure){
  # adb writes normal progress (notably `adb pull`) to stderr. Under Windows
  # PowerShell 5.1, ErrorActionPreference=Stop can promote that native stderr
  # stream into a terminating NativeCommandError even when adb exits 0. Lower
  # ErrorActionPreference only for the native process, capture both streams,
  # then restore strict script-level error handling immediately.
  $priorEap=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    $raw=@(& $adb @a 2>&1)
    $code=$LASTEXITCODE
  }finally{
    $ErrorActionPreference=$priorEap
  }
  $out=@($raw|ForEach-Object{[string]$_})
  if(-not $AllowFailure -and $code -ne 0){throw "adb failed exit=$code args=$($a -join ' ') output=$($out -join ' | ')"}
  return [pscustomobject]@{exitCode=$code;output=$out}
}
function Device-Present([string]$adb,[string]$serial){
  $r=Invoke-Adb $adb @('devices')
  foreach($line in $r.output){if(([string]$line) -match ('^'+[regex]::Escape($serial)+'\s+device$')){return $true}}
  return $false
}
function Get-Pid([string]$adb,[string]$serial){
  $r=Invoke-Adb $adb @('-s',$serial,'shell','pidof',$package) -AllowFailure
  if($r.exitCode -ne 0){return ''};return (($r.output -join '').Trim())
}
function Audio-Granted([string]$adb,[string]$serial){
  $r=Invoke-Adb $adb @('-s',$serial,'shell','dumpsys','package',$package) -AllowFailure
  return (($r.output -join "`n") -match 'android\.permission\.RECORD_AUDIO:\s+granted=true')
}

$req=Read-Json $RequestPath
if(-not $req){exit 0}
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'familyptt' -or [string]$req.action -ne 'prepare-two-handset-physical-e2e' -or [int]$req.issue -ne 17){exit 0}
$job=[string]$req.job_id
$deviceA=[string]$req.device_a
$deviceB=[string]$req.device_b
if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,100}$'){throw 'invalid job id'}
if($deviceA -ne '19161FDEE008XN'){throw 'unexpected DeviceA; only the proven Pixel 6 Pro is allowed'}
if($deviceB -ne '192.168.50.69:38209'){throw 'unexpected DeviceB; only the currently paired Pixel 8 endpoint is allowed'}

$prior=Read-Json $ResultPath
if($prior -and [string]$prior.jobId -eq $job -and [string]$prior.status -eq 'completed'){$null=Mirror-Result $prior;Log "SKIP completed job=$job mirrored=true";exit 0}

$result=[ordered]@{
  schema=1;jobId=$job;status='running';ok=$false;classification='TWO_HANDSET_PREPARE_RUNNING';startedAt=(Get-Date -Format o);finishedAt=$null
  deviceA=[ordered]@{serial=$deviceA;model='Pixel 6 Pro';pid=$null;recordAudioGranted=$false}
  deviceB=[ordered]@{serial=$deviceB;model='Pixel 8';pid=$null;recordAudioGranted=$false;installResult=$null}
  apk=[ordered]@{count=0;primarySha256=$null;files=@()}
  error=$null
}
Save-Result $result
$null=Mirror-Result $result
Log "START job=$job A=$deviceA B=$deviceB"

try{
  $env:USERPROFILE='C:\Users\Faiz'
  $env:HOME='C:\Users\Faiz'
  $env:ANDROID_USER_HOME='C:\Users\Faiz'
  if(Test-Path -LiteralPath 'C:\Users\Faiz\.android\adbkey' -PathType Leaf){$env:ADB_VENDOR_KEYS='C:\Users\Faiz\.android\adbkey'}

  $adb=Find-Adb
  if(-not $adb){throw 'adb.exe not found'}

  if(-not(Device-Present $adb $deviceA)){throw 'Pixel 6 Pro is not present on ADB'}
  if(-not(Device-Present $adb $deviceB)){
    $connect=Invoke-Adb $adb @('connect',$deviceB) -AllowFailure
    Log "ADB_CONNECT_B exit=$($connect.exitCode) output=$($connect.output -join ' | ')"
    Start-Sleep -Seconds 2
  }
  if(-not(Device-Present $adb $deviceB)){throw 'Pixel 8 direct ADB endpoint is not connected'}

  $pathsRaw=Invoke-Adb $adb @('-s',$deviceA,'shell','pm','path',$package)
  $remoteApks=@($pathsRaw.output|Where-Object{$_ -match '^package:'}|ForEach-Object{$_.Substring(8).Trim()})
  if($remoteApks.Count -lt 1){throw 'FamilyPTT package is not installed on Pixel 6 Pro'}

  $work=Join-Path $env:TEMP ('familyptt-proven-apk-'+$job)
  if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $work|Out-Null
  $localApks=@();$apkInfo=@()
  foreach($remote in $remoteApks){
    $name=[IO.Path]::GetFileName($remote);if([string]::IsNullOrWhiteSpace($name)){$name='base.apk'}
    $local=Join-Path $work $name
    $null=Invoke-Adb $adb @('-s',$deviceA,'pull',$remote,$local)
    if(-not(Test-Path -LiteralPath $local -PathType Leaf)){throw "APK pull produced no file: $remote"}
    $hash=(Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()
    $localApks+=$local;$apkInfo+=[ordered]@{name=$name;source=$remote;sha256=$hash;bytes=(Get-Item -LiteralPath $local).Length}
  }
  $result.apk.count=$localApks.Count;$result.apk.files=$apkInfo;$result.apk.primarySha256=[string]$apkInfo[0].sha256;Save-Result $result;$null=Mirror-Result $result

  if($localApks.Count -eq 1){$install=Invoke-Adb $adb @('-s',$deviceB,'install','-r',$localApks[0])}
  else{$installArgs=@('-s',$deviceB,'install-multiple','-r')+$localApks;$install=Invoke-Adb $adb $installArgs}
  $installText=($install.output -join ' ').Trim();$result.deviceB.installResult=$installText
  if($installText -notmatch '(?i)Success'){throw "Pixel 8 install did not report Success: $installText"}

  foreach($serial in @($deviceA,$deviceB)){
    $grant=Invoke-Adb $adb @('-s',$serial,'shell','pm','grant',$package,'android.permission.RECORD_AUDIO') -AllowFailure
    Log "GRANT serial=$serial exit=$($grant.exitCode) output=$($grant.output -join ' | ')"
  }
  $result.deviceA.recordAudioGranted=Audio-Granted $adb $deviceA
  $result.deviceB.recordAudioGranted=Audio-Granted $adb $deviceB
  if(-not $result.deviceA.recordAudioGranted -or -not $result.deviceB.recordAudioGranted){throw 'RECORD_AUDIO is not granted on both handsets'}

  foreach($serial in @($deviceA,$deviceB)){Invoke-Adb $adb @('-s',$serial,'shell','am','force-stop',$package)|Out-Null}
  Invoke-Adb $adb @('-s',$deviceA,'shell','am','start','-W','-n',$component)|Out-Null
  Invoke-Adb $adb @('-s',$deviceB,'shell','am','start','-W','-n',$component)|Out-Null
  Start-Sleep -Seconds 7

  $pidA=Get-Pid $adb $deviceA;$pidB=Get-Pid $adb $deviceB
  $result.deviceA.pid=$pidA;$result.deviceB.pid=$pidB
  if([string]::IsNullOrWhiteSpace($pidA) -or [string]::IsNullOrWhiteSpace($pidB)){throw "FamilyPTT process missing after launch A=$pidA B=$pidB"}

  $result.ok=$true;$result.status='completed';$result.classification='TWO_HANDSET_READY_PHYSICAL_AUDIBILITY_PENDING';$result.finishedAt=(Get-Date -Format o)
  Save-Result $result
  $mirrored=Mirror-Result $result
  $published=Publish-Issue $result
  Log "PASS job=$job pidA=$pidA pidB=$pidB mirrored=$mirrored published=$published apkSha=$($result.apk.primarySha256)"
  exit 0
}catch{
  $result.ok=$false;$result.status='failed';$result.classification='TWO_HANDSET_PREPARE_FAILED';$result.error=$_.Exception.Message;$result.finishedAt=(Get-Date -Format o)
  Save-Result $result
  $mirrored=Mirror-Result $result
  $published=Publish-Issue $result
  Log "FAIL job=$job error=$($result.error) mirrored=$mirrored published=$published"
  exit 40
}
