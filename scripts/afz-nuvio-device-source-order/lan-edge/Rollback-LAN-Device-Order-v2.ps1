param([switch]$Apply)
$ErrorActionPreference='Stop'
$root='C:\AFZ\Stremio-Failover-H3'
$stage='C:\AFZ\Nuvio-Setup-20260923\device-source-order-20261012\LAN-v2'
$taskName='AFZ Stremio H3 LAN TLS Edge'
$taskReceipt=Join-Path $stage 'LAN-TLS-Edge-task-v2-receipt.json'
$deployReceipt=Join-Path $stage 'lan-v2-live-receipt.json'
$orig=Join-Path $root 'afz_lan_proxy.py'
$live=Join-Path $root 'stremio_catalog.py'
$python=Join-Path $root '.venv\Scripts\python.exe'
$name='desktop-h3r6cqn.tailc9bb62.ts.net'
$base='https://'+$name+':8445'
$resolve=('{0}:8445:{1}' -f $name,'192.168.50.185')
$key=Join-Path $root ('certs\'+$name+'.key')
$cert=Join-Path $root ('certs\'+$name+'.crt')
$oldSha='337654d93c08e831f4a924f0082257f19de38ff5a44fa77afcb5dc0b953c28c5'
$coreSha='d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f'
$taskDisabled=$false
$wasLive=$false
function Sha([string]$p){return (Get-FileHash $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function Listener {
 return (Get-NetTCPConnection -State Listen -LocalAddress 192.168.50.185 -LocalPort 8445 -ErrorAction SilentlyContinue|Select-Object -First 1)
}
function Active {
 return @((Get-NetTCPConnection -State Established -LocalAddress 192.168.50.185 -LocalPort 8445 -ErrorAction SilentlyContinue)).Count
}
function Healthy {
 try{
  $s=& curl.exe -sS -m 6 --resolve $resolve ($base+'/__lan_health') 2>$null
  if($LASTEXITCODE -ne 0){return $false}
  $obj=$s|ConvertFrom-Json
  return ($obj.ok -and $obj.addonVersion -eq '0.6.243')
 }catch{return $false}
}
if((Sha $orig) -ne $oldSha -or (Sha $live) -ne $coreSha){throw 'Source hashes changed'}
if(-not(Test-Path $taskReceipt) -or -not(Test-Path $deployReceipt)){throw 'Missing rollback checkpoints'}
$taskOld=Get-Content -Raw $taskReceipt|ConvertFrom-Json
$deployment=Get-Content -Raw $deployReceipt|ConvertFrom-Json
if($taskOld.status -ne 'STARTUP_TASK_REPOINTED_VERIFIED' -or $deployment.status -ne 'LAN_V2_LIVE'){
 throw 'Unexpected checkpoint status'
}
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if($task.Principal.UserId -ne 'SYSTEM' -or $task.Actions[0].Arguments -ne $taskOld.nextAction){
 throw 'Task action no longer matches deployed V2'
}
$l=Listener
if(-not $l){throw 'LAN listener not found'}
$p=Get-CimInstance Win32_Process -Filter "ProcessId=$($l.OwningProcess)"
if(-not $p -or $p.CommandLine -notmatch 'uvicorn afz_lan_proxy_device_v2:app'){throw 'Unexpected LAN process owner'}
if(-not(Healthy)){throw 'Existing LAN proxy unhealthy'}
Write-Output 'LAN_DEVICE_ORDER_ROLLBACK_PREFLIGHT=PASS'
if(-not $Apply){Write-Output 'ROLLBACK_DRY_RUN_NO_CHANGES';return}
for($i=0;$i -lt 12;$i++){
 if((Active) -gt 0){throw 'LAN clients connected; rollback held'}
 Start-Sleep -Seconds 1
}
if((Active) -gt 0){throw 'LAN client arrived during rollback gate'}
Disable-ScheduledTask -TaskName $taskName|Out-Null
$taskDisabled=$true
try{
 for($i=0;$i -lt 30;$i++){
  if((Get-ScheduledTask -TaskName $taskName).State -eq 'Disabled'){break}
  Start-Sleep -Milliseconds 250
 }
 if((Get-ScheduledTask -TaskName $taskName).State -ne 'Disabled'){throw 'Could not pause boot task'}
 $previousAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ([string]$taskOld.originalAction)
 Set-ScheduledTask -TaskName $taskName -Action $previousAction -ErrorAction Stop|Out-Null
 if((Get-ScheduledTask -TaskName $taskName).Actions[0].Arguments -ne $taskOld.originalAction){
  throw 'Original task action not restored'
 }
 $wasLive=$true
 Stop-Process -Id $l.OwningProcess -Force
 for($i=0;$i -lt 24;$i++){
  if(-not(Listener)){break}
  Start-Sleep -Milliseconds 250
 }
 if(Listener){throw 'LAN port still bound'}
 $env:AFZ_LAN_UPSTREAM='http://127.0.0.1:18774'
 $env:AFZ_LAN_PUBLIC_BASE=$base
 $env:AFZ_SOURCE_PUBLIC_BASE=$base
 $env:AFZ_LAN_SEPARATE_ID='0'
 $args=@('-m','uvicorn','afz_lan_proxy:app','--host','192.168.50.185','--port','8445',
   '--log-level','warning','--ssl-keyfile',$key,'--ssl-certfile',$cert,'--no-proxy-headers')
 $process=Start-Process -FilePath $python -ArgumentList $args -WorkingDirectory $root -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $stage 'rollback.stdout.log') -RedirectStandardError (Join-Path $stage 'rollback.stderr.log')
 $ready=$false
 for($i=0;$i -lt 55;$i++){
   Start-Sleep -Milliseconds 400
   if($process.HasExited){throw 'Restored LAN proxy exited'}
   if(Healthy){$ready=$true;break}
 }
 if(-not $ready){throw 'Original LAN proxy did not recover'}
 $now=Listener
 $restored=Get-CimInstance Win32_Process -Filter "ProcessId=$($now.OwningProcess)"
 if($restored.CommandLine -notmatch 'uvicorn afz_lan_proxy:app'){throw 'Original process identity not verified'}
 $state=[ordered]@{
    result='ORIGINAL_LAN_EDGE_RESTORED'
    restoredUtc=(Get-Date).ToUniversalTime().ToString('o')
    originalManifestPreserved=$true
    originalCatalogUntouched=$true
    startupTaskRestored=$true
 }
 [IO.File]::WriteAllText((Join-Path $stage 'rollback-result.json'),($state|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
 Write-Output 'LAN_DEVICE_ORDER_V2_ROLLBACK=PASS'
}catch{
 Write-Output ('ROLLBACK_ERROR='+$_.Exception.Message)
 if($wasLive -and -not(Healthy)){
  Write-Output 'LAN_SERVICE_REQUIRES_MANUAL_RECOVERY'
 }
 throw
}finally{
 if($taskDisabled){
  Enable-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue|Out-Null
  Write-Output ('TASK_REENABLED='+((Get-ScheduledTask -TaskName $taskName).Settings.Enabled))
 }
}
