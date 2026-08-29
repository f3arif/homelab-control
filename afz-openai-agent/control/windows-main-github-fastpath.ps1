#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\AFZ\homelab-control',
    [int]$IntervalSeconds = 3
)

$ErrorActionPreference = 'Stop'
$IntervalSeconds = [Math]::Max(2,[Math]::Min($IntervalSeconds,30))
$stateRoot = 'C:\ProgramData\AFZ\GitHubFastPath'
$stateFile = Join-Path $stateRoot 'windows-main.json'
$logFile = Join-Path $stateRoot 'windows-main.log'
$signalUrl = 'https://raw.githubusercontent.com/f3arif/homelab-control/main/.github/afz-agent-deploy-signal.txt'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Write-Log([string]$Message) {
    Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8
}

function Save-State([string]$Status,[string]$Signal,[string]$Detail) {
    [ordered]@{
        schema = 'afz-github-fastpath-v1'
        worker = 'windows-main'
        status = $Status
        signal = $Signal
        detail = $Detail
        intervalSeconds = $IntervalSeconds
        timestamp = (Get-Date -Format o)
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stateFile -Encoding UTF8
}

$mutex = New-Object Threading.Mutex($false,'Global\AFZWindowsMainGitHubFastPath')
$locked = $false
try {
    $locked = $mutex.WaitOne(0)
    if (-not $locked) { exit 0 }
    Write-Log "START interval=${IntervalSeconds}s"
    $lastSignal = ''
    while ($true) {
        try {
            $nonce = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $headers = @{'User-Agent'='AFZ-WindowsMain-GitHubFastPath';'Cache-Control'='no-cache';'Pragma'='no-cache'}
            $response = Invoke-WebRequest -Uri ($signalUrl + '?nocache=' + $nonce) -Headers $headers -UseBasicParsing -TimeoutSec 10
            $signal = ([string]$response.Content).Trim().ToLowerInvariant()
            if ($signal -notmatch '^[0-9a-f]{40}$') { throw "Invalid signal payload: $signal" }
            if ($signal -ne $lastSignal) {
                $lastSignal = $signal
                Save-State 'READY' $signal 'GitHub fast signal reachable. Live execution remains Direct Fabric/typed AFZ agent authority.'
                Write-Log "SIGNAL $signal"
            }
        }
        catch {
            Save-State 'DEGRADED' '' $_.Exception.Message
            Write-Log "ERROR $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    if ($locked) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
}
