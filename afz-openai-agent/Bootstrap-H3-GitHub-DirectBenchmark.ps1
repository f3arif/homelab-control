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
# The benchmark job remains qwen3.8:27b / Qwen38-27B-Website-Benchmark-20260826-174739.
# This generation installs the return-only publisher and retires the obsolete raw watcher; it never launches Qwen.
$key='C:\Users\Faiz\.ssh\afz_h3_worker'
if(-not(Test-Path $key)){throw "H3 SSH key missing: $key"}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$acl=Get-Acl -LiteralPath $key
$acl.SetAccessRuleProtection($true,$false)
foreach($r in @($acl.Access)){$acl.RemoveAccessRuleAll($r)}
$readRule=New-Object Security.AccessControl.FileSystemAccessRule($identity,[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow)
$acl.AddAccessRule($readRule)
try{$acl.SetOwner((New-Object Security.Principal.NTAccount($identity)))}catch{}
Set-Acl -LiteralPath $key -AclObject $acl
$uri="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/Bootstrap-H3-GitHub-DirectReturnV3.ps1"
$tmp=Join-Path $env:TEMP ('AFZ-H3-ReturnV3-'+$ExpectedSha+'.ps1')
try{
  Invoke-WebRequest -Uri $uri -OutFile $tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-ExactSha-ReturnV3'} -TimeoutSec 60
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)
  if($errors.Count -gt 0){throw ('Return V3 bootstrap parse failure: '+($errors.Message -join '; '))}
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp -ExpectedSha $ExpectedSha -InstallRoot $InstallRoot
  exit $LASTEXITCODE
}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
