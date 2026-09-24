#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ExpectedHost = 'DESKTOP-H3R6CQN'
$ProfileRoot = 'C:\AFZ\HermesProfiles\afz-blog-oauth-only'
$Hermes = Join-Path $env:LOCALAPPDATA 'hermes\bin\hermes.exe'
$StateRoot = 'C:\ProgramData\AFZ\HermesBlogOAuth'
$StatePath = Join-Path $StateRoot 'device-auth-latest.json'
$Utf8 = New-Object Text.UTF8Encoding($false)

function Emit($Object, [int]$Code = 0) {
  $json = $Object | ConvertTo-Json -Depth 10 -Compress
  Write-Output $json
  exit $Code
}

function Strip-Ansi([string]$Text) {
  return [regex]::Replace([string]$Text, "`e\[[0-?]*[ -/]*[@-~]", '')
}

function Parse-Device([string]$Text) {
  $clean = Strip-Ansi $Text
  $url = $null
  $code = $null

  $m = [regex]::Match(
    $clean,
    'https://auth\.openai\.com/codex/device(?:\?[^\s]+)?',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  if ($m.Success) {
    $url = $m.Value.TrimEnd('.', ',', ')', ']')
  }

  $m = [regex]::Match(
    $clean,
    '\b[A-Z0-9]{4}-[A-Z0-9]{5}\b',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  if ($m.Success) {
    $code = $m.Value.ToUpperInvariant()
  }

  return [ordered]@{
    url = $url
    code = $code
  }
}

if ($env:COMPUTERNAME -ne $ExpectedHost) {
  Emit ([ordered]@{
    schema = 1
    ok = $false
    classification = 'WRONG_HOST'
    host = $env:COMPUTERNAME
    secretValuesEmitted = $false
  }) 40
}

if (-not (Test-Path -LiteralPath $ProfileRoot -PathType Container)) {
  Emit ([ordered]@{
    schema = 1
    ok = $false
    classification = 'DEDICATED_PROFILE_MISSING'
    profile = $ProfileRoot
    secretValuesEmitted = $false
  }) 41
}

if (-not (Test-Path -LiteralPath $Hermes -PathType Leaf)) {
  Emit ([ordered]@{
    schema = 1
    ok = $false
    classification = 'HERMES_CLI_MISSING'
    secretValuesEmitted = $false
  }) 42
}

New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

# Reuse a still-running device-auth attempt when possible.
if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
  try {
    $prior = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $pidValue = [int]$prior.pid
    $alive = $false
    if ($pidValue -gt 0) {
      $alive = $null -ne (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)
    }

    if ($alive -and $prior.deviceUrl -and $prior.deviceCode) {
      Emit ([ordered]@{
        schema = 1
        ok = $true
        classification = 'AUTH_DEVICE_CODE_READY'
        host = $ExpectedHost
        profile = $ProfileRoot
        provider = 'openai-codex'
        deviceUrl = [string]$prior.deviceUrl
        deviceCode = [string]$prior.deviceCode
        pid = $pidValue
        reusedExistingAttempt = $true
        providerSwitched = $false
        generationStarted = $false
        secretValuesEmitted = $false
      }) 0
    }
  }
  catch {
    # Ignore stale/malformed state and start a fresh attempt.
  }
}

$stamp = Get-Date -Format 'yyyyMMddTHHmmssZ'
$outPath = Join-Path $StateRoot "device-auth-$stamp.out.log"
$errPath = Join-Path $StateRoot "device-auth-$stamp.err.log"

$oldHome = $env:HERMES_HOME
try {
  $env:HERMES_HOME = $ProfileRoot

  $process = Start-Process `
    -FilePath $Hermes `
    -ArgumentList @('auth', 'add', 'openai-codex') `
    -RedirectStandardOutput $outPath `
    -RedirectStandardError $errPath `
    -WindowStyle Hidden `
    -PassThru
}
finally {
  if ($null -eq $oldHome) {
    Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue
  }
  else {
    $env:HERMES_HOME = $oldHome
  }
}

$deadline = (Get-Date).AddSeconds(20)
$device = $null
$text = ''

do {
  Start-Sleep -Milliseconds 500

  $parts = @()
  if (Test-Path -LiteralPath $outPath -PathType Leaf) {
    $parts += Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $errPath -PathType Leaf) {
    $parts += Get-Content -LiteralPath $errPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  }

  $text = ($parts -join [Environment]::NewLine)
  $device = Parse-Device $text

  if ($device.url -and $device.code) {
    break
  }

  $process.Refresh()
  if ($process.HasExited) {
    break
  }
}
while ((Get-Date) -lt $deadline)

if (-not ($device.url -and $device.code)) {
  try {
    $process.Refresh()
    if (-not $process.HasExited) {
      Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
  }
  catch {}

  $safeTail = Strip-Ansi $text
  if ($safeTail.Length -gt 1600) {
    $safeTail = $safeTail.Substring($safeTail.Length - 1600)
  }

  Emit ([ordered]@{
    schema = 1
    ok = $false
    classification = 'AUTH_DEVICE_CODE_NOT_EMITTED'
    host = $ExpectedHost
    profile = $ProfileRoot
    provider = 'openai-codex'
    pid = $process.Id
    safeOutputTail = $safeTail
    providerSwitched = $false
    generationStarted = $false
    secretValuesEmitted = $false
  }) 43
}

$state = [ordered]@{
  schema = 1
  ok = $true
  classification = 'AUTH_DEVICE_CODE_READY'
  host = $ExpectedHost
  profile = $ProfileRoot
  provider = 'openai-codex'
  deviceUrl = $device.url
  deviceCode = $device.code
  pid = $process.Id
  stdoutPath = $outPath
  stderrPath = $errPath
  startedAt = (Get-Date -Format o)
  providerSwitched = $false
  generationStarted = $false
  secretValuesEmitted = $false
}

[IO.File]::WriteAllText(
  $StatePath,
  ($state | ConvertTo-Json -Depth 10),
  $Utf8
)

Emit $state 0
