#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$ExpectedSha,
  [string]$InstallRoot='C:\AFZ\homelab-control'
)
$ErrorActionPreference='Stop'
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha required'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()

# Compatibility shim only. The old V3 implementation directly registered an
# Interactive powershell.exe Scheduled Task and could recreate a visible console
# flash. All callers are now delegated to the V4 no-window installer so there is
# only one supported registration path.
$v4=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-H3-GitHub-DirectReturnV4.ps1'
if(-not(Test-Path -LiteralPath $v4 -PathType Leaf)){
  $uri="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/Bootstrap-H3-GitHub-DirectReturnV4.ps1"
  $tmp=Join-Path $env:TEMP ('AFZ-H3-ReturnV4-Compat-'+[guid]::NewGuid().ToString('n')+'.ps1')
  try{
    Invoke-WebRequest -Uri $uri -OutFile $tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-Return-V3-Compat'} -TimeoutSec 60
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)
    if($errors.Count -gt 0){throw ('Downloaded V4 parse failure: '+($errors.Message -join '; '))}
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $tmp -ExpectedSha $ExpectedSha -InstallRoot $InstallRoot
    exit $LASTEXITCODE
  }finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
}
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $v4 -ExpectedSha $ExpectedSha -InstallRoot $InstallRoot
exit $LASTEXITCODE
