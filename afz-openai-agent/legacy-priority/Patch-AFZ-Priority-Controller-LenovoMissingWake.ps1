#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$shared='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared'
$priority=Join-Path $shared 'AFZ Priority'
$target=Join-Path $priority 'AFZ-Priority-Controller.ps1'
$backups=Join-Path $priority 'Backups'
$expectedSha256='916ABA18157D6A478CC177D405C5E16D756F8258DE5B56A293A5D3B875A6DD29'
$oldVersion=@'
$controllerVersion = '5.5-portable-normal-lenovo-wake'
'@.Trim()
$newVersion=@'
$controllerVersion = '5.6-lenovo-missing-state-wake'
'@.Trim()
$oldCondition='    if(-not $st.ready -and $AllowWake -and $st.exists -and (-not $st.fresh)){'
$newCondition='    if(-not $st.ready -and $AllowWake -and (-not $st.fresh)){'

if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "Priority controller missing: $target"}
New-Item -ItemType Directory -Force -Path $backups | Out-Null
$raw=[IO.File]::ReadAllText($target)
if($raw.Contains($newVersion) -and $raw.Contains($newCondition)){
  Write-Output 'STATUS=ALREADY_APPLIED'
  exit 0
}
$actual=(Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToUpperInvariant()
Write-Output ('SOURCE_SHA256='+$actual)
if($actual -ne $expectedSha256){throw "Source changed concurrently; expected $expectedSha256 got $actual"}
if(-not $raw.Contains($oldVersion)){throw 'Expected controller version marker not found'}
$matches=[regex]::Matches($raw,[regex]::Escape($oldCondition)).Count
if($matches -ne 1){throw "Expected exactly one Lenovo stale-state wake condition; found $matches"}
$candidate=$raw.Replace($oldVersion,$newVersion).Replace($oldCondition,$newCondition)
$tmp=$target+'.lenovo-missing-wake.tmp'
$utf8Bom=New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($tmp,$candidate,$utf8Bom)
try {
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){throw ('Candidate PowerShell parse failed: '+((@($errors)|ForEach-Object{$_.Message}) -join ' | '))}
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup=Join-Path $backups ("AFZ-Priority-Controller-before-lenovo-missing-wake-$stamp.ps1")
  Copy-Item -LiteralPath $target -Destination $backup -Force
  Move-Item -LiteralPath $tmp -Destination $target -Force
  Write-Output 'STATUS=PASS'
  Write-Output ('BACKUP='+$backup)
  Write-Output ('NEW_SHA256='+((Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToUpperInvariant()))
  Write-Output 'CHANGE=Bounded Lenovo wake is now attempted for stale OR missing Direct-State readiness during portable routing'
  Write-Output 'UNCHANGED=Wake API preflight; cooldown; bounded wait; AC/eligibility gate; worker allow markers; host pins; HP wake fail-closed; resource/RAM guards'
} finally {
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
