[CmdletBinding()]
param([switch]$Apply,[switch]$PreflightOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root='C:\AFZ\Stremio-Failover-H3'
$stage=$PSScriptRoot
$live=Join-Path $root 'stremio_catalog.py'
$candidate=Join-Path $stage 'stremio_catalog.py'
$python=Join-Path $root '.venv\Scripts\python.exe'
$launcher=Join-Path $root 'Start-AFZ-Stremio-H3-Core243.ps1'
$expectedLive='889d370d3b960740e84a2d7878ccbef934248eddb5b1a2b8570128acf188d68c'
$expectedCandidate='d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f'
$state=[ordered]@{status='starting';phase='preflight';startedAtUtc=[DateTime]::UtcNow.ToString('o');sourceChanged=$false;coreStopped=$false;coreStopAttempted=$false;backup=$null;error=$null;rollbackError=$null;runtimeVerified=$false}
$report=Join-Path $stage 'deployment-result.json'
$lock=$null;$owned=$false;$writeAllowed=$false
function Save-State{
    if(-not $writeAllowed){return}
    $state.atUtc=[DateTime]::UtcNow.ToString('o')
    $temp=$report+'.tmp'
    [IO.File]::WriteAllText($temp,($state|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $report -Force
}
function Hash($path){return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()}
function Get-Core{
    $ids=@(Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 18774 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
    if($ids.Count -ne 1){throw 'CORE_LISTENER_GATE'}
    $core=Get-CimInstance Win32_Process -Filter "ProcessId=$($ids[0])"
    $parent=Get-CimInstance Win32_Process -Filter "ProcessId=$($core.ParentProcessId)"
    if($core.Name -notmatch '^python' -or $core.CommandLine -notlike '*stremio_catalog:app*'){throw 'CORE_COMMAND_GATE'}
    if(-not (($core.CommandLine -like "*$python*") -or ($parent -and $parent.CommandLine -like "*$python*" -and $parent.CommandLine -like '*stremio_catalog:app*'))){throw 'CORE_IDENTITY_GATE'}
    return $core
}
function Stop-Core{
    $core=Get-Core
    $parent=Get-CimInstance Win32_Process -Filter "ProcessId=$($core.ParentProcessId)"
    $ids=@($core.ProcessId)
    if($parent -and $parent.Name -match '^python' -and $parent.CommandLine -like '*stremio_catalog:app*'){$ids+=$parent.ProcessId}
    foreach($processId in ($ids|Select-Object -Unique)){if(Get-Process -Id $processId -ErrorAction SilentlyContinue){Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue}}
    $deadline=(Get-Date).AddSeconds(15)
    do{if(-not(Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 18774 -State Listen -ErrorAction SilentlyContinue)){return};Start-Sleep -Milliseconds 250}while((Get-Date) -lt $deadline)
    throw 'CORE_STOP_TIMEOUT'
}
function Start-Core{
    $started=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$launcher) -WorkingDirectory $root -RedirectStandardOutput (Join-Path $stage ($state.phase+'.stdout.log')) -RedirectStandardError (Join-Path $stage ($state.phase+'.stderr.log')) -PassThru
    $null=$started.Handle
    if(-not $started.WaitForExit(60000)){throw 'CORE_LAUNCHER_TIMEOUT'}
    $started.Refresh();if($started.ExitCode -ne 0){throw 'CORE_LAUNCHER_FAILED'}
    $null=Get-Core
    $m=Invoke-RestMethod 'http://127.0.0.1:18774/manifest.json' -TimeoutSec 10
    if($m.id -ne 'com.afzengineering.releasecatalog' -or $m.version -ne '0.6.243'){throw 'MANIFEST_GATE'}
}
try{
    $lock=[Threading.Mutex]::new($false,'Global\AFZ-Mobile-Recovery-20261001-Deployment')
    try{$owned=$lock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not $owned){throw 'OTHER_DEPLOYMENT_RUNNING'}
    if(Test-Path $report){$old=Get-Content -Raw $report|ConvertFrom-Json;if($old.status -in @('deployed','rolled-back','rollback-failed')){throw 'COMPLETED_ATTEMPT_REQUIRES_INSPECTION'}}
    $writeAllowed=$true
    Save-State
    if((Hash $live) -ne $expectedLive -or (Hash $candidate) -ne $expectedCandidate){throw 'SOURCE_HASH_GATE'}
    if((Hash $launcher) -ne '4dc89430589f76106bb4abb7d3de845ba10186c2f35046171d8661549e226f17'){throw 'LAUNCHER_HASH_GATE'}
    if((Hash (Join-Path $root 'bridge.mjs')) -ne '3474a7d985ae3a26ee1c7b46c518e1a06d55f3ca4cf3e3e2977ed88df48fa0eb'){throw 'BRIDGE_HASH_GATE'}
    $tests=Get-Content -Raw (Join-Path $stage 'test-result.json')|ConvertFrom-Json
    if(-not $tests.passed -or $tests.testsRun -ne 37 -or $tests.failures -ne 0 -or $tests.errors -ne 0){throw 'TEST_GATE'}
    $admin=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if(-not $admin){throw 'ADMINISTRATOR_REQUIRED'}
    $core=Get-Core;$state.beforeCorePid=$core.ProcessId
    $m=Invoke-RestMethod 'http://127.0.0.1:18774/manifest.json' -TimeoutSec 10
    if($m.id -ne 'com.afzengineering.releasecatalog' -or $m.version -ne '0.6.243'){throw 'MANIFEST_GATE'}
    $state.status='preflight-passed';Save-State
    if($PreflightOnly){return}
    if(-not $Apply){throw 'APPLY_SWITCH_REQUIRED'}
    & $python (Join-Path $stage 'verify_runtime.py') baseline
    if($LASTEXITCODE -ne 0){throw 'BASELINE_GATE'}
    if((Hash $live) -ne $expectedLive){throw 'SOURCE_CHANGED_DURING_PREFLIGHT'}
    $state.backup=Join-Path $stage ('backup-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'.py')
    Copy-Item -LiteralPath $live -Destination $state.backup
    $state.phase='stop-core';$state.coreStopAttempted=$true;Save-State;Stop-Core;$state.coreStopped=$true;Save-State
    $state.phase='replace-source';Save-State
    if((Hash $live) -ne $expectedLive){throw 'SOURCE_CHANGED_BEFORE_REPLACE'}
    Copy-Item -LiteralPath $candidate -Destination ($live+'.episode-identity-tmp')
    Move-Item -LiteralPath ($live+'.episode-identity-tmp') -Destination $live -Force
    $state.sourceChanged=$true;Save-State
    $state.phase='start-core';Save-State;Start-Core
    $state.phase='verify-runtime';Save-State
    & $python (Join-Path $stage 'verify_runtime.py')
    if($LASTEXITCODE -ne 0){throw 'RUNTIME_VERIFICATION_FAILED'}
    if((Hash $live) -ne $expectedCandidate){throw 'DEPLOYED_HASH_GATE'}
    $state.runtimeVerified=$true;$state.liveSha256=$expectedCandidate;$state.status='deployed';$state.phase='complete';Save-State
}catch{
    $state.error=$_.Exception.Message;$state.status='failed';if($owned){Save-State}
    if($state.sourceChanged -or $state.coreStopAttempted){
        try{
            $state.phase='rollback-stop';Save-State
            if(Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 18774 -State Listen -ErrorAction SilentlyContinue){Stop-Core}
            Copy-Item -LiteralPath $state.backup -Destination $live -Force
            $state.phase='rollback-start';Save-State;Start-Core
            if((Hash $live) -ne $expectedLive){throw 'ROLLBACK_HASH_GATE'}
            $state.status='rolled-back';Save-State
        }catch{$state.rollbackError=$_.Exception.Message;$state.status='rollback-failed';Save-State}
    }
    throw
}finally{
    if($owned){Save-State;$lock.ReleaseMutex()};if($lock){$lock.Dispose()}
    $state|ConvertTo-Json -Depth 5
}
