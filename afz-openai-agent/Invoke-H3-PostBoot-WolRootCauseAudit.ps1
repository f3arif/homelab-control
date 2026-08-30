[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$targetMac = '4C-ED-FB-3F-B0-9E'
$targetMacFlat = ($targetMac -replace '[-:]','').ToUpperInvariant()

function Write-Section([string]$Name) {
    Write-Output ("--- {0} ---" -f $Name)
}

function Invoke-ReadOnly([scriptblock]$Script) {
    try { & $Script } catch { Write-Output ("ERROR={0}" -f $_.Exception.Message) }
}

Write-Output '===== AFZ H3 POSTBOOT WOL ROOTCAUSE AUDIT ====='
Write-Output ("Timestamp={0}" -f [DateTimeOffset]::Now.ToString('o'))
Write-Output ("Computer={0}" -f $env:COMPUTERNAME)
Write-Output 'MutationPolicy=READ_ONLY'
Write-Output ("TargetMac={0}" -f $targetMac)

Write-Section 'SYSTEM POWER CAPABILITIES'
Invoke-ReadOnly { powercfg.exe /a 2>&1 }
Write-Output ("PowerCfgAExit={0}" -f $LASTEXITCODE)

Write-Section 'ACTIVE POWER SCHEME'
Invoke-ReadOnly { powercfg.exe /getactivescheme 2>&1 }
Write-Output ("PowerCfgActiveExit={0}" -f $LASTEXITCODE)
Invoke-ReadOnly { powercfg.exe /query SCHEME_CURRENT SUB_SLEEP 2>&1 }
Write-Output ("PowerCfgSleepQueryExit={0}" -f $LASTEXITCODE)

Write-Section 'WAKE DEVICE SETS'
foreach ($q in @('wake_armed','wake_from_any','wake_programmable')) {
    Write-Output ("QUERY={0}" -f $q)
    Invoke-ReadOnly { powercfg.exe /devicequery $q 2>&1 }
    Write-Output ("EXIT={0}" -f $LASTEXITCODE)
}

Write-Section 'LAST WAKE AND WAKE TIMERS'
Invoke-ReadOnly { powercfg.exe /lastwake 2>&1 }
Write-Output ("LastWakeExit={0}" -f $LASTEXITCODE)
Invoke-ReadOnly { powercfg.exe /waketimers 2>&1 }
Write-Output ("WakeTimersExit={0}" -f $LASTEXITCODE)

Write-Section 'HIBERNATE FAST STARTUP'
Invoke-ReadOnly {
    $power = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop
    [pscustomobject]@{
        HibernateEnabled = $power.HibernateEnabled
        HibernateEnabledDefault = $power.HibernateEnabledDefault
    } | Format-List | Out-String | Write-Output
}
Invoke-ReadOnly {
    $session = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop
    [pscustomobject]@{ HiberbootEnabled = $session.HiberbootEnabled } | Format-List | Out-String | Write-Output
}

Write-Section 'PHYSICAL NETWORK ADAPTERS'
$physical = @()
Invoke-ReadOnly {
    $script:physical = @(Get-NetAdapter -Physical -ErrorAction Stop | Sort-Object ifIndex)
    $script:physical | Select-Object Name,InterfaceDescription,Status,MacAddress,LinkSpeed,ifIndex,DriverInformation | Format-Table -AutoSize | Out-String | Write-Output
}

$targetAdapters = @($physical | Where-Object { (($_.MacAddress -replace '[-:]','').ToUpperInvariant()) -eq $targetMacFlat })
Write-Output ("TargetAdapterCount={0}" -f $targetAdapters.Count)
foreach ($adapter in $targetAdapters) {
    Write-Output ("TargetAdapter={0}|{1}|Status={2}|IfIndex={3}" -f $adapter.Name,$adapter.InterfaceDescription,$adapter.Status,$adapter.ifIndex)

    Write-Section ("POWER MANAGEMENT {0}" -f $adapter.Name)
    Invoke-ReadOnly {
        Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction Stop |
            Format-List * | Out-String -Width 260 | Write-Output
    }

    Write-Section ("ADVANCED WAKE/POWER PROPERTIES {0}" -f $adapter.Name)
    Invoke-ReadOnly {
        Get-NetAdapterAdvancedProperty -Name $adapter.Name -AllProperties -ErrorAction Stop |
            Where-Object {
                $_.DisplayName -match 'Wake|WOL|Magic|Shutdown|Power|Energy|EEE|Green|Sleep' -or
                $_.RegistryKeyword -match 'Wake|WOL|Magic|Shutdown|Power|Energy|EEE|Green|Sleep'
            } |
            Select-Object DisplayName,DisplayValue,RegistryKeyword,RegistryValue |
            Format-Table -AutoSize | Out-String -Width 300 | Write-Output
    }

    Write-Section ("PNP CAPABILITIES {0}" -f $adapter.Name)
    Invoke-ReadOnly {
        $pnp = Get-CimInstance Win32_NetworkAdapter -ErrorAction Stop |
            Where-Object { $_.GUID -eq $adapter.InterfaceGuid.Guid -or $_.MACAddress -eq ($adapter.MacAddress -replace '-',':') } |
            Select-Object -First 1
        if ($pnp) {
            $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $pnp.PNPDeviceID + '\Device Parameters'
            Write-Output ("PNPDeviceID={0}" -f $pnp.PNPDeviceID)
            Write-Output ("RegistryPath={0}" -f $regPath)
            if (Test-Path -LiteralPath $regPath) {
                Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop |
                    Select-Object PnPCapabilities,*Wake*,*Power* |
                    Format-List | Out-String -Width 260 | Write-Output
            }
        } else {
            Write-Output 'PNP_MATCH=NONE'
        }
    }
}

Write-Section 'RECENT POWER EVENTS'
Invoke-ReadOnly {
    $start = (Get-Date).AddHours(-8)
    Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$start} -ErrorAction Stop |
        Where-Object {
            $_.ProviderName -in @('Microsoft-Windows-Kernel-Power','Microsoft-Windows-Power-Troubleshooter','EventLog','Microsoft-Windows-Kernel-General') -or
            $_.Id -in @(1,12,13,41,42,107,109,506,507,6005,6006,6008)
        } |
        Select-Object -First 120 TimeCreated,Id,ProviderName,LevelDisplayName,@{N='Message';E={($_.Message -replace '[\r\n]+',' ')}} |
        Format-Table -Wrap -AutoSize | Out-String -Width 320 | Write-Output
}

Write-Section 'AFZ TASKS WITH POWER-ACTION STRINGS'
Invoke-ReadOnly {
    $patterns = 'shutdown|Stop-Computer|Restart-Computer|SetSuspendState|powrprof|hibernate|sleep|psshutdown|rundll32'
    $hits = foreach ($task in Get-ScheduledTask -ErrorAction Stop) {
        $actionText = (($task.Actions | ForEach-Object { '{0} {1}' -f $_.Execute,$_.Arguments }) -join ' || ')
        if ($task.TaskName -match '^AFZ' -and $actionText -match $patterns) {
            [pscustomobject]@{
                TaskPath = $task.TaskPath
                TaskName = $task.TaskName
                State = $task.State
                Action = $actionText
            }
        }
    }
    if ($hits) { $hits | Format-Table -Wrap -AutoSize | Out-String -Width 320 | Write-Output }
    else { Write-Output 'AFZ_POWER_ACTION_TASKS=NONE' }
}

Write-Section 'CURRENT BOOT / UPTIME'
Invoke-ReadOnly {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Write-Output ("LastBootUpTime={0}" -f ([DateTimeOffset]$os.LastBootUpTime).ToString('o'))
    Write-Output ("UptimeSeconds={0}" -f [math]::Round(((Get-Date)-$os.LastBootUpTime).TotalSeconds,0))
}

Write-Output 'POWER_CHANGE=NONE'
Write-Output 'RESULT=PASS_READONLY_H3_POSTBOOT_WOL_ROOTCAUSE_AUDIT'
Write-Output '===== END ====='
