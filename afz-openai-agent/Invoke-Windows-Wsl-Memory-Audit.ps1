#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-IniValue {
    param(
        [string[]]$Lines,
        [string]$Section,
        [string]$Key
    )
    $inSection = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            $inSection = ($Matches[1] -ieq $Section)
            continue
        }
        if ($inSection -and $line -match '^\s*([^#;=]+?)\s*=\s*(.*?)\s*$') {
            if ($Matches[1].Trim() -ieq $Key) { return $Matches[2].Trim() }
        }
    }
    return $null
}

function Get-WslVersionInfo {
    $raw = ''
    $version = $null
    try {
        $raw = (& wsl.exe --version 2>&1 | Out-String).Trim()
        if ($raw -match '(?im)^\s*WSL version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)') {
            $version = [version]$Matches[1]
        }
    } catch {
        $raw = $_.Exception.Message
    }
    [pscustomobject]@{
        raw = $raw
        version = if ($version) { $version.ToString() } else { $null }
        autoMemoryReclaimSupported = ($null -ne $version -and $version -ge [version]'1.3.10')
    }
}

function Get-ConfigProfiles {
    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($env:USERPROFILE) { [void]$paths.Add($env:USERPROFILE) }

    try {
        $interactive = (Get-CimInstance Win32_ComputerSystem).UserName
        if ($interactive) {
            $userLeaf = ($interactive -split '\\')[-1]
            Get-CimInstance Win32_UserProfile |
                Where-Object { -not $_.Special -and $_.LocalPath -and ((Split-Path $_.LocalPath -Leaf) -ieq $userLeaf) } |
                ForEach-Object { [void]$paths.Add([string]$_.LocalPath) }
        }
    } catch {}

    try {
        Get-CimInstance Win32_UserProfile |
            Where-Object { $_.Loaded -and -not $_.Special -and $_.LocalPath } |
            ForEach-Object { [void]$paths.Add([string]$_.LocalPath) }
    } catch {}

    $out = @()
    foreach ($profile in $paths) {
        $configPath = Join-Path $profile '.wslconfig'
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { continue }
        $lines = @(Get-Content -LiteralPath $configPath -ErrorAction Stop)
        $out += [pscustomobject]@{
            profile = $profile
            configPath = $configPath
            memory = Get-IniValue -Lines $lines -Section 'wsl2' -Key 'memory'
            processors = Get-IniValue -Lines $lines -Section 'wsl2' -Key 'processors'
            swap = Get-IniValue -Lines $lines -Section 'wsl2' -Key 'swap'
            autoMemoryReclaim = Get-IniValue -Lines $lines -Section 'experimental' -Key 'autoMemoryReclaim'
        }
    }
    return @($out)
}

$os = Get-CimInstance Win32_OperatingSystem
$totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
$loadPct = if ($totalGB -gt 0) { [math]::Round((($totalGB - $freeGB) / $totalGB) * 100, 1) } else { $null }

$top = @(Get-Process -ErrorAction SilentlyContinue |
    Sort-Object WorkingSet64 -Descending |
    Select-Object -First 20 @{n='name';e={$_.ProcessName}}, @{n='pid';e={$_.Id}}, @{n='workingSetMB';e={[math]::Round($_.WorkingSet64 / 1MB, 1)}}, @{n='privateMB';e={[math]::Round($_.PrivateMemorySize64 / 1MB, 1)}})

$vmmem = Get-Process -Name 'vmmemWSL' -ErrorAction SilentlyContinue | Select-Object -First 1
$dockerBackend = Get-Process -Name 'com.docker.backend' -ErrorAction SilentlyContinue | Select-Object -First 1
$dockerDesktop = Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue | Select-Object -First 1

$dockerMemGB = $null
$dockerInfoError = $null
try {
    $docker = Get-Command docker.exe -ErrorAction Stop | Select-Object -First 1
    $rawMem = (& $docker.Source info --format '{{.MemTotal}}' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $rawMem -match '^\d+$') {
        $dockerMemGB = [math]::Round(([double]$rawMem / 1GB), 2)
    } else {
        $dockerInfoError = $rawMem
    }
} catch {
    $dockerInfoError = $_.Exception.Message
}

$distros = @()
try {
    $distros = @(& wsl.exe --list --running --quiet 2>$null | ForEach-Object { ([string]$_).Trim([char]0).Trim() } | Where-Object { $_ })
} catch {}

$wsl = Get-WslVersionInfo
$configs = @(Get-ConfigProfiles)

$result = [ordered]@{
    ok = $true
    schema = 'afz.windows-wsl-memory-audit.v1'
    action = 'audit'
    readOnly = $true
    computer = $env:COMPUTERNAME
    time = Get-Date -Format o
    physicalMemory = [ordered]@{
        totalGB = $totalGB
        freeGB = $freeGB
        loadPct = $loadPct
    }
    wsl = [ordered]@{
        version = $wsl.version
        autoMemoryReclaimSupported = $wsl.autoMemoryReclaimSupported
        runningDistros = $distros
        vmmemWslMB = if ($vmmem) { [math]::Round($vmmem.WorkingSet64 / 1MB, 1) } else { 0 }
        configs = $configs
    }
    docker = [ordered]@{
        backendRunning = [bool]$dockerBackend
        desktopRunning = [bool]$dockerDesktop
        engineMemoryGB = $dockerMemGB
        infoError = $dockerInfoError
    }
    topMemoryProcesses = $top
    safety = 'Read-only: no process stop, service stop, WSL shutdown, Docker restart, container mutation, file write, configuration change, or memory-cap change.'
}

[pscustomobject]$result | ConvertTo-Json -Depth 8 -Compress
