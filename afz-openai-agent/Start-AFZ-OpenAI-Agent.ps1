#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$Port=8796,
  [string]$BindHost='100.70.25.8'
)
$ErrorActionPreference='Stop'
$sourceRoot=Join-Path $InstallRoot 'afz-openai-agent'
$src=Join-Path $sourceRoot 'AFZ-OpenAI-Agent-v2.ps1'
$allowFile=Join-Path $sourceRoot 'allowed-clients.txt'
$uiSrc=Join-Path $sourceRoot 'AFZ-Agent-UI.html'
$toolsSrc=Join-Path $sourceRoot 'tools'
$runtimeRoot='C:\ProgramData\AFZ\OpenAIAgent\runtime'
$runtime=Join-Path $runtimeRoot 'AFZ-OpenAI-Agent-runtime.ps1'
if(-not(Test-Path $src)){throw "Agent source missing: $src"}
if(-not(Test-Path $uiSrc)){throw "Agent UI missing: $uiSrc"}
if(-not(Test-Path $toolsSrc)){throw "Agent tools directory missing: $toolsSrc"}
New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
$ips=@()
if(Test-Path $allowFile){
  $ips=@(Get-Content -LiteralPath $allowFile | ForEach-Object {$_.Trim()} | Where-Object {$_ -and -not $_.StartsWith('#') -and $_ -match '^100\.(?:\d{1,3}\.){2}\d{1,3}$'} | Sort-Object -Unique)
}
$vals=@('127.0.0.1','::1')+$ips
$text=Get-Content -LiteralPath $src -Raw
$replacement='$AllowedClients = @('+(($vals|ForEach-Object {"'$_'"}) -join ',')+')'
$patched=[regex]::Replace($text,'(?m)^\$AllowedClients\s*=\s*@\([^\r\n]*\)\s*$',[System.Text.RegularExpressions.MatchEvaluator]{param($m)$replacement},1)
if($patched -eq $text){throw 'Could not inject AFZ client allowlist into runtime copy'}

# PowerShell argument mode does not reliably pass a bare [ordered]@{} literal after
# positional arguments. Use a normal hashtable for direct Send-Json health responses.
$patched=$patched.Replace('Send-Json $ctx 200 [ordered]@{','Send-Json $ctx 200 @{')

# The runtime script resolves the UI and typed tool scripts relative to its own path.
# Stage those read-only assets beside the generated runtime so remote UI and tools work.
Copy-Item -LiteralPath $uiSrc -Destination (Join-Path $runtimeRoot 'AFZ-Agent-UI.html') -Force
$runtimeTools=Join-Path $runtimeRoot 'tools'
if(Test-Path $runtimeTools){Remove-Item -LiteralPath $runtimeTools -Recurse -Force}
Copy-Item -LiteralPath $toolsSrc -Destination $runtimeTools -Recurse -Force

Set-Content -LiteralPath $runtime -Value $patched -Encoding UTF8
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runtime -Port $Port -BindHost $BindHost
exit $LASTEXITCODE
