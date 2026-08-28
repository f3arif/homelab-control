function Invoke-AFZSiteR5HungSshAbortSafe {
    param($Config,$Job)
    $jobId='afz-site-git-cutover-r5-20260828T1151'
    $siteSha='c38576741ce2d379723fde038300363429845656'
    $pi='192.168.50.68'
    $resultFile='C:\Users\Faiz\AppData\Local\AFZ\WebsiteGitDeploy\latest.json'
    $watcherStateFile='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-site-deploy\request-watcher.json'
    $summary=New-Object System.Collections.Generic.List[string]
    $summary.Add('AFZ Website R5 Hung SSH Abort : BOUNDED')
    $summary.Add("Expected job                 : $jobId")
    $summary.Add("Expected site SHA            : $siteSha")

    if(-not(Test-Path -LiteralPath $watcherStateFile -PathType Leaf)){throw 'Website deploy watcher state is missing.'}
    $watch=Get-Content -LiteralPath $watcherStateFile -Raw -ErrorAction Stop | ConvertFrom-Json
    if([string]$watch.status -ne 'deploying' -or [string]$watch.jobId -ne $jobId -or ([string]$watch.expectedSiteSha).ToLowerInvariant() -ne $siteSha){
        throw 'Website deploy watcher is not in the exact R5 deploying state; abort refused.'
    }
    if(Test-Path -LiteralPath $resultFile -PathType Leaf){
        $existing=$null
        try{$existing=Get-Content -LiteralPath $resultFile -Raw -ErrorAction Stop | ConvertFrom-Json}catch{}
        if($existing -and [string]$existing.jobId -eq $jobId){
            throw 'R5 already has a terminal/result file; abort refused.'
        }
    }

    $all=@(Get-CimInstance Win32_Process -ErrorAction Stop)
    $core=@($all | Where-Object {
        [string]$_.Name -ieq 'powershell.exe' -and
        ([string]$_.CommandLine) -match '(?i)Deploy-AFZ-WebsiteToPi-Core[.]ps1' -and
        ([string]$_.CommandLine) -match [regex]::Escape($jobId) -and
        ([string]$_.CommandLine) -match $siteSha
    })
    if($core.Count -ne 1){throw "Expected exactly one R5 core PowerShell process; found $($core.Count)."}

    $ssh=@($all | Where-Object {
        [string]$_.Name -ieq 'ssh.exe' -and
        [int]$_.ParentProcessId -eq [int]$core[0].ProcessId -and
        ([string]$_.CommandLine) -match [regex]::Escape($pi) -and
        ([string]$_.CommandLine) -match '(?i)mkdir -p' -and
        ([string]$_.CommandLine) -match [regex]::Escape('/opt/edge/afz-site/git-deploy/stage') -and
        ([string]$_.CommandLine) -match [regex]::Escape('/opt/edge/afz-site/git-deploy/backups')
    })
    if($ssh.Count -ne 1){throw "Expected exactly one R5 staging SSH child; found $($ssh.Count)."}

    $created=[Management.ManagementDateTimeConverter]::ToDateTime([string]$ssh[0].CreationDate)
    $age=[math]::Round(((Get-Date)-$created).TotalSeconds,1)
    if($age -lt 120){throw "R5 SSH child age is only ${age}s; bounded abort requires at least 120s."}

    $summary.Add("Core PID                     : $($core[0].ProcessId)")
    $summary.Add("SSH PID                      : $($ssh[0].ProcessId)")
    $summary.Add("SSH age seconds              : $age")
    $summary.Add('Verified command             : exact R5 staging mkdir only')
    $summary.Add('Pi promotion marker          : not touched by this action')

    Stop-Process -Id ([int]$ssh[0].ProcessId) -Force -ErrorAction Stop
    $deadline=(Get-Date).AddSeconds(10)
    $still=$null
    do{
        Start-Sleep -Milliseconds 500
        $still=Get-Process -Id ([int]$ssh[0].ProcessId) -ErrorAction SilentlyContinue
        if(-not $still){break}
    }while((Get-Date) -lt $deadline)
    if($still){throw 'R5 SSH child remained alive after bounded stop.'}

    $summary.Add('SSH child stopped            : true')
    $summary.Add('Parent deploy process         : NOT directly stopped')
    $summary.Add('Carrier/legacy restoration    : delegated to existing R5 watcher failure path')
    return [ordered]@{
        action='afz-site-r5-hung-ssh-abort-safe'
        ok=$true
        bridgeOk=$true
        verified=$true
        jobId=$jobId
        corePid=[int]$core[0].ProcessId
        sshPid=[int]$ssh[0].ProcessId
        sshAgeSeconds=$age
        summary=@($summary)
    }
}
