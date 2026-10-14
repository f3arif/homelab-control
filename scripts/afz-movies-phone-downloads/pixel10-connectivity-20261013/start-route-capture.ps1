$ErrorActionPreference='Stop'
$root='C:\AFZ\Evidence\Pixel10-Connectivity-20261013-2052\usb-5038'
$taskName='AFZ Pixel10 USB Route Capture 20261013'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {throw 'Existing task: inspect before repeating'}
if (Test-Path (Join-Path $root 'route-capture-status.json')) {throw 'Existing capture: inspect before repeating'}
$script=Join-Path $root 'capture-routes.py'
$action=New-ScheduledTaskAction -Execute 'C:\Users\Faiz\AppData\Local\Programs\Python\Python311\python.exe' -Argument ('"'+$script+'"') -WorkingDirectory $root
$principal=New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 35) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Description 'One-shot read-only Pixel 10 DNS/TCP capture; no recurring trigger' | Out-Null
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2
$task=Get-ScheduledTask -TaskName $taskName
[xml]$xml=Export-ScheduledTask -TaskName $taskName
$receipt=[ordered]@{taskName=$taskName;state=[string]$task.State;triggerCount=@($xml.Task.Triggers.ChildNodes | Where-Object {$_.NodeType -eq 'Element'}).Count;hardRuntimeLimitMinutes=35;settingsChanged=$false}
$receipt | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $root 'route-task-receipt.json')
$receipt | ConvertTo-Json
