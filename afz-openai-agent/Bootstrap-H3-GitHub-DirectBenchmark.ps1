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
$sourceKey='C:\Users\Faiz\.ssh\afz_h3_worker'
$keyRoot='C:\ProgramData\AFZ\OpenAIAgent\keys'
$key=Join-Path $keyRoot 'afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$h3='Faiz@100.106.186.118'
if(-not(Test-Path -LiteralPath $sourceKey -PathType Leaf)){throw "H3 source SSH key missing: $sourceKey"}
if(-not(Test-Path -LiteralPath $known -PathType Leaf)){throw "H3 known-hosts file missing: $known"}

# OpenSSH rejects the shared user-key ACL when this exact-SHA bootstrap runs as
# NT AUTHORITY\SYSTEM. Create a dedicated local copy for the SYSTEM control
# plane and protect it so only SYSTEM can read it. The user's source key is not
# modified. The copy contains the same private key bytes and never leaves this
# Windows machine.
New-Item -ItemType Directory -Force -Path $keyRoot | Out-Null
Copy-Item -LiteralPath $sourceKey -Destination $key -Force
$systemAccount=New-Object System.Security.Principal.NTAccount('NT AUTHORITY','SYSTEM')
$secureAcl=New-Object System.Security.AccessControl.FileSecurity
$secureAcl.SetOwner($systemAccount)
$secureAcl.SetAccessRuleProtection($true,$false)
$systemRule=New-Object System.Security.AccessControl.FileSystemAccessRule($systemAccount,[System.Security.AccessControl.FileSystemRights]::FullControl,[System.Security.AccessControl.AccessControlType]::Allow)
[void]$secureAcl.AddAccessRule($systemRule)
Set-Acl -LiteralPath $key -AclObject $secureAcl -ErrorAction Stop
$verifiedAcl=Get-Acl -LiteralPath $key -ErrorAction Stop
$unexpectedRules=@($verifiedAcl.Access | Where-Object {[string]$_.IdentityReference -ne 'NT AUTHORITY\SYSTEM'})
if($unexpectedRules.Count -gt 0){throw 'SYSTEM H3 SSH key copy still has non-SYSTEM access rules'}
if(-not $verifiedAcl.AreAccessRulesProtected){throw 'SYSTEM H3 SSH key copy still inherits ACLs'}

# Prove the SYSTEM-only key without allowing Windows PowerShell to promote
# native stderr into a terminating NativeCommandError. Capture both streams and
# decide success from the real ssh.exe exit code plus the expected hostname.
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
  if($probeExit -ne 0){throw "H3 SSH preflight failed with SYSTEM-only key: exit=$probeExit stdout=$probeStdout stderr=$probeStderr"}
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
