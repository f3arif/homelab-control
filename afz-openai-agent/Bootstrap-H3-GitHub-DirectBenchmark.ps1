#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$ExpectedSha,
  [string]$InstallRoot='C:\AFZ\homelab-control'
)
$ErrorActionPreference='Stop'
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha required'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()
# Trusted exact-SHA entrypoint for DESKTOP-H3R6CQN (Faiz@100.106.186.118).
# Return-only recovery: this script never launches Qwen or creates a benchmark iteration.
$key='C:\Users\Faiz\.ssh\afz_h3_worker'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$h3='Faiz@100.106.186.118'
$faiz='DESKTOP-10SKF0M\Faiz'
if(-not(Test-Path $key)){throw "H3 SSH key missing: $key"}
if(-not(Test-Path $known)){throw "H3 known-hosts file missing: $known"}

# Restore the last known-good Windows OpenSSH ACL. Do not bind the key to the
# transient bootstrap identity: the request watcher may run under SYSTEM while
# the key is owned/used by Faiz. This exact ACL was previously verified with a
# successful public-key SSH login to DESKTOP-H3R6CQN.
$icacls=(Get-Command icacls.exe -ErrorAction Stop).Source
& $icacls $key '/inheritance:r' | Out-Null
if($LASTEXITCODE -ne 0){throw "Failed to disable inheritance on H3 SSH key; exit=$LASTEXITCODE"}
& $icacls $key '/grant:r' "${faiz}:(M)" 'NT AUTHORITY\SYSTEM:(F)' 'BUILTIN\Administrators:(F)' | Out-Null
if($LASTEXITCODE -ne 0){throw "Failed to restore H3 SSH key ACL; exit=$LASTEXITCODE"}
& $icacls $key '/setowner' $faiz | Out-Null
if($LASTEXITCODE -ne 0){throw "Failed to restore H3 SSH key owner; exit=$LASTEXITCODE"}

# Prove the repaired key without allowing Windows PowerShell to promote benign
# native stderr into a terminating NativeCommandError. Capture both streams and
# decide success only from the real ssh.exe exit code plus expected hostname.
$ssh=(Get-Command ssh.exe -ErrorAction Stop).Source
$probeOut=Join-Path $env:TEMP ('AFZ-H3-SSH-Probe-Out-'+[guid]::NewGuid().ToString('n')+'.txt')
$probeErr=Join-Path $env:TEMP ('AFZ-H3-SSH-Probe-Err-'+[guid]::NewGuid().ToString('n')+'.txt')
try{
  $probeArgs=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',("UserKnownHostsFile="+$known),$h3,'hostname')
  $p=Start-Process -FilePath $ssh -ArgumentList $probeArgs -RedirectStandardOutput $probeOut -RedirectStandardError $probeErr -PassThru -NoNewWindow
  if(-not $p.WaitForExit(20000)){
    try{$p.Kill()}catch{}
    try{$p.WaitForExit()}catch{}
    throw 'H3 SSH preflight timed out after 20 seconds'
  }
  $p.WaitForExit()
  $probeExit=[int]$p.ExitCode
  $probeStdout=$(if(Test-Path -LiteralPath $probeOut){[IO.File]::ReadAllText($probeOut).Trim()}else{''})
  $probeStderr=$(if(Test-Path -LiteralPath $probeErr){[IO.File]::ReadAllText($probeErr).Trim()}else{''})
  if($probeExit -ne 0){throw "H3 SSH preflight failed after ACL restore: exit=$probeExit stdout=$probeStdout stderr=$probeStderr"}
  if($probeStdout -notmatch 'DESKTOP-H3R6CQN'){throw "H3 SSH preflight reached unexpected host: stdout=$probeStdout stderr=$probeStderr"}
}finally{
  Remove-Item -LiteralPath $probeOut,$probeErr -Force -ErrorAction SilentlyContinue
}

$uri="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/Bootstrap-H3-GitHub-DirectReturnV4.ps1"
$tmp=Join-Path $env:TEMP ('AFZ-H3-ReturnV4-'+$ExpectedSha+'.ps1')
try{
  Invoke-WebRequest -Uri $uri -OutFile $tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-ExactSha-ReturnV4'} -TimeoutSec 60
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)
  if($errors.Count -gt 0){throw ('Return V4 bootstrap parse failure: '+($errors.Message -join '; '))}
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp -ExpectedSha $ExpectedSha -InstallRoot $InstallRoot
  exit $LASTEXITCODE
}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
