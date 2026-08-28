#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$ProfileRoot='C:\AFZ\MarketplaceBrowserProfile',
  [string]$RuntimeRoot='C:\AFZ\MarketplaceManager',
  [int]$DebugPort=9222
)
$ErrorActionPreference='Stop'

if($DebugPort -lt 1024 -or $DebugPort -gt 65535){throw 'DebugPort out of range'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
if($identity -match '\\SYSTEM$'){throw 'Marketplace SSH login must run as the user account, not SYSTEM.'}

$marketRoot=Join-Path $InstallRoot 'afz-openai-agent\marketplace'
$launcher=Join-Path $marketRoot 'Start-Marketplace-ReadOnly-Browser.ps1'
$loginHelper=Join-Path $marketRoot 'marketplace_browser_login.py'
if(-not(Test-Path -LiteralPath $launcher)){throw "Marketplace browser launcher missing: $launcher"}
if(-not(Test-Path -LiteralPath $loginHelper)){throw "Marketplace login helper missing: $loginHelper"}

function Invoke-NativeCaptured([string]$File,[string[]]$Arguments){
  $old=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    $out=@(& $File @Arguments 2>&1)
    $code=$LASTEXITCODE
  }finally{$ErrorActionPreference=$old}
  [pscustomobject]@{ExitCode=$code;Text=([string]($out -join "`n"))}
}

$basePy=Get-Command python.exe -ErrorAction SilentlyContinue
$basePrefix=@()
if(-not $basePy){
  $basePy=Get-Command py.exe -ErrorAction SilentlyContinue
  if($basePy){$basePrefix=@('-3')}
}
if(-not $basePy){throw 'Python is not available on windows-main.'}
$basePyPath=if($basePy.Source){[string]$basePy.Source}else{[string]$basePy.Path}

$venvRoot=Join-Path $RuntimeRoot 'venv'
$venvPy=Join-Path $venvRoot 'Scripts\python.exe'
if(-not(Test-Path -LiteralPath $venvPy -PathType Leaf)){
  New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
  Write-Host 'Preparing isolated Marketplace Python environment...'
  $mkArgs=@($basePrefix)+@('-m','venv',$venvRoot)
  $mk=Invoke-NativeCaptured $basePyPath $mkArgs
  if($mk.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $venvPy -PathType Leaf)){
    throw "Could not create Marketplace Python environment. $($mk.Text.Trim())"
  }
}

$check=Invoke-NativeCaptured $venvPy @('-c','import playwright')
if($check.ExitCode -ne 0){
  Write-Host 'Installing Playwright into the isolated Marketplace environment...'
  $install=Invoke-NativeCaptured $venvPy @('-m','pip','install','--disable-pip-version-check','playwright>=1.48,<2')
  if($install.ExitCode -ne 0){
    throw "Could not install Playwright in the Marketplace environment. $($install.Text.Trim())"
  }
  $check=Invoke-NativeCaptured $venvPy @('-c','import playwright')
  if($check.ExitCode -ne 0){throw 'Playwright installation completed but the import check still failed.'}
}

$cdp="http://127.0.0.1:$DebugPort"
$browserUp=$false
try{
  $r=Invoke-WebRequest -Uri "$cdp/json/version" -UseBasicParsing -TimeoutSec 2
  $browserUp=($r.StatusCode -eq 200)
}catch{}
if(-not $browserUp){
  $launcherArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$launcher,'-ProfileRoot',$ProfileRoot,'-DebugPort',[string]$DebugPort)
  if(-not [string]::IsNullOrWhiteSpace($env:SSH_CONNECTION)){$launcherArgs += '-Headless'}
  $launch=Invoke-NativeCaptured 'powershell.exe' $launcherArgs
  if($launch.ExitCode -ne 0){throw "Dedicated Marketplace browser launch failed. $($launch.Text.Trim())"}
  $deadline=(Get-Date).AddSeconds(20)
  do{
    Start-Sleep -Milliseconds 500
    try{
      $r=Invoke-WebRequest -Uri "$cdp/json/version" -UseBasicParsing -TimeoutSec 2
      $browserUp=($r.StatusCode -eq 200)
    }catch{}
  }until($browserUp -or (Get-Date) -gt $deadline)
}
if(-not $browserUp){throw "Dedicated Marketplace browser did not expose local CDP at $cdp"}

function Invoke-MarketplaceAuthHelper {
  param(
    [Parameter(Mandatory=$true)][string]$Payload,
    [switch]$VerifyCode
  )
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName=$venvPy
  $quotedHelper='"'+($loginHelper.Replace('"','\"'))+'"'
  $psi.Arguments=$quotedHelper+' --cdp "'+$cdp+'"'+$(if($VerifyCode){' --verify-code'}else{''})
  $psi.UseShellExecute=$false
  $psi.CreateNoWindow=$true
  $psi.RedirectStandardInput=$true
  $psi.RedirectStandardOutput=$true
  $psi.RedirectStandardError=$true

  $proc=New-Object Diagnostics.Process
  $proc.StartInfo=$psi
  if(-not $proc.Start()){throw 'Failed to start Marketplace authentication helper.'}
  try{
    $proc.StandardInput.WriteLine($Payload)
    $proc.StandardInput.Close()
    $stdout=$proc.StandardOutput.ReadToEnd()
    $stderr=$proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    [pscustomobject]@{ExitCode=[int]$proc.ExitCode;StdOut=[string]$stdout;StdErr=[string]$stderr}
  }finally{
    $Payload=$null
    $proc.Dispose()
  }
}

function Convert-SecureToPlain([Security.SecureString]$SecureValue){
  $ptr=[IntPtr]::Zero
  try{
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
  }finally{
    if($ptr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
  }
}

function Parse-HelperJson([string]$Text){
  if([string]::IsNullOrWhiteSpace($Text)){return $null}
  $candidate=($Text -split '\r?\n' | Where-Object {$_.Trim().StartsWith('{')} | Select-Object -Last 1)
  if(-not $candidate){return $null}
  try{return ($candidate|ConvertFrom-Json)}catch{return $null}
}

Write-Host 'Marketplace credential entry is LOCAL to windows-main.'
Write-Host 'Nothing entered here is written to GitHub, OneDrive, logs, command-line arguments, or environment variables.'
$username=Read-Host 'Facebook email / username'
if([string]::IsNullOrWhiteSpace($username)){throw 'Facebook email / username is required.'}
$secure=Read-Host 'Facebook password' -AsSecureString
if(-not $secure -or $secure.Length -eq 0){throw 'Facebook password is required.'}

$plain=$null
$payload=$null
try{
  $plain=Convert-SecureToPlain $secure
  $payload=@{username=$username;password=$plain}|ConvertTo-Json -Compress
  $first=Invoke-MarketplaceAuthHelper -Payload $payload
}finally{
  $payload=$null;$plain=$null;$username=$null;$secure=$null
}

if($first.StdOut){$first.StdOut.Trim()|Write-Output}
$firstJson=Parse-HelperJson $first.StdOut
if($first.ExitCode -eq 0){return}
if($first.ExitCode -ne 2){
  $safeError=if($first.StdErr){$first.StdErr.Trim()}else{"Marketplace authentication helper exited $($first.ExitCode)"}
  throw $safeError
}

if($firstJson -and [string]$firstJson.status -eq 'otp_required'){
  Write-Host 'Facebook requested a one-time verification code. Enter the code from your authenticator/SMS/email.'
  $secureCode=Read-Host 'Facebook verification code' -AsSecureString
  if(-not $secureCode -or $secureCode.Length -eq 0){throw 'Facebook verification code is required.'}
  $plainCode=$null
  $codePayload=$null
  try{
    $plainCode=Convert-SecureToPlain $secureCode
    $codePayload=@{code=$plainCode}|ConvertTo-Json -Compress
    $second=Invoke-MarketplaceAuthHelper -Payload $codePayload -VerifyCode
  }finally{
    $codePayload=$null;$plainCode=$null;$secureCode=$null
  }

  if($second.StdOut){$second.StdOut.Trim()|Write-Output}
  $secondJson=Parse-HelperJson $second.StdOut
  if($second.ExitCode -eq 0){return}
  if($second.ExitCode -ne 2){
    $safeError=if($second.StdErr){$second.StdErr.Trim()}else{"Marketplace verification helper exited $($second.ExitCode)"}
    throw $safeError
  }
  if($secondJson -and [string]$secondJson.status -eq 'otp_required'){
    Write-Warning 'Facebook still requires a one-time code. The submitted code may have expired/been rejected, or Facebook requested another code. Re-run the SSH login to try again.'
    exit 2
  }
  Write-Warning 'Facebook requires a manual verification step (for example CAPTCHA, identity review, checkpoint, or approval from another device). The helper stopped without attempting to bypass it.'
  exit 2
}

Write-Warning 'Facebook requires a manual verification step (for example CAPTCHA, identity review, checkpoint, or approval from another device). The helper stopped without attempting to bypass it.'
exit 2
