#Requires -Version 5.1
# AFZ_TIMEOUT_SECONDS = 240
$ErrorActionPreference='Continue'
if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw ('WRONG_HOST '+$env:COMPUTERNAME)}
$dc='C:\Users\Faiz\AppData\Local\AFZ\DesktopCommander\Watch-DesktopCommander.ps1'
if(Test-Path $dc){powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $dc}
Start-Sleep -Seconds 5
$roleDir='C:\ProgramData\AFZ\HermesRouting'
New-Item -ItemType Directory -Force -Path $roleDir | Out-Null
$role=[ordered]@{schema=1;host='DESKTOP-10SKF0M';role='standby';service='Hermes';primary_host='DESKTOP-H3R6CQN';standby_local_model='qwen3.5:4b-hermes96k';cloud_order=@('gpt-5.6-sol-900k','gpt-6-astra','openrouter');updated=(Get-Date -Format o)}
$role | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $roleDir 'role.json') -Encoding UTF8
$router='C:\Projects\HermesRouter\hermes_route.py'
$routerOk=$false
$routerOutput=''
if(Test-Path $router){
  $o=py -3 $router --lane default --prompt 'Reply only ASUS_STANDBY_OK' 2>&1
  $routerOk=($LASTEXITCODE -eq 0 -and (($o|Out-String) -match 'ASUS_STANDBY_OK'))
  $routerOutput=(($o|Out-String).Trim()).Replace([Environment]::NewLine,' | ')
}
$dcProcs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {([string]$_.CommandLine) -match '(?i)desktop-commander.*remote'})
[ordered]@{ok=$routerOk;host=$env:COMPUTERNAME;commanderProcesses=$dcProcs.Count;roleMarker=(Test-Path (Join-Path $roleDir 'role.json'));routerOk=$routerOk;routerOutput=$routerOutput;time=(Get-Date -Format o)} | ConvertTo-Json -Depth 5
