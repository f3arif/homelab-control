#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$Port=8796,
  [string]$BindHost='100.70.25.8'
)
$ErrorActionPreference='Stop'
$src=Join-Path $InstallRoot 'afz-openai-agent\AFZ-OpenAI-Agent-v2.ps1'
$allowFile=Join-Path $InstallRoot 'afz-openai-agent\allowed-clients.txt'
$runtimeRoot='C:\ProgramData\AFZ\OpenAIAgent\runtime'
$runtime=Join-Path $runtimeRoot 'AFZ-OpenAI-Agent-runtime.ps1'
if(-not(Test-Path $src)){throw "Agent source missing: $src"}
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
# positional arguments. The agent has one direct health response using that form;
# use a normal hashtable there. Ordered dictionaries returned through variables are fine.
$patched=$patched.Replace('Send-Json $ctx 200 [ordered]@{','Send-Json $ctx 200 @{')

Set-Content -LiteralPath $runtime -Value $patched -Encoding UTF8
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runtime -Port $Port -BindHost $BindHost
exit $LASTEXITCODE
