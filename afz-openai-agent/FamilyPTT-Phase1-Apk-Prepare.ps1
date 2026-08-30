#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath='',
  [string]$ResultPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\familyptt-phase1-apk-prepare\latest.json'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$package='ca.afzeng.familyptt'
$component='ca.afzeng.familyptt/.MainActivity'
$deviceA='19161FDEE008XN'
$preferredDeviceB='192.168.50.69:38209'
$expectedSha='4bc8ceafe13ea42eb68cf0f682dec5dbbab9980510d642993453e8e788e9117b'
$expectedWorkflowRun=33325967023
$bridgeRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$apkPath=Join-Path $bridgeRoot 'FamilyPTT-standalone-arm64-phase1.apk'
$diagPath=Join-Path $bridgeRoot 'FAMILYPTT-PHASE1-APK-PREP-LATEST.txt'
if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\familyptt-phase1-apk-prepare.json'}
$stateRoot=Split-Path -Parent $ResultPath
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
$logPath=Join-Path $stateRoot 'prepare.log'

function Log([string]$m){Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) $m" -Encoding UTF8}
function Read-Json([string]$p){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){return $null};try{return Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}}
function Save-Result($o){$o|ConvertTo-Json -Depth 14|Set-Content -LiteralPath $ResultPath -Encoding UTF8}
function Mirror-Result($o){try{if(Test-Path -LiteralPath $bridgeRoot -PathType Container){$o|ConvertTo-Json -Depth 14|Set-Content -LiteralPath $diagPath -Encoding UTF8;return $true}}catch{};return $false}
function Find-Adb{
  $c=Get-Command adb.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Users\Faiz\AppData\Local\Android\Sdk\platform-tools\adb.exe','C:\Android\platform-tools\adb.exe')){if(Test-Path -LiteralPath $p -PathType Leaf){return $p}}
  return $null
}
function Invoke-Adb([string]$adb,[string[]]$a,[switch]$AllowFailure){
  $prior=$ErrorActionPreference
  try{$ErrorActionPreference='Continue';$raw=@(& $adb @a 2>&1);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$prior}
  $out=@($raw|ForEach-Object{[string]$_})
  if(-not $AllowFailure -and $code -ne 0){throw "adb failed exit=$code args=$($a -join ' ') output=$($out -join ' | ')"}
  return [pscustomobject]@{exitCode=$code;output=$out}
}
function Get-Devices([string]$adb){
  $r=Invoke-Adb $adb @('devices','-l');$rows=@()
  foreach($line in $r.output){$s=[string]$line;if($s -match '^([^\s]+)\s+device\b'){$rows+=[pscustomobject]@{serial=$Matches[1];line=$s}}}
  return @($rows)
}
function Get-Pid([string]$adb,[string]$serial){$r=Invoke-Adb $adb @('-s',$serial,'shell','pidof',$package) -AllowFailure;if($r.exitCode -ne 0){return ''};return (($r.output -join '').Trim())}
function Audio-Granted([string]$adb,[string]$serial){$r=Invoke-Adb $adb @('-s',$serial,'shell','dumpsys','package',$package) -AllowFailure;return (($r.output -join "`n") -match 'android\.permission\.RECORD_AUDIO:\s+granted=true')}

$req=Read-Json $RequestPath
if(-not $req){exit 0}
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'familyptt' -or [string]$req.action -ne 'prepare-phase1-acceptance-apk'){exit 0}
if([string]$req.status -ne 'active'){Log "SKIP request status=$([string]$req.status)";exit 0}
if([int64]$req.workflow_run_id -ne $expectedWorkflowRun){throw 'unexpected workflow run id'}
if(([string]$req.apk_sha256).ToLowerInvariant() -ne $expectedSha){throw 'request APK SHA256 does not match validated Phase 1 APK'}
if([string]$req.package_id -ne $package){throw 'unexpected package id'}
if([string]$req.device_a -ne $deviceA){throw 'unexpected Pixel 6 Pro endpoint'}
if([string]$req.device_b -ne $preferredDeviceB){throw 'unexpected Pixel 8 endpoint'}
$job=[string]$req.job_id
if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,100}$'){throw 'invalid job id'}

$prior=Read-Json $ResultPath
if($prior -and [string]$prior.jobId -eq $job -and [string]$prior.status -eq 'completed'){$null=Mirror-Result $prior;Log "SKIP completed job=$job";exit 0}

$result=[ordered]@{
  schema=1;jobId=$job;status='running';ok=$false;classification='PHASE1_APK_PREP_RUNNING';startedAt=(Get-Date -Format o);finishedAt=$null
  source=[ordered]@{repository=[string]$req.repository;workflowRunId=[int64]$req.workflow_run_id;artifactName=[string]$req.artifact_name}
  apk=[ordered]@{path=$apkPath;expectedSha256=$expectedSha;actualSha256=$null;bytes=$null}
  deviceA=[ordered]@{serial=$deviceA;model='Pixel 6 Pro';pid=$null;recordAudioGranted=$false;installResult=$null}
  deviceB=[ordered]@{serial=$null;model='Pixel 8';pid=$null;recordAudioGranted=$false;installResult=$null}
  error=$null
}
Save-Result $result;$null=Mirror-Result $result;Log "START job=$job"

try{
  if(-not(Test-Path -LiteralPath $apkPath -PathType Leaf)){throw "staged Phase 1 APK missing: $apkPath"}
  $actual=(Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $result.apk.actualSha256=$actual;$result.apk.bytes=(Get-Item -LiteralPath $apkPath).Length
  if($actual -ne $expectedSha){throw "Phase 1 APK SHA256 mismatch expected=$expectedSha actual=$actual"}

  $env:USERPROFILE='C:\Users\Faiz';$env:HOME='C:\Users\Faiz';$env:ANDROID_USER_HOME='C:\Users\Faiz'
  if(Test-Path -LiteralPath 'C:\Users\Faiz\.android\adbkey' -PathType Leaf){$env:ADB_VENDOR_KEYS='C:\Users\Faiz\.android\adbkey'}
  $adb=Find-Adb;if(-not $adb){throw 'adb.exe not found'}
  $devices=@(Get-Devices $adb)
  if(-not($devices.serial -contains $deviceA)){throw 'Pixel 6 Pro USB ADB endpoint is not connected'}

  $deviceB=$null
  if($devices.serial -contains $preferredDeviceB){$deviceB=$preferredDeviceB}
  if(-not $deviceB){
    $pixel8=@($devices|Where-Object{$_.line -match '\bmodel:Pixel_8\b'}|Select-Object -First 1)
    if($pixel8.Count -gt 0){$deviceB=[string]$pixel8[0].serial}
  }
  if(-not $deviceB){
    $connect=Invoke-Adb $adb @('connect',$preferredDeviceB) -AllowFailure;Log "CONNECT preferred exit=$($connect.exitCode) output=$($connect.output -join ' | ')";Start-Sleep -Seconds 2
    $devices=@(Get-Devices $adb);if($devices.serial -contains $preferredDeviceB){$deviceB=$preferredDeviceB}
  }
  if(-not $deviceB){throw 'Pixel 8 is not connected to ADB'}
  $result.deviceB.serial=$deviceB;Save-Result $result;$null=Mirror-Result $result

  foreach($serial in @($deviceA,$deviceB)){
    $install=Invoke-Adb $adb @('-s',$serial,'install','-r',$apkPath)
    $text=($install.output -join ' ').Trim()
    if($serial -eq $deviceA){$result.deviceA.installResult=$text}else{$result.deviceB.installResult=$text}
    if($text -notmatch '(?i)Success'){throw "install did not report Success for $serial`: $text"}
  }
  foreach($serial in @($deviceA,$deviceB)){$null=Invoke-Adb $adb @('-s',$serial,'shell','pm','grant',$package,'android.permission.RECORD_AUDIO') -AllowFailure}
  $result.deviceA.recordAudioGranted=Audio-Granted $adb $deviceA;$result.deviceB.recordAudioGranted=Audio-Granted $adb $deviceB
  if(-not $result.deviceA.recordAudioGranted -or -not $result.deviceB.recordAudioGranted){throw 'RECORD_AUDIO is not granted on both handsets'}

  foreach($serial in @($deviceA,$deviceB)){$null=Invoke-Adb $adb @('-s',$serial,'shell','am','force-stop',$package)}
  $null=Invoke-Adb $adb @('-s',$deviceA,'shell','am','start','-W','-n',$component)
  $null=Invoke-Adb $adb @('-s',$deviceB,'shell','am','start','-W','-n',$component)
  Start-Sleep -Seconds 8
  $pidA=Get-Pid $adb $deviceA;$pidB=Get-Pid $adb $deviceB
  $result.deviceA.pid=$pidA;$result.deviceB.pid=$pidB
  if([string]::IsNullOrWhiteSpace($pidA) -or [string]::IsNullOrWhiteSpace($pidB)){throw "FamilyPTT process missing after launch A=$pidA B=$pidB"}

  $result.ok=$true;$result.status='completed';$result.classification='PHASE1_APK_INSTALLED_BOTH_HANDSETS_BASELINE_PTT_PENDING';$result.finishedAt=(Get-Date -Format o)
  Save-Result $result;$mirrored=Mirror-Result $result;Log "PASS job=$job A=$deviceA B=$deviceB pidA=$pidA pidB=$pidB sha=$actual mirrored=$mirrored";exit 0
}catch{
  $result.ok=$false;$result.status='failed';$result.classification='PHASE1_APK_PREP_FAILED';$result.error=$_.Exception.Message;$result.finishedAt=(Get-Date -Format o)
  Save-Result $result;$mirrored=Mirror-Result $result;Log "FAIL job=$job error=$($result.error) mirrored=$mirrored";exit 40
}
