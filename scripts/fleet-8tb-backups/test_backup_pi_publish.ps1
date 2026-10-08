param(
    [Parameter(Mandatory=$true)][string]$TestRoot,
    [string]$VerifierPath = (Join-Path $PSScriptRoot 'backup_pi_verify.ps1')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Utf8 = [Text.UTF8Encoding]::new($false)

# Execute the receiver's actual publication block, only inside a fresh test directory.
$source = Get-Content -LiteralPath $VerifierPath -Raw -Encoding UTF8
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'receiver_parse_error' }
$assert = $ast.Find({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-NoReparse'
}, $false)
if ($null -eq $assert) { throw 'missing_reparse_guard' }
. ([ScriptBlock]::Create($assert.Extent.Text))
$start = $source.IndexOf('$temporary = Join-Path $base')
$end = $source.IndexOf("`nGuard-Volume", $start)
if ($start -lt 0 -or $end -le $start) { throw 'missing_publication_block' }
$publish = [ScriptBlock]::Create($source.Substring($start, $end - $start))
$base = Join-Path ([IO.Path]::GetFullPath($TestRoot)) ('publish-' + [Guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $base) { throw 'test_directory_exists' }
[void][IO.Directory]::CreateDirectory($base)
$latestPath = Join-Path $base 'latest.json'
$sentinel = Join-Path $base 'existing-generation.txt'
[IO.File]::WriteAllText($sentinel, 'preserve-existing-generation', $Utf8)

foreach ($generation in @('first', 'second', 'third')) {
    $cfg = [pscustomobject]@{generation=$generation}
    $record = [pscustomobject]@{generation=$generation; value=('receipt-' + $generation)}
    & $publish
    $actual = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($actual.generation -cne $generation -or $actual.value -cne $record.value) { throw 'publication_content' }
    if (Test-Path -LiteralPath (Join-Path $base ('latest.' + $generation + '.tmp'))) { throw 'temporary_not_consumed' }
}

# A Windows sharing violation must preserve the previous pointer and failed temporary.
$cfg = [pscustomobject]@{generation='blocked'}
$record = [pscustomobject]@{generation='blocked'; value='must-not-publish'}
$before = [IO.File]::ReadAllText($latestPath)
$hold = [IO.File]::Open($latestPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
$failed = $false
try { try { & $publish } catch { $failed = $true } } finally { $hold.Dispose() }
if (!$failed) { throw 'locked_target_unexpectedly_replaced' }
if ([IO.File]::ReadAllText($latestPath) -cne $before) { throw 'failed_publication_changed_pointer' }
if (!(Test-Path -LiteralPath (Join-Path $base 'latest.blocked.tmp'))) { throw 'failed_temporary_lost' }
if ([IO.File]::ReadAllText($sentinel) -cne 'preserve-existing-generation') { throw 'existing_generation_changed' }
@{ok=$true; first_publish=$true; repeated_publish=$true; locked_target_preserved=$true;
  test_directory=$base; powershell_version=$PSVersionTable.PSVersion.ToString()} | ConvertTo-Json -Compress
