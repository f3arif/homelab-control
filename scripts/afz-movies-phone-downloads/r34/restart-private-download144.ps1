$ErrorActionPreference='Stop'
$stage='C:\AFZ\Nuvio-Setup-20260923\R34-seerr-integrated-candidate'
$dir='C:\AFZ\Nuvio-Setup-20260923\private-direct-download-20261012'
$python='C:\AFZ\Stremio-Failover-H3\.venv\Scripts\python.exe'
if (!(Test-Path "$dir\download_app.before-r34.py")) { throw 'Prepared backup missing' }
& $python -c "import sys;sys.path.insert(0,r'$dir');import download_app;assert download_app.R34_NAME=='AFZ-Nuvio-R34-Seerr-build144.apk';print('Pinned releases validated')"
if ($LASTEXITCODE -ne 0) { throw 'Module validation failed; current server preserved' }
$old=Get-CimInstance Win32_Process -Filter 'ProcessId=44600'
if (!$old -or $old.CommandLine -notlike '*uvicorn download_app:app*--port 18793*' -or $old.ExecutablePath -ne $python) { throw 'Existing server identity changed; inspect before restart' }
& taskkill.exe /PID 44600 /T /F
if ($LASTEXITCODE -ne 0) { throw 'Could not stop exact download server' }
$p=Start-Process -FilePath $python -ArgumentList @('-m','uvicorn','download_app:app','--app-dir',$dir,'--host','127.0.0.1','--port','18793','--lifespan','off','--no-access-log','--log-level','warning') -WindowStyle Hidden -RedirectStandardOutput "$dir\download144-stdout.log" -RedirectStandardError "$dir\download144-stderr.log" -PassThru
@{pid=$p.Id;startedUtc=(Get-Date).ToUniversalTime().ToString('o');port=18793;existingRoutesPreserved=$true} | ConvertTo-Json | Set-Content "$stage\download144-process.json"
Write-Output "Private download process started: $($p.Id)"