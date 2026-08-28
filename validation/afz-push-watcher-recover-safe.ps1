function Invoke-AFZGithubPushWatcherRecoverSafe {
    param($Config,$Job)
    $taskName='AFZ OpenAI Agent Push Deploy Watcher'
    $expectedScript='C:\AFZ\homelab-control\afz-openai-agent\Push-Deploy-Watcher.ps1'
    $expectedInstallRoot='C:\AFZ\homelab-control'
    $summary=New-Object System.Collections.Generic.List[string]
    $summary.Add('AFZ GitHub Push Watcher Recovery : BOUNDED')
    $summary.Add("Task                         : $taskName")

    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $action=@($task.Actions | Select-Object -First 1)
    if(-not $action -or [string]::IsNullOrWhiteSpace([string]$action.Execute)){
        throw 'Push watcher task has no executable action.'
    }
    $execute=[string]$action.Execute
    $args=[string]$action.Arguments
    $scriptPattern=[regex]::Escape($expectedScript)
    $rootPattern=[regex]::Escape($expectedInstallRoot)
    if($execute -notmatch '(?i)(^|\\)powershell[.]exe$'){
        throw "Push watcher task executable is unexpected: $execute"
    }
    if($args -notmatch $scriptPattern -or $args -notmatch $rootPattern -or $args -notmatch '(?i)-IntervalSeconds\s+3(?:\s|$)'){
        throw 'Push watcher task arguments do not match the fixed AFZ GitHub watcher contract.'
    }

    $before=[string]$task.State
    $procsBefore=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ([string]$_.CommandLine) -match $scriptPattern
    })
    $started=$false
    if($before -ne 'Running' -and $procsBefore.Count -eq 0){
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $started=$true
    }

    $deadline=(Get-Date).AddSeconds(8)
    do{
        Start-Sleep -Milliseconds 500
        $afterTask=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $procsAfter=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            ([string]$_.CommandLine) -match $scriptPattern
        })
        if([string]$afterTask.State -eq 'Running' -or $procsAfter.Count -gt 0){break}
    }while((Get-Date) -lt $deadline)

    $after=[string]$afterTask.State
    $consumerAlive=($after -eq 'Running' -or $procsAfter.Count -gt 0)
    $sourceState='C:\ProgramData\AFZ\OpenAIAgent\source-state.json'
    $pushState='C:\ProgramData\AFZ\OpenAIAgent\push-watcher.json'
    $source=''
    $signal=''
    try{if(Test-Path -LiteralPath $sourceState){$source=[string]((Get-Content -LiteralPath $sourceState -Raw|ConvertFrom-Json).remoteSha)}}catch{}
    try{if(Test-Path -LiteralPath $pushState){$signal=[string]((Get-Content -LiteralPath $pushState -Raw|ConvertFrom-Json).signalSha)}}catch{}

    $summary.Add("Task state before             : $before")
    $summary.Add("Task start requested          : $started")
    $summary.Add("Task state after              : $after")
    $summary.Add("Watcher processes after       : $($procsAfter.Count)")
    $summary.Add("Consumer alive                : $consumerAlive")
    $summary.Add("Current source SHA            : $source")
    $summary.Add("Last watcher signal SHA       : $signal")
    $summary.Add('Deployment request/site/Pi    : NOT DIRECTLY MODIFIED')
    if(-not $consumerAlive){throw 'AFZ GitHub push watcher did not remain alive after bounded start attempt.'}
    return [ordered]@{
        action='afz-github-push-watcher-recover-safe'
        ok=$true
        bridgeOk=$true
        verified=$true
        started=$started
        taskStateBefore=$before
        taskStateAfter=$after
        watcherProcessCount=$procsAfter.Count
        currentSourceSha=$source
        lastSignalSha=$signal
        summary=$summary
    }
}
