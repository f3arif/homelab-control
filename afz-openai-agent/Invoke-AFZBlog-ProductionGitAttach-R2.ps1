#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('audit','apply')][string]$Action='audit',
  [string]$RequestId='afz-blog-production-git-attach-r2',
  [string]$ExpectedBlogSha='a37e71aa0e0c9fad41ecdc9652a7024c485666f4'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$source=Join-Path $PSScriptRoot 'Invoke-AFZBlog-ProductionGitAttach.ps1'
if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "Canonical production runner missing: $source"}
$text=[IO.File]::ReadAllText($source)
$oldSignature='function Run-Git([string[]]$Args,[switch]$AllowFailure){'
$newSignature='function Run-Git([string[]]$ArgumentVector,[switch]$AllowFailure){'
$oldSplat='& git @Args 2>&1'
$newSplat='& git @ArgumentVector 2>&1'
if(([regex]::Matches($text,[regex]::Escape($oldSignature))).Count -ne 1){throw 'Unexpected canonical Run-Git signature count'}
if(([regex]::Matches($text,[regex]::Escape($oldSplat))).Count -ne 1){throw 'Unexpected canonical git splat count'}
$patched=$text.Replace($oldSignature,$newSignature).Replace($oldSplat,$newSplat)
$temp=Join-Path $env:TEMP ('Invoke-AFZBlog-ProductionGitAttach-R2-'+[guid]::NewGuid().ToString('n')+'.ps1')
try{
  [IO.File]::WriteAllText($temp,$patched,(New-Object Text.UTF8Encoding($false)))
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $temp -Action $Action -RequestId $RequestId -ExpectedBlogSha $ExpectedBlogSha
  exit $LASTEXITCODE
}finally{
  Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
