#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# AFZ_FAMILYPTT_PHASE1_EXACT_APK_PREP_V1
# This helper is intentionally NOT wired to a watcher by this change.
# It performs no work unless an exact request is explicitly status=active.
$ExpectedRepo='f3arif/FamilyPTT'
$ExpectedRunId=33325967023
$ExpectedArtifact='FamilyPTT-standalone-release-apk-arm64'
$ExpectedApkSha256='4bc8ceafe13ea42eb68cf0f682dec5dbbab9980510d642993453e8e788e9117b'
$ExpectedPackage='ca.afzeng.familyptt'
$ExpectedDeviceA='19161FDEE008XN'
$ExpectedDeviceB='192.168.50.69:38209'
$ExpectedAction='prepare-phase1-acceptance-apk'
$StateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\familyptt-phase1-apk-prepare'
$StateFile=Join-Path $StateRoot 'latest.json'
if([string]::IsNullOrWhiteSpace($RequestPath)){
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\familyptt-phase1-apk-prepare.json'
}
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

function Emit($Object,[int]$Code=0){
  $Object | ConvertTo-Json -Depth 12 -Compress
  exit $Code
}
function Save-State([string]$JobId,[string]$Status,[string]$Message,$Details=$null){
  $state=[ordered]@{
    schema='afz.familyptt.phase1-apk-prepare.v1'
    ok=($Status -eq 'completed')
    jobId=$JobId
    status=$Status
    message=$Message
    runId=$ExpectedRunId
    artifact=$ExpectedArtifact
    apkSha256=$ExpectedApkSha256
    package=$ExpectedPackage
    deviceA=$ExpectedDeviceA
    deviceB=$ExpectedDeviceB
    details=$Details
    updatedAt=(Get-Date -Format o)
  }
  $state|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $StateFile -Encoding UTF8
  return $state
}
function Resolve-Command([string[]]$Names){
  foreach($name in $Names){
    $c=Get-Command $name -ErrorAction SilentlyContinue
    if($c){return $c.Source}
  }
  return $null
}
function Invoke-Native([string]$File,[string[]]$Arguments,[int]$TimeoutSeconds=120){
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName=$File
  $psi.UseShellExecute=$false
  $psi.CreateNoWindow=$true
  $psi.RedirectStandardOutput=$true
  $psi.RedirectStandardError=$true
  foreach($a in $Arguments){[void]$psi.ArgumentList.Add($a)}
  $p=New-Object Diagnostics.Process
  $p.StartInfo=$psi
  if(-not $p.Start()){throw "Failed to start native process: $File"}
  $stdoutTask=$p.StandardOutput.ReadToEndAsync();$stderrTask=$p.StandardError.ReadToEndAsync()
  if(-not $p.WaitForExit($TimeoutSeconds*1000)){
    try{$p.Kill()}catch{}
    throw "Native process timed out after ${TimeoutSeconds}s: $File"
  }
  $stdout=$stdoutTask.Result;$stderr=$stderrTask.Result;$code=$p.ExitCode
  $p.Dispose()
  return [ordered]@{exit=$code;stdout=$stdout;stderr=$stderr}
}
function Get-AuthorizedDevices([string]$Adb){
  $r=Invoke-Native $Adb @('devices') 30
  if($r.exit -ne 0){throw "adb devices failed: $($r.stderr)"}
  $devices=@()
  foreach($line in @($r.stdout -split "`r?`n")){
    if($line -match '^([^\s]+)\s+device$'){$devices+=$Matches[1]}
  }
  return @($devices|Sort-Object -Unique)
}
function Assert-ExpectedDevices([string]$Adb){
  $devices=Get-AuthorizedDevices $Adb
  if($devices -notcontains $ExpectedDeviceA -or $devices -notcontains $ExpectedDeviceB){
    throw "WAIT_TWO_EXPECTED_HANDSETS authorized=$($devices -join ',')"
  }
  return $devices
}
function Invoke-Adb([string]$Adb,[string]$Serial,[string[]]$Arguments,[int]$TimeoutSeconds=120){
  $args=@('-s',$Serial)+$Arguments
  $r=Invoke-Native $Adb $args $TimeoutSeconds
  if($r.exit -ne 0){throw "adb $Serial $($Arguments -join ' ') failed exit=$($r.exit): $($r.stderr) $($r.stdout)"}
  return $r
}
function Find-Aapt {
  $sdk=$(if($env:ANDROID_HOME){$env:ANDROID_HOME}elseif($env:ANDROID_SDK_ROOT){$env:ANDROID_SDK_ROOT}else{Join-Path $env:LOCALAPPDATA 'Android\Sdk'})
  if(-not(Test-Path -LiteralPath $sdk -PathType Container)){return $null}
  $tools=@(Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Filter aapt.exe -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
  if($tools.Count -gt 0){return $tools[0].FullName}
  return $null
}

$jobId=''
$temp=$null
try{
  if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){Emit ([ordered]@{ok=$true;status='no-request'}) 0}
  $req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
  if([int]$req.schema -ne 1 -or [string]$req.project -ne 'familyptt' -or [string]$req.action -ne $ExpectedAction){throw 'Invalid FamilyPTT Phase 1 request contract.'}
  $jobId=[string]$req.job_id
  if($jobId -notmatch '^familyptt-phase1-apk-prepare-[A-Za-z0-9._-]{3,80}$'){throw 'Invalid FamilyPTT Phase 1 job_id.'}
  if([string]$req.repository -ne $ExpectedRepo -or [int64]$req.workflow_run_id -ne $ExpectedRunId -or [string]$req.artifact_name -ne $ExpectedArtifact){throw 'Request artifact identity does not match the pinned build.'}
  if(([string]$req.apk_sha256).ToLowerInvariant() -ne $ExpectedApkSha256 -or [string]$req.package_id -ne $ExpectedPackage){throw 'Request APK identity does not match the pinned build.'}
  if([string]$req.device_a -ne $ExpectedDeviceA -or [string]$req.device_b -ne $ExpectedDeviceB){throw 'Request handset identity does not match the pinned pair.'}
  $status=[string]$req.status
  if($status -eq 'staged-not-active'){
    Emit ([ordered]@{ok=$true;status='staged-not-active';jobId=$jobId;mutated=$false}) 0
  }
  if($status -ne 'active'){throw "Unsupported request status: $status"}

  $prior=$null
  if(Test-Path -LiteralPath $StateFile -PathType Leaf){try{$prior=Get-Content -LiteralPath $StateFile -Raw|ConvertFrom-Json}catch{}}
  if($prior -and [string]$prior.jobId -eq $jobId -and [string]$prior.status -eq 'completed'){Emit $prior 0}

  $gh=Resolve-Command @('gh.exe','gh')
  $adb=Resolve-Command @('adb.exe','adb')
  if(-not $gh){throw 'GitHub CLI is unavailable.'}
  if(-not $adb){throw 'ADB is unavailable.'}

  # Critical precondition: both exact authorized devices must exist before artifact
  # download and again immediately before the first install. This helper never
  # toggles Wi-Fi/mobile data, clears app data, uninstalls apps, or changes backend.
  $beforeDevices=Assert-ExpectedDevices $adb
  [void](Save-State $jobId 'running' 'Exact devices present; downloading pinned APK artifact.' ([ordered]@{authorizedDevices=$beforeDevices}))

  $temp=Join-Path $env:TEMP ('AFZ-FamilyPTT-Phase1-'+[guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $temp|Out-Null
  $download=Invoke-Native $gh @('run','download',[string]$ExpectedRunId,'--repo',$ExpectedRepo,'--name',$ExpectedArtifact,'--dir',$temp) 180
  if($download.exit -ne 0){throw "Pinned artifact download failed: $($download.stderr)"}
  $apks=@(Get-ChildItem -LiteralPath $temp -Recurse -File -Filter '*.apk')
  if($apks.Count -ne 1){throw "Expected exactly one APK in pinned artifact; found $($apks.Count)."}
  $apk=$apks[0].FullName
  $actualHash=(Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
  if($actualHash -ne $ExpectedApkSha256){throw "APK SHA-256 mismatch: $actualHash"}

  $aapt=Find-Aapt
  if($aapt){
    $badge=Invoke-Native $aapt @('dump','badging',$apk) 60
    if($badge.exit -ne 0 -or $badge.stdout -notmatch ("package: name='"+[regex]::Escape($ExpectedPackage)+"'")){throw 'APK package ID verification failed.'}
  }

  $preInstallDevices=Assert-ExpectedDevices $adb
  $installA=Invoke-Adb $adb $ExpectedDeviceA @('install','-r',$apk) 180
  $installB=Invoke-Adb $adb $ExpectedDeviceB @('install','-r',$apk) 180
  foreach($serial in @($ExpectedDeviceA,$ExpectedDeviceB)){
    [void](Invoke-Adb $adb $serial @('shell','pm','grant',$ExpectedPackage,'android.permission.RECORD_AUDIO') 30)
    [void](Invoke-Adb $adb $serial @('shell','am','force-stop',$ExpectedPackage) 30)
    [void](Invoke-Adb $adb $serial @('shell','monkey','-p',$ExpectedPackage,'-c','android.intent.category.LAUNCHER','1') 45)
  }
  Start-Sleep -Seconds 3
  $pidA=(Invoke-Adb $adb $ExpectedDeviceA @('shell','pidof',$ExpectedPackage) 30).stdout.Trim()
  $pidB=(Invoke-Adb $adb $ExpectedDeviceB @('shell','pidof',$ExpectedPackage) 30).stdout.Trim()
  if(-not $pidA -or -not $pidB){throw "FamilyPTT did not remain running on both phones after install. pidA=$pidA pidB=$pidB"}

  $details=[ordered]@{
    authorizedDevices=$preInstallDevices
    artifactVerified=$true
    apkSha256=$actualHash
    packageVerified=([bool]$aapt)
    installA=($installA.stdout.Trim())
    installB=($installB.stdout.Trim())
    pidA=$pidA
    pidB=$pidB
    networkStateChanged=$false
    appDataCleared=$false
    uninstallUsed=$false
  }
  $done=Save-State $jobId 'completed' 'Pinned Phase 1 APK installed and launched on both exact handsets; physical failover acceptance remains manual/staged.' $details
  Emit $done 0
}catch{
  $msg=$_.Exception.Message
  $failed=Save-State $jobId 'failed' $msg
  Emit $failed 1
}finally{
  if($temp -and (Test-Path -LiteralPath $temp)){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
}
