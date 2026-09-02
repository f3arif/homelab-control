#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\AFZ\homelab-control',
    [string]$TaskName = 'AFZ Home Assistant Fleet MQTT Publisher',
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$publisher = Join-Path $InstallRoot 'afz-openai-agent\homeassistant\Publish-AFZ-Fleet-Mqtt.ps1'
$logRoot = 'C:\ProgramData\AFZ\HomeAssistant'
$logFile = Join-Path $logRoot 'mqtt-publisher.log'

Write-Host "=== AFZ FLEET MQTT PUBLISHER INSTALLER ==="

if (-not (Test-Path -LiteralPath $publisher -PathType Leaf)) {
    throw "Publisher missing: $publisher"
}

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $publisher,
    [ref]$tokens,
    [ref]$errors
)

if (@($errors).Count -gt 0) {
    $errors | ForEach-Object { Write-Host "PARSER_ERROR=$($_.Message)" }
    throw "Publisher parser validation failed with $(@($errors).Count) error(s)."
}
Write-Host 'PUBLISHER_PARSE=PASS'

Write-Host "`n--- DRY RUN MAPPING ---"
$dryOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $publisher -Once -DryRun 2>&1
$dryExit = $LASTEXITCODE
$dryOutput | ForEach-Object { Write-Host $_ }
if ($dryExit -ne 0) { throw "Publisher dry run failed: exit $dryExit" }
$dryText = $dryOutput | Out-String
if ($dryText -notmatch '"worker":"h3"') { throw 'Dry run did not map canonical H3 worker.' }
if ($dryText -notmatch '"worker":"asus","availability":"offline"') { throw 'Dry run did not fail closed for missing ASUS source.' }
Write-Host 'DRY_RUN=PASS'

if ($ValidateOnly) {
    Write-Host 'VALIDATE_ONLY=YES'
    Write-Host 'INSTALL_PERFORMED=NO'
    exit 0
}

Write-Host "`n--- ONE-SHOT MQTT CANARY ---"
$canaryOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $publisher -Once 2>&1
$canaryExit = $LASTEXITCODE
$canaryOutput | ForEach-Object { Write-Host $_ }
$canaryText = $canaryOutput | Out-String
if ($canaryExit -ne 0) { throw "Publisher one-shot MQTT canary failed: exit $canaryExit" }
if ($canaryText -notmatch 'DISCOVERY_PUBLISHED=YES') { throw 'Discovery publish was not confirmed.' }
if ($canaryText -notmatch 'STATE_PUBLISHED=YES') { throw 'State publish was not confirmed.' }
Write-Host 'ONE_SHOT_MQTT_CANARY=PASS'

New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    $samePublisher = $false
    foreach ($existingAction in @($existing.Actions)) {
        if ([string]$existingAction.Execute -match 'powershell' -and [string]$existingAction.Arguments -like "*$publisher*") {
            $samePublisher = $true
        }
    }
    if (-not $samePublisher) {
        throw "Task '$TaskName' already exists with a different action. Refusing to replace it."
    }
    Write-Host 'EXISTING_TASK=SAME_PUBLISHER'
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# Task Scheduler is only the startup launcher. The publisher owns one long-running
# 15-second read/publish loop; there is no recurring Task Scheduler trigger.
$command = "& '$publisher' *>> '$logFile'"
$arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$command`""

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument $arguments `
    -WorkingDirectory (Split-Path $publisher -Parent)

$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Single AFZ Home Assistant MQTT telemetry publisher. Reads Control Hub /api/state and publishes retained afz/fleet state; no execution authority.' | Out-Null

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 4

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName

Write-Host "TASK_STATE=$($task.State)"
Write-Host "LAST_TASK_RESULT=$($info.LastTaskResult)"
Write-Host 'TASK_TRIGGER=AT_STARTUP_ONLY'
Write-Host 'RECURRING_TASK_TRIGGER=NO'
Write-Host "PUBLISHER=$publisher"
Write-Host "LOG_FILE=$logFile"
Write-Host 'INSTALL_PERFORMED=YES'
Write-Host 'NEXT=VERIFY_HOME_ASSISTANT_MQTT_ENTITIES'
