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
$prospectSrc=Join-Path $sourceRoot 'prospect-engine'
$watcherSrc=Join-Path $sourceRoot 'Push-Deploy-Watcher.ps1'
$queueOrphanWatcher=Join-Path $sourceRoot 'Queue-Orphan-Request-Watcher.ps1'
$familyPttAuditWatcher=Join-Path $sourceRoot 'FamilyPTT-Transport-Audit-Watcher-R3.ps1'
$familyPttEdgeWatcher=Join-Path $sourceRoot 'FamilyPTT-Edge-Preflight-Watcher-R12.ps1'
$runtimeRoot='C:\ProgramData\AFZ\OpenAIAgent\runtime'
$runtime=Join-Path $runtimeRoot 'AFZ-OpenAI-Agent-runtime.ps1'
if(-not(Test-Path $src)){throw "Agent source missing: $src"}
if(-not(Test-Path $uiSrc)){throw "Agent UI missing: $uiSrc"}
if(-not(Test-Path $toolsSrc)){throw "Agent tools directory missing: $toolsSrc"}
if(-not(Test-Path $prospectSrc)){throw "Prospect Engine directory missing: $prospectSrc"}
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

$patched=$patched.Replace('Send-Json $ctx 200 [ordered]@{','Send-Json $ctx 200 @{')
$patched=$patched.Replace('properties=[ordered]@{};required=@();additionalProperties=$false','properties=[ordered]@{};additionalProperties=$false')
$patched=$patched.Replace('[Security.Cryptography.ProtectedData]','[System.Security.Cryptography.ProtectedData]')
$patched=$patched.Replace('[Security.Cryptography.DataProtectionScope]','[System.Security.Cryptography.DataProtectionScope]')
if($patched -match '\[System\.Security\.Cryptography\.ProtectedData\]' -and $patched -notmatch '(?im)^\s*Add-Type\s+-AssemblyName\s+System\.Security'){
  $patched=$patched.Replace("`$ErrorActionPreference = 'Stop'","`$ErrorActionPreference = 'Stop'`r`nAdd-Type -AssemblyName System.Security -ErrorAction Stop")
}

$patched=$patched.Replace('param($Args)','param($ToolArgs)')
$patched=$patched.Replace('param([string]$Name,$Args)','param([string]$Name,$ToolArgs)')
$patched=$patched.Replace('$Args.','$ToolArgs.')
$patched=$patched.Replace('Tool-ReadFile $Args','Tool-ReadFile $ToolArgs')
$patched=$patched.Replace('Tool-ListFiles $Args','Tool-ListFiles $ToolArgs')
$patched=$patched.Replace('Tool-FileSearch $Args','Tool-FileSearch $ToolArgs')
$patched=$patched.Replace('Tool-JellyfinUserViews $Args','Tool-JellyfinUserViews $ToolArgs')
$patched=$patched.Replace('$args = [pscustomobject]@{}','$callArgs = [pscustomobject]@{}')
$patched=$patched.Replace('$args = $call.arguments | ConvertFrom-Json','$callArgs = $call.arguments | ConvertFrom-Json')
$patched=$patched.Replace('Invoke-Tool ([string]$call.name) $args','Invoke-Tool ([string]$call.name) $callArgs')
$patched=$patched.Replace('Get-Content -LiteralPath $file -Raw','Get-Content -LiteralPath $file -Raw -Encoding UTF8')

Copy-Item -LiteralPath $uiSrc -Destination (Join-Path $runtimeRoot 'AFZ-Agent-UI.html') -Force
$runtimeTools=Join-Path $runtimeRoot 'tools'
if(Test-Path $runtimeTools){Remove-Item -LiteralPath $runtimeTools -Recurse -Force}
Copy-Item -LiteralPath $toolsSrc -Destination $runtimeTools -Recurse -Force
$runtimeProspect=Join-Path $runtimeRoot 'prospect-engine'
if(Test-Path $runtimeProspect){Remove-Item -LiteralPath $runtimeProspect -Recurse -Force}
Copy-Item -LiteralPath $prospectSrc -Destination $runtimeProspect -Recurse -Force

$pushTaskName='AFZ OpenAI Agent Push Deploy Watcher'
$pushTask=Get-ScheduledTask -TaskName $pushTaskName -ErrorAction SilentlyContinue
if(-not $pushTask -and (Test-Path $watcherSrc)){
  $watchArgs="-NoProfile -ExecutionPolicy Bypass -File `"$watcherSrc`" -InstallRoot `"$InstallRoot`" -IntervalSeconds 3"
  Start-Process -FilePath 'powershell.exe' -ArgumentList $watchArgs -WindowStyle Hidden | Out-Null
}

# Secretless, narrowly typed queue-orphan request watcher. The request is deployed
# atomically inside afz-openai-agent/requests with the exact GitHub source bundle.
# OneDrive is diagnostic output only; it is never request/control input.
if(Test-Path $queueOrphanWatcher){
  $queueOrphanTaskName='AFZ Queue Orphan Remediation Request Watcher'
  $queueOrphanTaskAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$queueOrphanWatcher`" -InstallRoot `"$InstallRoot`" -IntervalSeconds 5"
  $queueOrphanTask=Get-ScheduledTask -TaskName $queueOrphanTaskName -ErrorAction SilentlyContinue
  if($queueOrphanTask){
    Set-ScheduledTask -TaskName $queueOrphanTaskName -Action $queueOrphanTaskAction | Out-Null
  }else{
    $queueOrphanPrincipal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $queueOrphanSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $queueOrphanTaskName -Action $queueOrphanTaskAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $queueOrphanSettings -Principal $queueOrphanPrincipal -Force | Out-Null
  }

  # Reload the watcher after a source deployment so its in-memory code matches the
  # newly installed exact source. Never interrupt a repair already marked running.
  $queueOrphanStatePath='C:\ProgramData\AFZ\OpenAIAgent\jobs\queue-orphan-remediation\request-watcher.json'
  $queueOrphanBusy=$false
  if(Test-Path -LiteralPath $queueOrphanStatePath -PathType Leaf){
    try{$queueOrphanState=Get-Content -LiteralPath $queueOrphanStatePath -Raw|ConvertFrom-Json;$queueOrphanBusy=([string]$queueOrphanState.status -eq 'running')}catch{}
  }
  $queueOrphanTask=Get-ScheduledTask -TaskName $queueOrphanTaskName -ErrorAction Stop
  if($queueOrphanTask.State -eq 'Running' -and -not $queueOrphanBusy){
    Stop-ScheduledTask -TaskName $queueOrphanTaskName -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
    Start-ScheduledTask -TaskName $queueOrphanTaskName
  }elseif($queueOrphanTask.State -ne 'Running'){
    Start-ScheduledTask -TaskName $queueOrphanTaskName
  }
}

if(Test-Path $familyPttAuditWatcher){
  $familyPttTaskName='AFZ FamilyPTT Transport Audit Watcher R3'
  $familyPttTaskAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$familyPttAuditWatcher`" -InstallRoot `"$InstallRoot`" -IntervalSeconds 5"
  $familyPttTask=Get-ScheduledTask -TaskName $familyPttTaskName -ErrorAction SilentlyContinue
  if($familyPttTask){
    Set-ScheduledTask -TaskName $familyPttTaskName -Action $familyPttTaskAction | Out-Null
  }else{
    $familyPttPrincipal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $familyPttSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $familyPttTaskName -Action $familyPttTaskAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $familyPttSettings -Principal $familyPttPrincipal -Force | Out-Null
  }
  $familyPttTask=Get-ScheduledTask -TaskName $familyPttTaskName -ErrorAction Stop
  if($familyPttTask.State -ne 'Running'){Start-ScheduledTask -TaskName $familyPttTaskName}
}

if(Test-Path $familyPttEdgeWatcher){
  $familyPttEdgeTaskName='AFZ FamilyPTT Edge Preflight Watcher R12'
  $familyPttEdgeTaskAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$familyPttEdgeWatcher`" -InstallRoot `"$InstallRoot`" -IntervalSeconds 5"
  $familyPttEdgeTask=Get-ScheduledTask -TaskName $familyPttEdgeTaskName -ErrorAction SilentlyContinue
  if($familyPttEdgeTask){
    Set-ScheduledTask -TaskName $familyPttEdgeTaskName -Action $familyPttEdgeTaskAction | Out-Null
  }else{
    $familyPttEdgePrincipal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $familyPttEdgeSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $familyPttEdgeTaskName -Action $familyPttEdgeTaskAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $familyPttEdgeSettings -Principal $familyPttEdgePrincipal -Force | Out-Null
  }
  $familyPttEdgeTask=Get-ScheduledTask -TaskName $familyPttEdgeTaskName -ErrorAction Stop
  if($familyPttEdgeTask.State -ne 'Running'){Start-ScheduledTask -TaskName $familyPttEdgeTaskName}
}

Set-Content -LiteralPath $runtime -Value $patched -Encoding UTF8
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runtime -Port $Port -BindHost $BindHost
exit $LASTEXITCODE