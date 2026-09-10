#Requires -Version 5.1
# User-context Hermes gateway lifecycle executor for gateway HA handover on ASUS.
#
# Runs AS FAIZ (S4U logon, no stored password, no UAC) via scheduled task
# 'AFZ Hermes Gateway HA User Action'. The SYSTEM-side HA watcher drops a
# command/result handshake file pair in C:\ProgramData\AFZ\HermesRouting\gateway-ha-handoff
# (command.json written by SYSTEM, ACL opened for this user; result.json written
# here, readable by SYSTEM).
#
# Uses ONLY native Hermes lifecycle commands:
#   start -> hermes gateway start   (direct detached spawn, no install prompts)
#   stop  -> hermes gateway stop    (drain marker, then taskkill escalation)
#
# Single-shot semantics: each commandId executes at most once (result marker).
# The result reflects the post-action verified process state (Get-CimInstance).
[CmdletBinding()]
param()
$ErrorActionPreference='Continue'
Set-StrictMode -Version 2.0

if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){ exit 3 }

$handoffDir='C:\ProgramData\AFZ\HermesRouting\gateway-ha-handoff'
$commandPath=Join-Path $handoffDir 'command.json'
$resultPath=Join-Path $handoffDir 'result.json'
$doneDir=Join-Path $handoffDir 'done'
$utf8=New-Object Text.UTF8Encoding($false)

function Get-GatewayProcs{
  $procs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
    ([string]$_.Name)-match '(?i)python|hermes' -and ([string]$_.CommandLine)-match '(?i)hermes_cli[.]main' -and ([string]$_.CommandLine)-match '(?i)gateway\s+run'})
  return @($procs)
}
function Test-TelegramEstablished($Procs){
  if(@($Procs).Count -eq 0){return $false}
  $pset=@($Procs|ForEach-Object{[int]$_.ProcessId})
  $tg=$false
  try{
    $conns=@(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue|Where-Object{
      [int]$_.RemotePort -eq 443 -and ((([string]$_.RemoteAddress)-like '149.154.*') -or (([string]$_.RemoteAddress)-like '91.108.*'))})
    foreach($c in $conns){if($pset -contains [int]$c.OwningProcess){$tg=$true;break}}
  }catch{}
  return $tg
}
function Write-Result($o){
  try{
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
    $json=$o|ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($resultPath,$json,$utf8)
    try{
      $acl=Get-Acl -LiteralPath $resultPath
      $rule=New-Object Security.AccessControl.FileSystemAccessRule('SYSTEM','FullControl','Allow')
      $acl.AddAccessRule($rule)
      Set-Acl -LiteralPath $resultPath -AclObject $acl
    }catch{}
  }catch{}
}

try{
  New-Item -ItemType Directory -Force -Path $doneDir | Out-Null
  if(-not (Test-Path -LiteralPath $commandPath -PathType Leaf)){exit 0}
  $cmd=Get-Content -LiteralPath $commandPath -Raw -Encoding UTF8|ConvertFrom-Json
  $cid=[string]$cmd.commandId
  if([string]::IsNullOrWhiteSpace($cid)){exit 0}
  $doneMarker=Join-Path $doneDir ($cid+'.done')
  if(Test-Path -LiteralPath $doneMarker -PathType Leaf){
    # Already executed this commandId; re-emit the recorded result.
    $prev=Join-Path $doneDir ($cid+'.result.json')
    if(Test-Path -LiteralPath $prev -PathType Leaf){
      $txt=[IO.File]::ReadAllText($prev)
      [IO.File]::WriteAllText($resultPath,$txt,$utf8)
    }
    exit 0
  }

  $lifecycle=([string]$cmd.lifecycle).Trim().ToLowerInvariant()
  if($lifecycle -notin @('start','stop')){exit 0}

  $root=Join-Path $env:LOCALAPPDATA 'hermes'
  $env:HERMES_HOME=$root
  $hermes=Join-Path $root 'bin\hermes.exe'
  $before=@(Get-GatewayProcs)
  $beforePids=@($before|ForEach-Object{[int]$_.ProcessId})
  $output=''
  $exit=$null

  if($lifecycle -eq 'start'){
    if($beforePids.Count -gt 0){
      $output='already-running'
      $exit=0
    }else{
      $outFile=Join-Path $env:TEMP ('ha-gw-start-'+[guid]::NewGuid().ToString('n')+'.out')
      $p=Start-Process -FilePath $hermes -ArgumentList @('gateway','start') -RedirectStandardOutput $outFile -WindowStyle Hidden -PassThru
      $null=$p.WaitForExit(45000)
      if(-not $p.HasExited){try{$p.Kill()}catch{}}
      $exit=$p.ExitCode
      if(Test-Path $outFile){$output=[IO.File]::ReadAllText($outFile);Remove-Item $outFile -Force -ErrorAction SilentlyContinue}
    }
    # Verify: allow the gateway a few seconds to appear.
    $after=@()
    for($i=0;$i -lt 10;$i++){
      Start-Sleep -Seconds 2
      $after=@(Get-GatewayProcs)
      if($after.Count -gt 0){break}
    }
    $tg=Test-TelegramEstablished $after
    $afterPids=@($after|ForEach-Object{[int]$_.ProcessId})
    Write-Result ([ordered]@{
      commandId=$cid;lifecycle='start';ok=($afterPids.Count -gt 0)
      gatewayPidCount=$afterPids.Count;gatewayPids=$afterPids;telegramEstablished=$tg
      exit=$exit;output=$output.Trim();beforePids=$beforePids
      verifiedAt=(Get-Date -Format o)
    })
  }else{
    # stop: drain first (planned-stop marker path inside hermes), then hard
    # escalation for anything that survived.
    $outFile=Join-Path $env:TEMP ('ha-gw-stop-'+[guid]::NewGuid().ToString('n')+'.out')
    $p=Start-Process -FilePath $hermes -ArgumentList @('gateway','stop') -RedirectStandardOutput $outFile -WindowStyle Hidden -PassThru
    $null=$p.WaitForExit(45000)
    if(-not $p.HasExited){try{$p.Kill()}catch{}}
    $exit=$p.ExitCode
    if(Test-Path $outFile){$output=[IO.File]::ReadAllText($outFile);Remove-Item $outFile -Force -ErrorAction SilentlyContinue}
    $after=@(Get-GatewayProcs)
    if($after.Count -gt 0){
      foreach($proc in $after){try{Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction SilentlyContinue}catch{}}
      Start-Sleep -Seconds 2
      $after=@(Get-GatewayProcs)
    }
    $afterPids=@($after|ForEach-Object{[int]$_.ProcessId})
    Write-Result ([ordered]@{
      commandId=$cid;lifecycle='stop';ok=($afterPids.Count -eq 0)
      gatewayPidCount=$afterPids.Count;gatewayPids=$afterPids;telegramEstablished=$false
      exit=$exit;output=$output.Trim();beforePids=$beforePids
      verifiedAt=(Get-Date -Format o)
    })
  }

  try{
    [IO.File]::WriteAllText($doneMarker,((Get-Date -Format o)),(New-Object Text.UTF8Encoding($false)))
    if(Test-Path -LiteralPath $resultPath -PathType Leaf){
      $txt=[IO.File]::ReadAllText($resultPath)
      [IO.File]::WriteAllText((Join-Path $doneDir ($cid+'.result.json')),$txt,$utf8)
    }
  }catch{}
}catch{exit 2}
exit 0
