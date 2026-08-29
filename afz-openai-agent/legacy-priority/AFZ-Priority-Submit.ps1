param(
  [Parameter(Mandatory=$true)][string]$Project,
  [ValidateSet('critical','urgent','high','normal','low')][string]$Urgency='normal',
  [string]$PayloadPath,
  [string]$Description='',
  [ValidateSet('auto','asus','windows-main','lenovo','hplaptop','hpenvy','pi','h3')][string]$Worker='auto',
  [switch]$PortableWindows,
  [switch]$NoPortableWindows,
  [switch]$HostPinned,
  [switch]$PortableLinux,
  [switch]$SafeToPreempt,
  [switch]$H3Restricted
)

$ErrorActionPreference='Stop'
$shared = Join-Path $env:USERPROFILE 'OneDrive - AFZ Engineering Inc\AFZ Shared'
$priorityRoot = Join-Path $shared 'AFZ Priority'
$inbox = Join-Path $priorityRoot 'Inbox'
$configPath = Join-Path $priorityRoot 'Projects.json'

if(-not (Test-Path $configPath)){ throw "Missing priority config: $configPath" }
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$proj = $config.projects.$Project
if($null -eq $proj){ throw "Unknown project '$Project'. Add it to Projects.json first." }

function Test-AFZAutoPortableWindowsPayload {
  param([string]$Path)
  if([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)){ return $false }
  if([IO.Path]::GetExtension($Path).ToLowerInvariant() -ne '.ps1'){ return $false }
  try {
    $raw=Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $hostLocalPatterns=@(
      '(?im)^\s*#\s*AFZ_(?:HOST_PINNED|LOCAL_HARDWARE)\s*=\s*1\s*$',
      '(?im)^# SIG # Begin signature block',
      '(?i)\b(?:adb|fastboot)(?:\.exe)?\b',
      '(?i)\b(?:Get|Set|Start|Stop|Register|Unregister)-ScheduledTask\b',
      '(?i)\b(?:Get|Set|Start|Stop|Restart)-Service\b',
      '(?i)\b(?:localhost|127\.0\.0\.1)\b',
      '(?i)\bDESKTOP-10SKF0M\b',
      '(?i)[A-Z]:\\'
    )
    foreach($pattern in $hostLocalPatterns){ if($raw -match $pattern){ return $false } }
    return $true
  } catch { return $false }
}

function Write-AFZPortableWindowsPayloadCopy {
  param([string]$Source,[string]$Destination)
  $raw=Get-Content -LiteralPath $Source -Raw -ErrorAction Stop
  if($raw -match '(?im)^# SIG # Begin signature block'){ throw 'Signed PowerShell payloads cannot be rewritten for portable worker execution; submit with -HostPinned or use an explicit worker-specific signed deployment.' }
  $markers=[System.Collections.Generic.List[string]]::new()
  if($raw -notmatch '(?im)^\s*#\s*AFZ_LENOVO_ALLOWED\s*=\s*1\s*$'){ [void]$markers.Add('# AFZ_LENOVO_ALLOWED=1') }
  if($raw -notmatch '(?im)^\s*#\s*AFZ_HPLAPTOP_ALLOW\s*=\s*1\s*$'){ [void]$markers.Add('# AFZ_HPLAPTOP_ALLOW=1') }
  if($raw -notmatch '(?im)^\s*#\s*AFZ_PORTABLE_WINDOWS\s*=\s*1\s*$'){ [void]$markers.Add('# AFZ_PORTABLE_WINDOWS=1') }
  if($markers.Count -gt 0){ $raw=($markers -join "`r`n")+"`r`n"+$raw }
  [IO.File]::WriteAllText($Destination,$raw,(New-Object Text.UTF8Encoding($false)))
}

$h3AllowedActions=@(
  'h3-status','h3-powershell-parse','h3-json-validate','h3-python-compile','h3-file-hash',
  'h3-dotnet-build','h3-npm-build','h3-npm-test','h3-tsc'
)

if($H3Restricted){
  if([string]::IsNullOrWhiteSpace($PayloadPath)){ throw 'H3Restricted requires PayloadPath.' }
  if($Worker -notin @('auto','h3')){ throw 'H3Restricted jobs must use Worker auto or h3.' }
  if([IO.Path]::GetExtension($PayloadPath).ToLowerInvariant() -ne '.json'){
    throw 'H3Restricted jobs require a .json payload. Generic PowerShell/script payloads are not allowed.'
  }
  if(-not (Test-Path $PayloadPath -PathType Leaf)){ throw "Payload not found: $PayloadPath" }
  try { $h3Envelope=Get-Content $PayloadPath -Raw | ConvertFrom-Json -ErrorAction Stop }
  catch { throw ('Invalid H3 JSON envelope: '+$_.Exception.Message) }
  $h3Action=[string]$h3Envelope.action
  $h3Id=[string]$h3Envelope.id
  if([string]::IsNullOrWhiteSpace($h3Id)){ throw 'H3 JSON envelope requires id.' }
  if($h3Action -notin $h3AllowedActions){ throw "H3 action not allowlisted: $h3Action" }
}

$slug = ($Project.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$id = "$stamp-$slug-" + ([guid]::NewGuid().ToString('N').Substring(0,8))

$payloadName = $null
$effectivePortableWindows=$false
$effectiveHostPinned=[bool]$HostPinned
$portabilityReason='not-windows-powershell'
if($PayloadPath){
  if(-not (Test-Path $PayloadPath)){ throw "Payload not found: $PayloadPath" }
  $ext = [IO.Path]::GetExtension($PayloadPath)
  $base = [IO.Path]::GetFileNameWithoutExtension($PayloadPath)
  $payloadName = "$id-$base$ext"
  $payloadDst=Join-Path $inbox $payloadName

  if($ext.ToLowerInvariant() -eq '.ps1'){
    if($HostPinned -and $PortableWindows){ throw 'HostPinned and PortableWindows are mutually exclusive.' }
    if($Worker -in @('asus','windows-main')){
      $effectiveHostPinned=$true
      $portabilityReason='explicit-local-worker'
    } elseif($Worker -in @('lenovo','hplaptop')){
      $effectivePortableWindows=$true
      $portabilityReason='explicit-portable-worker'
    } elseif($PortableWindows){
      $effectivePortableWindows=$true
      $portabilityReason='explicit-portable-windows'
    } elseif($HostPinned -or $NoPortableWindows){
      $effectiveHostPinned=$true
      $portabilityReason=$(if($HostPinned){'explicit-host-pinned'}else{'explicit-no-portable-windows'})
    } elseif($Worker -eq 'auto' -and (Test-AFZAutoPortableWindowsPayload -Path $PayloadPath)){
      $effectivePortableWindows=$true
      $portabilityReason='auto-portable-safe-payload'
    } elseif($Worker -eq 'auto'){
      $effectiveHostPinned=$true
      $portabilityReason='auto-host-local-safety-classifier'
    }
  }

  if($effectivePortableWindows -and $ext.ToLowerInvariant() -eq '.ps1'){
    Write-AFZPortableWindowsPayloadCopy -Source $PayloadPath -Destination $payloadDst
  } else {
    Copy-Item $PayloadPath $payloadDst -Force
  }
}

$meta = [ordered]@{
  schema = 2
  taskId = $id
  project = $Project
  projectRank = [int]$proj.rank
  urgency = $Urgency
  createdAt = (Get-Date).ToString('o')
  description = $Description
  requestedWorker = $Worker
  portableWindows = [bool]$effectivePortableWindows
  hostPinned = [bool]$effectiveHostPinned
  portabilityReason = $portabilityReason
  portableLinux = [bool]$PortableLinux
  safeToPreempt = [bool]$SafeToPreempt
  h3Restricted = [bool]$H3Restricted
  payloadName = $payloadName
  destinationQueue = [string]$proj.queuePath
  status = 'queued'
}

$tmp = Join-Path $inbox ($id + '.json.tmp')
$dst = Join-Path $inbox ($id + '.json')
$meta | ConvertTo-Json -Depth 8 | Set-Content $tmp -Encoding UTF8
Move-Item $tmp $dst -Force

Write-Output 'AFZ_PRIORITY_QUEUED'
Write-Output "TaskId=$id"
Write-Output "Project=$Project"
Write-Output "Rank=$($proj.rank)"
Write-Output "Urgency=$Urgency"
Write-Output "Worker=$Worker"
Write-Output "PortableWindows=$([bool]$effectivePortableWindows)"
Write-Output "HostPinned=$([bool]$effectiveHostPinned)"
Write-Output "PortabilityReason=$portabilityReason"
Write-Output "PortableLinux=$([bool]$PortableLinux)"
Write-Output "SafeToPreempt=$([bool]$SafeToPreempt)"
Write-Output "H3Restricted=$([bool]$H3Restricted)"
