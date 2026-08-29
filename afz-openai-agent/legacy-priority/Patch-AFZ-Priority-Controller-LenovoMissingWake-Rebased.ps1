#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$shared='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared'
$priority=Join-Path $shared 'AFZ Priority'
$target=Join-Path $priority 'AFZ-Priority-Controller.ps1'
$backups=Join-Path $priority 'Backups'
$expectedSha256='13910DFD69C3A6539DC3BF80424780C9DCF3F28FFA82D3D194FC7EFF31B0805C'
$oldVersion=@'
$controllerVersion = '5.6-hplaptop-live-recovery'
'@.Trim()
$newVersion=@'
$controllerVersion = '5.7-lenovo-missing-state-wake'
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
  Write-Output 'CHANGE=Bounded Lenovo wake is attempted when Direct-State readiness is stale OR missing during portable routing'
  Write-Output 'UNCHANGED=Wake API preflight; cooldown; bounded wait; AC/eligibility gate; Lenovo allow marker; HPLaptop live-probe logic; host pins; project priority; resource/RAM guards'
} finally {
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
