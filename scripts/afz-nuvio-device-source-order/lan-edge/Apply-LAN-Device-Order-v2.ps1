param([switch]$Apply)
$ErrorActionPreference='Stop'
$root='C:\AFZ\Stremio-Failover-H3'
$stage='C:\AFZ\Nuvio-Setup-20260923\device-source-order-20261012\LAN-v2'
$source=Join-Path $stage 'afz_lan_proxy_device_v2.py'
$orig=Join-Path $root 'afz_lan_proxy.py'
$py=Join-Path $root '.venv\Scripts\python.exe'
$hostName='desktop-h3r6cqn.tailc9bb62.ts.net'
$cert=Join-Path $root ('certs\'+$hostName+'.crt')
$key=Join-Path $root ('certs\'+$hostName+'.key')
$lanIP='192.168.50.185'
$base='https://'+$hostName+':8445'
$resolve=('{0}:8445:{1}' -f $hostName,$lanIP)
$core=Join-Path $root 'stremio_catalog.py'
$receipt=Join-Path $stage $(if($Apply){'lan-v2-live-receipt.json'}else{'lan-v2-preflight.json'})
$originalHash='337654d93c08e831f4a924f0082257f19de38ff5a44fa77afcb5dc0b953c28c5'
$candidateHash='b926a6c6fffb4daa60a5200f26fc4d0499b1bf5331591022bd9365cd34496b0b'
$coreHash='d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f'
$mutex=New-Object System.Threading.Mutex($false,'Global\AFZ_LAN_DEVICE_ORDER_V2_DEPLOY_20261012')
$locked=$false
$touched=$false
$report=[ordered]@{startUtc=(Get-Date).ToUniversalTime().ToString('o');status='STARTED';originalCoreUntouched=$true;originalLANCodeUntouched=$true;rollbackVerified=$false}
function Sha([string]$f){return (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant()}
function Listener{
 return (Get-NetTCPConnection -State Listen -LocalAddress $lanIP -LocalPort 8445 -ErrorAction SilentlyContinue|Select-Object -First 1)
}
function ActiveClientCount{
 return @((Get-NetTCPConnection -State Established -LocalAddress $lanIP -LocalPort 8445 -ErrorAction SilentlyContinue)).Count
}
function Healthy{
 try{
   $raw=& curl.exe -sS --max-time 6 --resolve $resolve ($base+'/__lan_health') 2>$null
   if($LASTEXITCODE -ne 0 -or -not $raw){return $false}
   $j=$raw|ConvertFrom-Json
   return ($j.ok -and $j.addonVersion -eq '0.6.243')
 }catch{return $false}
}
function StartLAN([bool]$candidate){
 $env:AFZ_LAN_UPSTREAM='http://127.0.0.1:18774'
 $env:AFZ_LAN_MOVIE_ORDER_UPSTREAM='http://127.0.0.1:18792'
 $env:AFZ_LAN_PUBLIC_BASE=$base
 $env:AFZ_SOURCE_PUBLIC_BASE=$base
 $env:AFZ_LAN_SEPARATE_ID='0'
 $module=if($candidate){'afz_lan_proxy_device_v2:app'}else{'afz_lan_proxy:app'}
 $args=@('-m','uvicorn',$module,'--host',$lanIP,'--port','8445',
         '--log-level','warning','--ssl-keyfile',$key,'--ssl-certfile',$cert,
         '--no-proxy-headers')
 if($candidate){$args+=@('--app-dir',$stage)}
 $label=if($candidate){'candidate'}else{'restored'}
 $p=Start-Process -FilePath $py -ArgumentList $args -WorkingDirectory $root -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $stage ('edge-'+$label+'.stdout.log')) -RedirectStandardError (Join-Path $stage ('edge-'+$label+'.stderr.log'))
 for($i=0;$i -lt 65;$i++){
   Start-Sleep -Milliseconds 350
   if($p.HasExited){throw ('LAN edge '+$module+' exited')}
   if(Healthy){return $p}
 }
 throw ('LAN edge '+$module+' did not recover health')
}
function RestoreOriginal {
 $owner=Listener
 if($owner){
   $p=Get-CimInstance Win32_Process -Filter "ProcessId=$($owner.OwningProcess)" -ErrorAction SilentlyContinue
   if($p -and $p.CommandLine -match 'afz_lan_proxy_device_v2:app'){
     Stop-Process -Id $owner.OwningProcess -Force -ErrorAction Stop
     Start-Sleep -Milliseconds 450
   }elseif($p -and $p.CommandLine -match 'uvicorn afz_lan_proxy:app' -and (Healthy)){
     return $true
   }else{throw 'Unexpected LAN port owner during rollback'}
 }
 for($i=0;$i -lt 28;$i++){
   if(-not(Listener)){break}
   Start-Sleep -Milliseconds 250
 }
 if(Listener){throw 'LAN port did not release during rollback'}
 $original=StartLAN $false
 return [bool](Healthy)
}
try{
 try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
 if(-not $locked){throw 'Another rollout is active'}
 if([Environment]::MachineName -ne 'DESKTOP-H3R6CQN'){throw 'Wrong host'}
 if((Sha $orig) -ne $originalHash -or (Sha $source) -ne $candidateHash){throw 'Pinned code mismatch'}
 if((Sha $core) -ne $coreHash){throw 'Original H3 catalog drift'}
 foreach($f in @($py,$cert,$key)){if(-not(Test-Path $f)){throw 'Required runtime file missing'}}
 if(Test-Path (Join-Path $stage 'lan-v2-live-receipt.json')){throw 'Prior deployment receipt exists'}
 $test=Get-Content -Raw (Join-Path $stage 'lan-v2-http-acceptance.json')|ConvertFrom-Json
 if($test.status -ne 'PASS' -or $test.count -lt 120){throw 'Regression receipt insufficient'}
 $v2=Invoke-RestMethod 'http://127.0.0.1:18792/health' -TimeoutSec 4
 if(-not $v2.ok -or $v2.policy -ne 'phone-best-v2'){throw 'Existing V2 sorter unhealthy'}
 $old=Listener
 if(-not $old){throw 'Original LAN listener absent'}
 $previous=Get-CimInstance Win32_Process -Filter "ProcessId=$($old.OwningProcess)" -ErrorAction SilentlyContinue
 if(-not $previous -or $previous.CommandLine -notmatch 'uvicorn afz_lan_proxy:app' -or $previous.CommandLine -notmatch '8445'){
   throw 'Unexpected LAN listener owner'
 }
 if(-not(Healthy)){throw 'Original LAN listener unhealthy'}
 Write-Output 'LAN_V2_PREFLIGHT=PASS'
 if(-not $Apply){$report.status='PREFLIGHT_PASS'}
 else {
   for($i=0;$i -lt 20;$i++){
     $busy=ActiveClientCount
     if($busy -gt 0){throw ('LAN_BUSY_CLIENTS='+$busy)}
     Start-Sleep -Seconds 1
   }
   if((ActiveClientCount) -gt 0){throw 'Active LAN connection at final gate'}
   if((Listener).OwningProcess -ne $old.OwningProcess){throw 'LAN owner changed'}
   Write-Output 'LAN_V2_QUIET_WINDOW=PASS'
   $touched=$true
   Stop-Process -Id $old.OwningProcess -Force -ErrorAction Stop
   for($i=0;$i -lt 30;$i++){
     if(-not(Listener)){break}
     Start-Sleep -Milliseconds 250
   }
   if(Listener){throw 'Old LAN listener did not release'}
   $new=StartLAN $true
   Write-Output 'LAN_V2_CANDIDATE_UP'
   $headers=& curl.exe -sS --max-time 11 --resolve $resolve -D - -o NUL ($base+'/stream/movie/tt11460992.json')
   if($LASTEXITCODE -ne 0 -or ($headers|Out-String) -notmatch '(?im)^x-afz-sort-policy:\s*phone-best-v2\s*$'){
     throw 'LAN source-list route did not reach V2'
   }
   $manifest=& curl.exe -sS --max-time 8 --resolve $resolve ($base+'/manifest.json')
   if($LASTEXITCODE -ne 0 -or ($manifest|ConvertFrom-Json).id -ne 'com.afzengineering.releasecatalog'){
     throw 'Addon identity changed'
   }
   if((Sha $core) -ne $coreHash){throw 'Core changed'}
   $report.status='LAN_V2_LIVE'
   $report.lanProxyPort=8445
   $report.mediaRoutesRetained=$true
   $report.newProcessId=$new.Id
   $report.candidateSourceSHA=$candidateHash
   Write-Output 'LAN_DEVICE_MOVIE_ORDER_V2=LIVE'
 }
}catch{
 $report.error=$_.Exception.Message
 $report.status='BLOCKED'
 Write-Output ('LAN_DEPLOY_ERROR='+$report.error)
 if($touched){
   try{
     if(RestoreOriginal){
       $report.status='ROLLED_BACK'
       $report.rollbackVerified=$true
       Write-Output 'LAN_V2_ROLLBACK=PASS'
     }
   }catch{
     $report.status='MANUAL_RECOVERY_REQUIRED'
     $report.rollbackError=$_.Exception.Message
     Write-Output ('LAN_ROLLBACK_ERROR='+$report.rollbackError)
   }
 }
}finally{
 $report.finishedUtc=(Get-Date).ToUniversalTime().ToString('o')
 try{[IO.File]::WriteAllText($receipt,($report|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}catch{}
 if($locked){try{$mutex.ReleaseMutex()}catch{}}
 $mutex.Dispose()
}
if($report.status -notin @('PREFLIGHT_PASS','LAN_V2_LIVE')){exit 1}
