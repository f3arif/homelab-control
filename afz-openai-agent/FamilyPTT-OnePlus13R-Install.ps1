#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath='',
  [string]$ResultPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\familyptt-oneplus13r-install\latest.json'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$package='ca.afzeng.familyptt'
$component='ca.afzeng.familyptt/.MainActivity'
$expectedSha='ec9a0db9534abfbf54e90e3ada47c9b298b4c1c608e483d5b465632bd71a8ff1'
$expectedFile='FamilyPTT-standalone-arm64-pr14-lanfix.apk'
$bridgeRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$apkPath=Join-Path $bridgeRoot $expectedFile
$diagPath=Join-Path $bridgeRoot 'FAMILYPTT-ONEPLUS13R-INSTALL-LATEST.txt'
if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\familyptt-oneplus13r-install.json'}
$stateRoot=Split-Path -Parent $ResultPath
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Read-Json([string]$p){
  if(-not(Test-Path -LiteralPath $p -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}
}
function Save($o){
  $o|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $ResultPath -Encoding UTF8
  try{if(Test-Path -LiteralPath $bridgeRoot -PathType Container){$o|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $diagPath -Encoding UTF8}}catch{}
}
function Find-Adb{
  $c=Get-Command adb.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Users\Faiz\AppData\Local\Android\Sdk\platform-tools\adb.exe','C:\Android\platform-tools\adb.exe')){if(Test-Path -LiteralPath $p -PathType Leaf){return $p}}
  return $null
}
function Invoke-Adb([string]$adb,[string[]]$args,[switch]$AllowFailure){
  $old=$ErrorActionPreference
  try{$ErrorActionPreference='Continue';$raw=@(& $adb @args 2>&1);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
  $out=@($raw|ForEach-Object{[string]$_})
  if(-not $AllowFailure -and $code -ne 0){throw "adb failed exit=$code args=$($args -join ' ') output=$($out -join ' | ')"}
  [pscustomobject]@{exitCode=$code;output=$out}
}
function Invoke-AdbTimed([string]$adb,[string[]]$args,[int]$seconds=180){
  $out=Join-Path $env:TEMP ('oneplus-adb-out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $err=Join-Path $env:TEMP ('oneplus-adb-err-'+[guid]::NewGuid().ToString('n')+'.txt')
  $argLine=(($args|ForEach-Object{if(([string]$_) -match '\s'){ '"'+[string]$_+'"' }else{[string]$_}}) -join ' ')
  try{
    $p=Start-Process -FilePath $adb -ArgumentList $argLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
    if(-not $p.WaitForExit($seconds*1000)){try{Stop-Process -Id $p.Id -Force}catch{};throw "adb timed out after ${seconds}s"}
    $stdout=$(if(Test-Path $out){Get-Content -LiteralPath $out -Raw}else{''})
    $stderr=$(if(Test-Path $err){Get-Content -LiteralPath $err -Raw}else{''})
    $text=(($stdout+"`n"+$stderr).Trim())
    if($p.ExitCode -ne 0){throw "adb failed exit=$($p.ExitCode) output=$text"}
    [pscustomobject]@{exitCode=$p.ExitCode;output=@($text)}
  }finally{Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue}
}
function Get-Prop([string]$adb,[string]$serial,[string]$prop){
  $r=Invoke-Adb $adb @('-s',$serial,'shell','getprop',$prop) -AllowFailure
  return (($r.output -join '').Trim())
}

$req=Read-Json $RequestPath
if(-not $req){exit 0}
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'familyptt' -or [string]$req.action -ne 'install-oneplus13r'){exit 0}
if([string]$req.status -ne 'active'){exit 0}
if([string]$req.apk_sha256 -ne $expectedSha){throw 'OnePlus request APK SHA does not match the pinned PR14 LAN-fix APK'}
if([string]$req.apk_file -ne $expectedFile){throw 'OnePlus request APK filename does not match the pinned PR14 LAN-fix APK'}
if([string]$req.package_id -ne $package){throw 'Unexpected package id in OnePlus request'}

$job=[string]$req.job_id
$prior=Read-Json $ResultPath
if($prior -and [string]$prior.jobId -eq $job -and [string]$prior.status -eq 'completed'){Save $prior;exit 0}

$result=[ordered]@{schema=1;jobId=$job;status='running';ok=$false;classification='ONEPLUS13R_INSTALL_RUNNING';startedAt=(Get-Date -Format o);finishedAt=$null;apkFile=$expectedFile;apkSha256=$null;device=$null;installResult=$null;pid=$null;recordAudioGranted=$false;error=$null}
Save $result
try{
  if(-not(Test-Path -LiteralPath $apkPath -PathType Leaf)){throw "validated PR14 LAN-fix APK is not staged on windows-main: $apkPath"}
  $sha=(Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant();$result.apkSha256=$sha;Save $result
  if($sha -ne $expectedSha){throw "APK SHA mismatch: $sha"}

  $env:USERPROFILE='C:\Users\Faiz';$env:HOME='C:\Users\Faiz';$env:ANDROID_USER_HOME='C:\Users\Faiz'
  if(Test-Path -LiteralPath 'C:\Users\Faiz\.android\adbkey'){$env:ADB_VENDOR_KEYS='C:\Users\Faiz\.android\adbkey'}
  $adb=Find-Adb;if(-not $adb){throw 'adb.exe not found'}
  $devices=Invoke-Adb $adb @('devices')
  $serials=@($devices.output|ForEach-Object{if(([string]$_) -match '^([^\s]+)\s+device(?:\s|$)'){$Matches[1]}}|Where-Object{$_})
  $matches=@()
  foreach($s in $serials){
    $m=Get-Prop $adb $s 'ro.product.manufacturer';$brand=Get-Prop $adb $s 'ro.product.brand';$model=Get-Prop $adb $s 'ro.product.model';$device=Get-Prop $adb $s 'ro.product.device'
    if($m -match '(?i)oneplus' -or $brand -match '(?i)oneplus'){$matches+=[pscustomobject]@{serial=$s;manufacturer=$m;brand=$brand;model=$model;device=$device}}
  }
  if($matches.Count -eq 0){$result.classification='ONEPLUS13R_ADB_NOT_CONNECTED';throw 'No authorized OnePlus device is visible to ADB'}
  if($matches.Count -gt 1){$result.classification='ONEPLUS13R_ADB_AMBIGUOUS';throw 'More than one OnePlus device is visible to ADB'}
  $target=$matches[0];$result.device=$target;Save $result

  # This ASUS adb build rejects --no-streaming. The proven local path is plain install -r.
  $install=Invoke-AdbTimed $adb @('-s',$target.serial,'install','-r',$apkPath) 180
  $text=($install.output -join ' ').Trim();$result.installResult=$text;Save $result
  if($text -notmatch '(?i)Success'){throw "install did not report Success: $text"}

  $null=Invoke-Adb $adb @('-s',$target.serial,'shell','pm','grant',$package,'android.permission.RECORD_AUDIO') -AllowFailure
  $perm=Invoke-Adb $adb @('-s',$target.serial,'shell','dumpsys','package',$package) -AllowFailure
  $result.recordAudioGranted=(($perm.output -join "`n") -match 'android\.permission\.RECORD_AUDIO:\s+granted=true')

  # Restart only the newly installed FamilyPTT process on the selected OnePlus.
  $null=Invoke-Adb $adb @('-s',$target.serial,'shell','am','force-stop',$package)
  $null=Invoke-Adb $adb @('-s',$target.serial,'shell','am','start','-W','-n',$component)
  Start-Sleep -Seconds 7
  $pid=Invoke-Adb $adb @('-s',$target.serial,'shell','pidof',$package) -AllowFailure;$result.pid=(($pid.output -join '').Trim())
  if([string]::IsNullOrWhiteSpace($result.pid)){throw 'FamilyPTT process did not start on OnePlus'}
  if(-not $result.recordAudioGranted){throw 'RECORD_AUDIO is not granted on OnePlus'}

  $result.ok=$true;$result.status='completed';$result.classification='ONEPLUS13R_FAMILYPTT_PR14_LANFIX_INSTALLED_READY';$result.finishedAt=(Get-Date -Format o);Save $result;exit 0
}catch{
  $result.ok=$false;$result.status='failed';if($result.classification -eq 'ONEPLUS13R_INSTALL_RUNNING'){$result.classification='ONEPLUS13R_INSTALL_FAILED'};$result.error=$_.Exception.Message;$result.finishedAt=(Get-Date -Format o);Save $result;exit 40
}
