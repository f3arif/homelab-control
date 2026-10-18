# Runs only the existing protected public edge; does not start or reconfigure other services.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$stateRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
$root='C:\AFZ\Stremio-Failover-H3'
$python=Join-Path $root '.venv\Scripts\python.exe'
$source=Join-Path $root 'afz_public_proxy.py'
$tokenFile=Join-Path $root 'state\public-transport-token.txt'
foreach($file in @($python,$source,$tokenFile)){if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw 'PUBLIC_EDGE_DEPENDENCY_MISSING'}}
$token=(Get-Content -LiteralPath $tokenFile -Raw).Trim()
if($token -notmatch '^[A-Za-z0-9_-]{24,256}$'){throw 'PUBLIC_EDGE_TOKEN_INVALID'}
$existing=Get-NetTCPConnection -State Listen -LocalPort 18773 -ErrorAction SilentlyContinue | Select-Object -First 1
if($existing){
 $owner=Get-CimInstance Win32_Process -Filter ("ProcessId="+$existing.OwningProcess)
 if(-not $owner -or $owner.Name -notmatch '^python' -or $owner.CommandLine -notmatch '(?i)(^|\s)afz_public_proxy:app(\s|$)'){throw 'PUBLIC_EDGE_PORT_OWNED_BY_ANOTHER_SERVICE'}
 # Avoid duplicate children if the scheduler restarts its parent while a valid child survives.
 Wait-Process -Id $owner.ProcessId -ErrorAction SilentlyContinue
 exit 1
}
$env:AFZ_PUBLIC_UPSTREAM='http://127.0.0.1:18774'
$env:AFZ_PUBLIC_PREFIX=$token
$env:AFZ_PUBLIC_BASE='https://desktop-h3r6cqn.tailc9bb62.ts.net:10000/'+$token
$env:AFZ_SOURCE_PUBLIC_BASE='https://desktop-h3r6cqn.tailc9bb62.ts.net:8445'
$argsList=@('-m','uvicorn','afz_public_proxy:app','--host','127.0.0.1','--port','18773','--log-level','warning','--no-access-log')
$child=Start-Process -FilePath $python -ArgumentList $argsList -WorkingDirectory $root -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $stateRoot 'public-edge-private.stdout.log') -RedirectStandardError (Join-Path $stateRoot 'public-edge-private.stderr.log')
$runtime=@{pid=$child.Id;startedUtc=$child.StartTime.ToUniversalTime().ToString('o');sourceSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()}
[IO.File]::WriteAllText((Join-Path $stateRoot 'runtime-private.json'),($runtime | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
$child.WaitForExit()
# An unexpected clean child exit also needs the task's bounded restart policy.
if($child.ExitCode -eq 0){exit 1}
exit $child.ExitCode
