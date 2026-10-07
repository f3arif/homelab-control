# Generic receiver verification; invoked only through an encoded strict SSH command.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$Utf8 = [Text.UTF8Encoding]::new($false)
$Qualification = 'stable observed capture; no exclusive writer lock'

function Guard-Volume([long]$Additional = 0) {
    $volumes = @(Get-Volume -DriveLetter ([string]$cfg.drive_letter) -ErrorAction Stop)
    if ($volumes.Count -ne 1) { throw 'volume_count' }
    $v = $volumes[0]
    $id = ([string]$v.UniqueId).Trim().ToLowerInvariant()
    $guid = ([string]$cfg.volume_guid).ToLowerInvariant()
    if (($id -ne $guid -and $id -ne ('\\?\volume{' + $guid + '}\')) -or
        ([string]$v.DriveLetter).ToUpperInvariant() -cne [string]$cfg.drive_letter -or
        [string]$v.FileSystemLabel -cne [string]$cfg.volume_label) { throw 'volume_identity' }
    if ($Additional -lt 0 -or [long]$v.SizeRemaining -lt ([long]$cfg.min_free_bytes + $Additional)) {
        throw 'volume_free_space'
    }
}

function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'reparse_point' }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}

function Assert-Generation([string]$Generation) {
    if ($Generation -cnotmatch '^[0-9]{8}T[0-9]{12}Z-[0-9a-f]{12}$') { throw 'generation_name' }
}

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Verify-Generation([string]$Directory, $Expected) {
    Assert-NoReparse $Directory
    if (!(Test-Path -LiteralPath $Directory -PathType Container)) { throw 'generation_missing' }
    if (Test-Path -LiteralPath (Join-Path $Directory 'INCOMPLETE')) { throw 'incomplete_capture' }
    $manifestPath = Join-Path $Directory 'manifest.json'
    $completePath = Join-Path $Directory 'COMPLETE'
    Assert-NoReparse $manifestPath
    Assert-NoReparse $completePath
    if ((Get-Hash $manifestPath) -cne [string]$Expected.manifest_sha256 -or
        (Get-Hash $completePath) -cne [string]$Expected.complete_sha256) { throw 'metadata_hash' }
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $complete = Get-Content -LiteralPath $completePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$complete.manifest_sha256 -cne [string]$Expected.manifest_sha256 -or
        [string]$m.qualification -cne $Qualification -or
        $m.restic_decryption_or_restore_tested -ne $false) { throw 'capture_qualification' }
    $files = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $dirs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$files.Add('manifest.json'); [void]$files.Add('COMPLETE')
    foreach ($name in @('repo','repo/keys','repo/data','repo/index','repo/snapshots','repo/locks','repo/tmp')) {
        [void]$dirs.Add($name)
    }
    $count = 0; [long]$bytes = 0
    foreach ($property in $m.files.PSObject.Properties) {
        $relative = [string]$property.Name
        if ($relative -cne 'config' -and
            $relative -cnotmatch '^(keys|index|snapshots)/[0-9a-f]{64}$' -and
            $relative -cnotmatch '^data/([0-9a-f]{2}/)?[0-9a-f]{64}$') { throw 'manifest_path' }
        $entry = $property.Value
        if ([string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or [long]$entry.size -lt 0) {
            throw 'manifest_value'
        }
        if ($relative -cne 'config' -and ($relative.Split('/')[-1] -cne [string]$entry.sha256)) {
            throw 'object_content_id'
        }
        $local = 'repo/' + $relative
        [void]$files.Add($local)
        $parts = $local.Split('/')
        for ($i = 1; $i -lt $parts.Length; $i++) {
            [void]$dirs.Add(($parts[0..($i-1)] -join '/'))
        }
        $path = Join-Path $Directory ($local.Replace('/', '\'))
        Assert-NoReparse $path
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or $item.Length -ne [long]$entry.size -or
            (Get-Hash $path) -cne [string]$entry.sha256) { throw 'repository_file_mismatch' }
        $count++; $bytes += [long]$entry.size
    }
    if ($count -ne [int]$m.file_count -or $bytes -ne [long]$m.total_bytes) { throw 'manifest_totals' }
    $actualFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $actualDirs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Directory)
    while ($pending.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath ($pending.Pop()) -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'reparse_point' }
            $relative = $item.FullName.Substring($Directory.Length + 1).Replace('\', '/')
            if ($item.PSIsContainer) {
                [void]$actualDirs.Add($relative); $pending.Push($item.FullName)
            } else { [void]$actualFiles.Add($relative) }
        }
    }
    if (!$actualFiles.SetEquals($files) -or !$actualDirs.SetEquals($dirs)) { throw 'unexpected_layout' }
}

Guard-Volume
$base = [IO.Path]::GetFullPath([string]$cfg.repository_base_windows).TrimEnd('\')
if (!$base.StartsWith(([string]$cfg.drive_letter + ':\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'destination_drive'
}
Assert-NoReparse $base
$latestPath = Join-Path $base 'latest.json'
if ($cfg.action -eq 'status') {
    if (!(Test-Path -LiteralPath $latestPath -PathType Leaf)) {
        Guard-Volume
        @{ok=$true;matches=$false} | ConvertTo-Json -Compress
        exit 0
    }
    Assert-NoReparse $latestPath
    $latest = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $same = $true
    foreach ($name in @('generation','source_manifest_sha256','manifest_sha256','complete_sha256','profile_id')) {
        if ([string]$latest.$name -cne [string]$cfg.expected.$name) { $same = $false }
    }
    if ($same) {
        Assert-Generation ([string]$latest.generation)
        Verify-Generation (Join-Path $base ([string]$latest.generation)) $cfg.expected
    }
    Guard-Volume
    @{ok=$true;matches=$same} | ConvertTo-Json -Compress
    exit 0
}
Assert-Generation ([string]$cfg.generation)
$partial = Join-Path $base ([string]$cfg.generation + '.partial')
$final = Join-Path $base ([string]$cfg.generation)
Assert-NoReparse $partial
Assert-NoReparse $final
if ($cfg.action -eq 'prepare') {
    Guard-Volume ([long]$cfg.required_bytes)
    if ((Test-Path -LiteralPath $partial) -or (Test-Path -LiteralPath $final)) { throw 'generation_exists' }
    [void][IO.Directory]::CreateDirectory($base)
    Assert-NoReparse $base
    [void][IO.Directory]::CreateDirectory($partial)
    Guard-Volume ([long]$cfg.required_bytes)
    @{ok=$true;generation=[string]$cfg.generation} | ConvertTo-Json -Compress
    exit 0
}
if ($cfg.action -ne 'publish') { throw 'unknown_action' }
if (Test-Path -LiteralPath $final) { throw 'generation_exists' }
Verify-Generation $partial $cfg.expected
Guard-Volume
[IO.Directory]::Move($partial, $final)
$record = $cfg.expected
$record | Add-Member -NotePropertyName published_utc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
$temporary = Join-Path $base ('latest.' + [string]$cfg.generation + '.tmp')
if (Test-Path -LiteralPath $temporary) { throw 'latest_temporary_exists' }
Assert-NoReparse $latestPath
$stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $data = $Utf8.GetBytes(($record | ConvertTo-Json -Depth 30 -Compress))
    $stream.Write($data, 0, $data.Length)
    $stream.Flush($true)
} finally { $stream.Dispose() }
if (Test-Path -LiteralPath $latestPath) {
    [IO.File]::Replace($temporary, $latestPath, $null)
} else { [IO.File]::Move($temporary, $latestPath) }
Guard-Volume
@{ok=$true;generation=[string]$cfg.generation;manifest_sha256=[string]$record.manifest_sha256;
  published_utc=[string]$record.published_utc} | ConvertTo-Json -Compress
