$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'AFZ\ONN-Internet-20261017'
$taskName='AFZ ONN Internet Gateway'
$python='C:\Users\Faiz\AppData\Local\Programs\Python\Python311\python.exe'
$tailscale='C:\Program Files\Tailscale\tailscale.exe'
$origin='https://desktop-h3r6cqn.tailc9bb62.ts.net'
if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){throw 'TASK_ALREADY_EXISTS'}
if(Get-NetTCPConnection -State Listen -LocalPort 19088 -ErrorAction SilentlyContinue){throw 'LOCAL_PORT_ALREADY_USED'}
$before=(& $tailscale serve status --json | Out-String | ConvertFrom-Json)
if($before.TCP.PSObject.Properties.Name -contains '443'){throw 'HTTPS_443_ALREADY_CONFIGURED'}
$before | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $root 'h3-serve-before-private.json') -Encoding UTF8
$seedLinks=Join-Path $root 'installation-links-private.json'
if(Test-Path -LiteralPath $seedLinks){
 $links=Get-Content -LiteralPath $seedLinks -Raw | ConvertFrom-Json
 $token=([uri][string]$links.manifest).AbsolutePath.Split('/')[1]
}else{
 $bytes=New-Object byte[] 32
 $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
 $rng.GetBytes($bytes);$rng.Dispose()
 $token=[Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}
if($token -notmatch '^[A-Za-z0-9_-]{40,96}$'){throw 'INVALID_TOKEN'}
$cfg=@{token=$token;publicOrigin=$origin;port=19088;upstream='http://127.0.0.1:18774'}
$cfgPath=Join-Path $root 'gateway-private.json'
if(Test-Path -LiteralPath $cfgPath){throw 'CONFIG_ALREADY_EXISTS'}
[IO.File]::WriteAllText($cfgPath,($cfg | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
$runner=Join-Path $root 'Run-Gateway.ps1'
$runnerContent=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$p=Start-Process -FilePath 'C:\Users\Faiz\AppData\Local\Programs\Python\Python311\python.exe' -ArgumentList @('-u',('"'+(Join-Path $root 'gateway.py')+'"'),'--config',('"'+(Join-Path $root 'gateway-private.json')+'"')) -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $root 'gateway-private.stdout.log') -RedirectStandardError (Join-Path $root 'gateway-private.stderr.log')
exit $p.ExitCode
'@
[IO.File]::WriteAllText($runner,$runnerContent,(New-Object Text.UTF8Encoding($false)))
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$runner+'"')
$user=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
$triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -AtLogOn -User $user))
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description 'AFZ Internet: protected read-only TV add-on; works without a VPN on the client.' | Out-Null
Start-ScheduledTask -TaskName $taskName
$ready=$false
for($i=0;$i -lt 25;$i++){
 try{
  $m=Invoke-RestMethod -Uri ('http://127.0.0.1:19088/'+$token+'/manifest.json') -TimeoutSec 5
  if([string]$m.id -eq 'com.afzengineering.releasecatalog.internet'){$ready=$true;break}
 }catch{}
 Start-Sleep -Milliseconds 400
}
if(-not $ready){Stop-ScheduledTask -TaskName $taskName;throw 'LOCAL_GATEWAY_NOT_READY'}
& $tailscale funnel --bg --yes --https=443 http://127.0.0.1:19088 | Out-Null
if($LASTEXITCODE -ne 0){throw 'FUNNEL_443_FAILED'}
$after=(& $tailscale serve status --json | Out-String | ConvertFrom-Json)
foreach($prop in $before.TCP.PSObject.Properties){
 $old=$prop.Value | ConvertTo-Json -Compress -Depth 20
 $new=$after.TCP.($prop.Name) | ConvertTo-Json -Compress -Depth 20
 if($old -ne $new){throw 'EXISTING_TCP_MAPPING_CHANGED'}
}
foreach($prop in $before.Web.PSObject.Properties){
 $old=$prop.Value | ConvertTo-Json -Compress -Depth 20
 $new=$after.Web.($prop.Name) | ConvertTo-Json -Compress -Depth 20
 if($old -ne $new){throw 'EXISTING_WEB_MAPPING_CHANGED'}
}
if(Test-Path -LiteralPath $seedLinks){Copy-Item -LiteralPath $seedLinks -Destination (Join-Path $root 'installation-links-before-install-private.json')}
$newLinks=@{manifest=($origin+'/'+$token+'/manifest.json');setup=($origin+'/'+$token+'/setup')}
[IO.File]::WriteAllText((Join-Path $root 'installation-links-private.json'),($newLinks | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
$report=@{ok=$true;task=$taskName;existingMappingsPreserved=$true;previousTcpCount=@($before.TCP.PSObject.Properties).Count;previousWebCount=@($before.Web.PSObject.Properties).Count;origin=$origin;catalogs=@($m.catalogs).Count;utc=[DateTime]::UtcNow.ToString('o')}
[IO.File]::WriteAllText((Join-Path $root 'h3-rollout-receipt.json'),($report | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
$report | ConvertTo-Json -Compress
