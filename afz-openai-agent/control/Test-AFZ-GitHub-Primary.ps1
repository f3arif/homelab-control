#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\AFZ\homelab-control'
)

$ErrorActionPreference = 'Continue'
$repo = 'f3arif/homelab-control'
$signalUrl = 'https://raw.githubusercontent.com/f3arif/homelab-control/main/.github/afz-agent-deploy-signal.txt'
$stateRoot = 'C:\ProgramData\AFZ\OpenAIAgent'

Write-Output 'AFZ_GITHUB_PRIMARY_TEST=START'
Write-Output ("TIME={0}" -f (Get-Date -Format o))
Write-Output ("COMPUTER={0}" -f $env:COMPUTERNAME)

Write-Output '--- LOCAL_REPO ---'
if (Test-Path (Join-Path $InstallRoot '.git')) {
    Write-Output 'LOCAL_REPO_PRESENT=True'
    Push-Location $InstallRoot
    try {
        $remote = (& git remote get-url origin 2>&1 | Out-String).Trim()
        $branch = (& git branch --show-current 2>&1 | Out-String).Trim()
        $head = (& git rev-parse HEAD 2>&1 | Out-String).Trim()
        Write-Output ("REMOTE={0}" -f $remote)
        Write-Output ("BRANCH={0}" -f $branch)
        Write-Output ("HEAD={0}" -f $head)
        & git fetch --quiet origin main 2>&1 | ForEach-Object { Write-Output ("GIT_FETCH={0}" -f $_) }
        Write-Output ("FETCH_EXIT={0}" -f $LASTEXITCODE)
        $originMain = (& git rev-parse origin/main 2>&1 | Out-String).Trim()
        Write-Output ("ORIGIN_MAIN={0}" -f $originMain)
    }
    finally { Pop-Location }
}
else {
    Write-Output 'LOCAL_REPO_PRESENT=False'
}

Write-Output '--- FAST_SIGNAL ---'
try {
    $nonce = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $headers = @{'User-Agent'='AFZ-GitHub-Primary-Test';'Cache-Control'='no-cache';'Pragma'='no-cache'}
    $response = Invoke-WebRequest -Uri ($signalUrl + '?nocache=' + $nonce) -Headers $headers -UseBasicParsing -TimeoutSec 10
    $signal = ([string]$response.Content).Trim()
    Write-Output ("SIGNAL_HTTP={0}" -f [int]$response.StatusCode)
    Write-Output ("SIGNAL_SHA={0}" -f $signal)
    Write-Output ("SIGNAL_VALID={0}" -f ($signal -match '^[0-9a-fA-F]{40}$'))
}
catch {
    Write-Output ("SIGNAL_ERROR={0}" -f $_.Exception.Message)
}

Write-Output '--- AGENT_TASKS ---'
$patterns = @(
    'AFZ OpenAI Agent',
    'AFZ OpenAI Agent Control',
    'AFZ OpenAI Agent Push Deploy Watcher',
    'AFZ OpenAI Agent Updater',
    'AFZ Control V2 Worker',
    'AFZ Direct State Cache',
    'AFZ Remote Ops',
    'AFZ WindowsMain Worker'
)
foreach ($name in $patterns) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
        Write-Output ("TASK|{0}|STATE={1}|LAST_RESULT={2}" -f $name,$task.State,$info.LastTaskResult)
    }
    else {
        Write-Output ("TASK|{0}|NOT_FOUND" -f $name)
    }
}

Write-Output '--- AGENT_STATE ---'
foreach ($file in @('source-state.json','push-watcher.json')) {
    $path = Join-Path $stateRoot $file
    if (Test-Path $path) {
        Write-Output ("STATE_FILE={0}" -f $file)
        try {
            Get-Content -LiteralPath $path -Raw | Write-Output
        }
        catch {
            Write-Output ("STATE_READ_ERROR={0}" -f $_.Exception.Message)
        }
    }
    else {
        Write-Output ("STATE_FILE_MISSING={0}" -f $file)
    }
}

Write-Output 'CHANGES=NONE'
Write-Output 'AFZ_GITHUB_PRIMARY_TEST=END'
