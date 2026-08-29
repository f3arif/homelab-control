#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$shared=Join-Path $env:USERPROFILE 'OneDrive - AFZ Engineering Inc\AFZ Shared'
$priority=Join-Path $shared 'AFZ Priority'
$target=Join-Path $priority 'AFZ-Priority-Controller.ps1'
$backups=Join-Path $priority 'Backups'
$expectedSha256='A5AF34219AE4BE21174F50C5B6101BEA70ABEE406B6F9DC8DBE23C67F32A504D'
$oldVersion=@'
$controllerVersion = '5.4-hplaptop-bounded-wake-registry'
'@.Trim()
$newVersion=@'
$controllerVersion = '5.5-portable-normal-lenovo-wake'
'@.Trim()
$oldRoute='    $lenovoCandidate=Get-AFZLenovoCandidate'
$newRoute=@'
    # Portable auto work may wake Lenovo during normal routing rather than waiting for RAM pressure.
    # Existing bounded wake cooldown/readiness/AC/queue guards remain authoritative.
    $lenovoCandidate=Get-AFZLenovoCandidate -AllowWake
'@.TrimEnd("`r","`n")

if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "Priority controller missing: $target"}
New-Item -ItemType Directory -Force -Path $backups | Out-Null

$raw=[IO.File]::ReadAllText($target)
if($raw.Contains($newVersion) -and $raw.Contains('$lenovoCandidate=Get-AFZLenovoCandidate -AllowWake')){
  Write-Output 'STATUS=ALREADY_APPLIED'
  Write-Output ('TARGET='+$target)
  exit 0
}

$actual=(Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToUpperInvariant()
Write-Output ('SOURCE_SHA256='+$actual)
if($actual -ne $expectedSha256){throw "Source changed concurrently; expected $expectedSha256 got $actual"}

if(-not $raw.Contains($oldVersion)){throw 'Expected controller version marker not found'}
$matches=[regex]::Matches($raw,[regex]::Escape($oldRoute)).Count
if($matches -ne 1){throw "Expected exactly one normal Lenovo candidate line; found $matches"}

$candidate=$raw.Replace($oldVersion,$newVersion).Replace($oldRoute,$newRoute)
$tmp=$target+'.portable-wake.tmp'
$utf8Bom=New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($tmp,$candidate,$utf8Bom)
try {
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){
    $msg=(@($errors)|ForEach-Object{$_.Message}) -join ' | '
    throw ('Candidate PowerShell parse failed: '+$msg)
  }
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup=Join-Path $backups ("AFZ-Priority-Controller-before-portable-normal-wake-$stamp.ps1")
  Copy-Item -LiteralPath $target -Destination $backup -Force
  Move-Item -LiteralPath $tmp -Destination $target -Force
  $newHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToUpperInvariant()
  Write-Output 'STATUS=PASS'
  Write-Output ('BACKUP='+$backup)
  Write-Output ('NEW_SHA256='+$newHash)
  Write-Output 'CHANGE=Normal portable PowerShell routing now allows bounded Lenovo wake before ASUS fallback'
  Write-Output 'UNCHANGED=Lenovo executor allow-marker guard; HPLaptop marker guard; queue/resource/RAM guards; host pins; project priority; HP wake fail-closed registry'
} finally {
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
