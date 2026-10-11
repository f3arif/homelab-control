$ErrorActionPreference = 'Stop'
$taskName = 'AFZ Pixel10 Connectivity Capture 20261011'
$python = 'C:\Users\Faiz\AppData\Local\Programs\Python\Python311\python.exe'
$root = 'C:\AFZ\Evidence\Pixel10-Connectivity-20261011'
$script = Join-Path $root 'capture.py'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'Existing capture task: inspect before repeating.' }
if (Test-Path (Join-Path $root 'capture-status.json')) { throw 'Existing capture state: inspect before repeating.' }
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $python -Argument ('"' + $script + '"') -WorkingDirectory $root
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 12) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$task = Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Description 'One-shot bounded read-only Pixel 10 network capture; no recurring trigger.'
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2
$live = Get-ScheduledTask -TaskName $taskName
$receipt = [ordered]@{ taskName=$taskName; state=[string]$live.State; triggerCount=$(if ($null -eq $live.Triggers) { 0 } else { @($live.Triggers).Count }); maxRuntimeMinutes=12; registeredAtUtc=[DateTime]::UtcNow.ToString('o'); phoneSettingsChanged=$false }
$receipt | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $root 'task-receipt.json')
$receipt | ConvertTo-Json
