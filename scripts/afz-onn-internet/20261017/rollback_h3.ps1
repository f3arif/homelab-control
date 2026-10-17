# Stop only this Internet option. Run deliberately for rollback, never as a health check.
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'AFZ\ONN-Internet-20261017'
$tailscale='C:\Program Files\Tailscale\tailscale.exe'
$taskName='AFZ ONN Internet Gateway'
$serve=(& $tailscale serve status --json | Out-String | ConvertFrom-Json)
$hostKey='desktop-h3r6cqn.tailc9bb62.ts.net:443'
if([string]$serve.Web.$hostKey.Handlers.'/'.Proxy -ne 'http://127.0.0.1:19088'){throw 'INGRESS_IS_NOT_THIS_GATEWAY'}
$task=Get-ScheduledTask -TaskName $taskName
if([string]$task.Actions.Arguments -notlike ('*'+$root+'\Run-Gateway.ps1*')){throw 'TASK_IS_NOT_THIS_GATEWAY'}
& $tailscale funnel --https=443 off
if($LASTEXITCODE -ne 0){throw 'INGRESS_REMOVAL_FAILED'}
Disable-ScheduledTask -TaskName $taskName | Out-Null
Stop-ScheduledTask -TaskName $taskName
Start-Sleep -Milliseconds 500
$listener=Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 19088 -State Listen -ErrorAction SilentlyContinue
if($listener){
 $owner=[int]$listener.OwningProcess
 $p=Get-CimInstance Win32_Process -Filter ('ProcessId='+$owner)
 if($p.CommandLine -notlike ('*'+$root+'\gateway.py*')){throw 'FOREIGN_PROCESS_ON_GATEWAY_PORT'}
 Stop-Process -Id $owner -Force
}
Write-Output 'AFZ Internet stopped; private configuration and other services retained.'
