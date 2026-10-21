$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'AFZ\ONN-Internet-20261017'
$python='C:\Users\Faiz\AppData\Local\Programs\Python\Python311\python.exe'
$test=Start-Process -FilePath $python -ArgumentList @((Join-Path $root 'test_gateway.py')) -Wait -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $root 'windows-tests.stdout.log') -RedirectStandardError (Join-Path $root 'windows-tests.stderr.log')
if($test.ExitCode -ne 0){Get-Content (Join-Path $root 'windows-tests.stderr.log') -Tail 12;throw 'WINDOWS_TESTS_FAILED'}
$runnerContent=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$p=Start-Process -FilePath 'C:\Users\Faiz\AppData\Local\Programs\Python\Python311\python.exe' -ArgumentList @('-u',('"'+(Join-Path $root 'gateway.py')+'"'),'--config',('"'+(Join-Path $root 'gateway-private.json')+'"')) -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $root 'gateway-private.stdout.log') -RedirectStandardError (Join-Path $root 'gateway-private.stderr.log')
exit $p.ExitCode
'@
[IO.File]::WriteAllText((Join-Path $root 'Run-Gateway.ps1'),$runnerContent,(New-Object Text.UTF8Encoding($false)))
$listener=Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 19088 -State Listen -ErrorAction Stop
$pidValue=[int]$listener.OwningProcess
$proc=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pidValue)
if($proc.CommandLine -notlike ('*'+$root+'\gateway.py*')){throw 'FOREIGN_GATEWAY_PROCESS'}
Stop-ScheduledTask -TaskName 'AFZ ONN Internet Gateway'
Start-Sleep -Milliseconds 500
if(Get-Process -Id $pidValue -ErrorAction SilentlyContinue){Stop-Process -Id $pidValue -Force}
Start-ScheduledTask -TaskName 'AFZ ONN Internet Gateway'
$cfg=Get-Content (Join-Path $root 'gateway-private.json') -Raw | ConvertFrom-Json
$ready=$false
for($i=0;$i -lt 25;$i++){
 try{
  $m=Invoke-RestMethod ('http://127.0.0.1:19088/'+$cfg.token+'/manifest.json') -TimeoutSec 4
  if(@($m.types).Count -eq 2){$ready=$true;break}
 }catch{}
 Start-Sleep -Milliseconds 400
}
if(-not $ready){throw 'UPDATED_GATEWAY_NOT_READY'}
$testCount=[int]([regex]::Match((Get-Content (Join-Path $root 'windows-tests.stderr.log') -Raw),'Ran (\d+) tests').Groups[1].Value)
$receipt=@{ok=$true;tests=$testCount;gatewaySha256=(Get-FileHash (Join-Path $root 'gateway.py') -Algorithm SHA256).Hash.ToLower();types=@($m.types);catalogs=@($m.catalogs).Count;taskState=[string](Get-ScheduledTask -TaskName 'AFZ ONN Internet Gateway').State}
[IO.File]::WriteAllText((Join-Path $root 'source-receipt.json'),($receipt | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
$receipt | ConvertTo-Json -Compress
