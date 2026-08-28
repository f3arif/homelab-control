#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$ProfileRoot='C:\AFZ\MarketplaceBrowserProfile',
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

$py=Get-Command python.exe -ErrorAction SilentlyContinue
$pyArgsPrefix=@()
if(-not $py){
  $py=Get-Command py.exe -ErrorAction SilentlyContinue
  if($py){$pyArgsPrefix=@('-3')}
}
if(-not $py){throw 'Python is not available on windows-main.'}

# Confirm Playwright is importable before requesting any credential input.
$checkArgs=@($pyArgsPrefix)+@('-c','import playwright')
& $py.Source @checkArgs *> $null
if($LASTEXITCODE -ne 0){throw 'Python Playwright is not installed for this user context.'}

$cdp="http://127.0.0.1:$DebugPort"
$browserUp=$false
try{
  $r=Invoke-WebRequest -Uri "$cdp/json/version" -UseBasicParsing -TimeoutSec 2
  $browserUp=($r.StatusCode -eq 200)
}catch{}
if(-not $browserUp){
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -ProfileRoot $ProfileRoot -DebugPort $DebugPort | Out-Null
  $deadline=(Get-Date).AddSeconds(15)
  do{
    Start-Sleep -Milliseconds 500
    try{
      $r=Invoke-WebRequest -Uri "$cdp/json/version" -UseBasicParsing -TimeoutSec 2
      $browserUp=($r.StatusCode -eq 200)
    }catch{}
  }until($browserUp -or (Get-Date) -gt $deadline)
}
if(-not $browserUp){throw "Dedicated Marketplace browser did not expose local CDP at $cdp"}

Write-Host 'Marketplace credential entry is LOCAL to windows-main.'
Write-Host 'Nothing entered here is written to GitHub, OneDrive, logs, command-line arguments, or environment variables.'
$username=Read-Host 'Facebook email / username'
if([string]::IsNullOrWhiteSpace($username)){throw 'Facebook email / username is required.'}
$secure=Read-Host 'Facebook password' -AsSecureString
if(-not $secure -or $secure.Length -eq 0){throw 'Facebook password is required.'}

$bstr=[IntPtr]::Zero
$plain=$null
$payload=$null
try{
  $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  $payload=@{username=$username;password=$plain}|ConvertTo-Json -Compress

  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName=$py.Source
  $quotedHelper='"'+($loginHelper.Replace('"','\"'))+'"'
  $prefix=if($pyArgsPrefix.Count){($pyArgsPrefix -join ' ')+' '}else{''}
  $psi.Arguments=$prefix+$quotedHelper+' --cdp "'+$cdp+'"'
  $psi.UseShellExecute=$false
  $psi.CreateNoWindow=$true
  $psi.RedirectStandardInput=$true
  $psi.RedirectStandardOutput=$true
  $psi.RedirectStandardError=$true

  $proc=New-Object Diagnostics.Process
  $proc.StartInfo=$psi
  if(-not $proc.Start()){throw 'Failed to start Marketplace authentication helper.'}
  $proc.StandardInput.WriteLine($payload)
  $proc.StandardInput.Close()

  # Clear local plaintext variables immediately after stdin is handed to the child process.
  $payload=$null
  $plain=$null
  $username=$null
  $secure=$null
  if($bstr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr);$bstr=[IntPtr]::Zero}

  $stdout=$proc.StandardOutput.ReadToEnd()
  $stderr=$proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  if($stdout){$stdout.Trim()|Write-Output}
  if($proc.ExitCode -eq 2){
    Write-Warning 'Facebook requires an interactive verification step (for example 2FA/checkpoint/CAPTCHA). The helper stopped without attempting to bypass it.'
    exit 2
  }
  if($proc.ExitCode -ne 0){
    if($stderr){Write-Error $stderr.Trim()}else{Write-Error "Marketplace authentication helper exited $($proc.ExitCode)"}
    exit $proc.ExitCode
  }
}finally{
  $payload=$null;$plain=$null;$username=$null;$secure=$null
  if($bstr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
}
