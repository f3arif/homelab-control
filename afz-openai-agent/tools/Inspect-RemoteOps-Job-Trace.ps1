#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$JobId)
$ErrorActionPreference='Stop'
$root='C:\AFZ\RemoteOps'
$bridge='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
Write-Output 'AFZ_REMOTEOPS_JOB_TRACE_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output ('JOB_ID='+$JobId)
Write-Output 'READ_ONLY=true'
$log=Join-Path $root 'logs\worker.log'
if(Test-Path -LiteralPath $log){
    $hits=@(Select-String -LiteralPath $log -Pattern ([regex]::Escape($JobId)) -SimpleMatch:$false -ErrorAction SilentlyContinue | Select-Object -Last 30)
    Write-Output ('LOG_HIT_COUNT='+$hits.Count)
    foreach($h in $hits){Write-Output ('LOG|'+$h.Line)}
}else{Write-Output 'LOG_MISSING=true'}
foreach($rel in @('jobs','processing','results','jobs-duplicate-v7','jobs-malformed-hold-v7')){
    $d=Join-Path $bridge $rel
    if(Test-Path -LiteralPath $d -PathType Container){
        $m=@(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue|Where-Object {$_.Name -like ('*'+$JobId+'*')})
        foreach($f in $m){Write-Output ('FOUND|area='+$rel+'|name='+$f.Name+'|mtime='+$f.LastWriteTime.ToString('o')+'|size='+$f.Length)}
    }
}
$jp=@(Get-CimInstance Win32_Process -Filter "Name='jellyfin.exe'" -ErrorAction SilentlyContinue)
Write-Output ('JELLYFIN_PROCESS_COUNT='+$jp.Count)
foreach($p in $jp){Write-Output ('JELLYFIN|pid='+$p.ProcessId+'|session='+$p.SessionId+'|created='+$(try{[Management.ManagementDateTimeConverter]::ToDateTime($p.CreationDate).ToString('o')}catch{''}))}
try{$i=Invoke-RestMethod -Uri 'http://127.0.0.1:8096/System/Info/Public' -TimeoutSec 5;Write-Output ('PUBLIC_INFO=PASS|name='+$i.ServerName+'|version='+$i.Version)}catch{Write-Output ('PUBLIC_INFO=FAIL|'+$_.Exception.Message)}
Write-Output 'TRACE_STATUS=PASS'
