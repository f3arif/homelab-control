#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$jobId='asus-runtime-cleanup-elevated-20260828-r2'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\asus-runtime-cleanup'
$stateFile=Join-Path $stateRoot 'last-job.txt'
$resultFile=Join-Path $stateRoot 'latest.json'
$mirrorResultFile='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius\EMERGENCY_FALLBACK-AFZ-RUNTIME-CLEANUP-ELEVATED-LATEST.json'
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot="C:\ProgramData\AFZ\CleanupBackups\runtime-cleanup-elevated-$stamp"
New-Item -ItemType Directory -Force -Path $stateRoot,$backupRoot | Out-Null

function Task([string]$Name){Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue}
function Task-State([string]$Name){$t=Task $Name;if($t){return [string]$t.State};return 'Missing'}
function Backup-Task([string]$Name){
  $t=Task $Name
  if(-not $t){return $false}
  try{
    $xml=Export-ScheduledTask -TaskName $Name -TaskPath $t.TaskPath -ErrorAction Stop
    $safe=($Name -replace '[^A-Za-z0-9._ -]','_')
    $xml|Set-Content -LiteralPath (Join-Path $backupRoot "$safe.xml") -Encoding Unicode
    return $true
  }catch{return $false}
}
function Action-Signature($Task){
  if(-not $Task){return $null}
  $a=@($Task.Actions|Select-Object -First 1)
  if($a.Count -eq 0){return $null}
  return (([string]$a[0].Execute).Trim().ToLowerInvariant()+'|'+([string]$a[0].Arguments).Trim().ToLowerInvariant())
}
function Process-ByScript([string]$ScriptName){
  $rx=[regex]::Escape($ScriptName)
  return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {([string]$_.CommandLine) -match $rx})
}
function Snapshot(){
  $os=Get-CimInstance Win32_OperatingSystem
  $total=[double]$os.TotalVisibleMemorySize*1KB;$free=[double]$os.FreePhysicalMemory*1KB;$used=$total-$free
  $gp=@(Get-Process -ErrorAction SilentlyContinue);$ps=@($gp|Where-Object ProcessName -eq 'powershell');$sum=($ps|Measure-Object PrivateMemorySize64 -Sum).Sum
  return [ordered]@{ramUsedGb=[math]::Round($used/1GB,2);ramUsedPercent=[math]::Round(($used/$total)*100,1);processCount=$gp.Count;powerShellCount=$ps.Count;powerShellPrivateMb=[math]::Round($sum/1MB,1)}
}
function Write-Result($payload){
  $json=$payload|ConvertTo-Json -Depth 12
  $json|Set-Content -LiteralPath $resultFile -Encoding UTF8
  try{
    $d=Split-Path $mirrorResultFile -Parent
    if(Test-Path -LiteralPath $d -PathType Container){$json|Set-Content -LiteralPath $mirrorResultFile -Encoding UTF8}
  }catch{}
}

if((Test-Path -LiteralPath $stateFile -PathType Leaf) -and (Test-Path -LiteralPath $resultFile -PathType Leaf)){
  try{if((Get-Content -LiteralPath $stateFile -Raw).Trim() -eq $jobId){exit 0}}catch{}
}

$actions=New-Object System.Collections.Generic.List[object]
$warnings=New-Object System.Collections.Generic.List[string]
$before=Snapshot
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

try{
  if(-not $isAdmin){throw "cleanup requires administrator/SYSTEM context; identity=$($identity.Name)"}

  # Remove only disabled historical/test tasks. Back up XML before deletion.
  foreach($name in @(
    'AFZ HPLaptop Enrollment Watch',
    'AFZ Lenovo WOL Test Monitor',
    'AFZ RadioHilal Strict Batch2 DirectRun 20260824-2222',
    'AFZ RadioHilal Strict Final DirectRun 20260824-2300'
  )){
    $t=Task $name
    if(-not $t){$actions.Add([pscustomobject]@{item=$name;action='already-absent';ok=$true});continue}
    if([bool]$t.Settings.Enabled){$warnings.Add("retained enabled task: $name");continue}
    if(-not(Backup-Task $name)){$warnings.Add("backup failed; retained: $name");continue}
    Unregister-ScheduledTask -TaskName $name -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
    $actions.Add([pscustomobject]@{item=$name;action='removed-disabled-task';ok=$true})
  }

  # OneDrive AutoRunner -> Queue AutoRunner only when their full Task Scheduler actions match exactly.
  $legacyAuto='AFZ OneDrive Auto Runner';$canonicalAuto='AFZ Queue AutoRunner'
  $la=Task $legacyAuto;$ca=Task $canonicalAuto
  if($la -and $ca){
    $sigLegacy=Action-Signature $la;$sigCanonical=Action-Signature $ca
    if($sigLegacy -and $sigLegacy -eq $sigCanonical){
      [void](Backup-Task $legacyAuto);[void](Backup-Task $canonicalAuto)
      $legacyWasEnabled=[bool]$la.Settings.Enabled
      try{
        if(-not [bool]$ca.Settings.Enabled){Enable-ScheduledTask -TaskName $canonicalAuto -TaskPath $ca.TaskPath -ErrorAction Stop|Out-Null}
        if((Task-State $canonicalAuto) -ne 'Running'){
          Start-ScheduledTask -TaskName $canonicalAuto -TaskPath $ca.TaskPath -ErrorAction Stop
          Start-Sleep -Seconds 3
        }
        $healthy=((Task-State $canonicalAuto) -eq 'Running') -or ((Process-ByScript 'AFZ-AutoRunner.ps1').Count -gt 0) -or ((Process-ByScript 'AFZ-Queue-SafeRunner.ps1').Count -gt 0)
        if(-not $healthy){throw 'canonical Queue AutoRunner did not become healthy'}
        if((Task-State $legacyAuto) -eq 'Running'){Stop-ScheduledTask -TaskName $legacyAuto -TaskPath $la.TaskPath -ErrorAction SilentlyContinue;Start-Sleep -Seconds 2}
        Disable-ScheduledTask -TaskName $legacyAuto -TaskPath $la.TaskPath -ErrorAction Stop|Out-Null
        if((Task-State $canonicalAuto) -notin @('Running','Ready')){throw 'Queue AutoRunner lost healthy state after legacy disable'}
        $actions.Add([pscustomobject]@{item=$legacyAuto;action='disabled-duplicate';replacement=$canonicalAuto;ok=$true})
      }catch{
        try{if($legacyWasEnabled){Enable-ScheduledTask -TaskName $legacyAuto -TaskPath $la.TaskPath -ErrorAction SilentlyContinue|Out-Null}}catch{}
        $warnings.Add("AutoRunner consolidation rolled back: $($_.Exception.Message)")
      }
    }else{$warnings.Add('AutoRunner task actions differ; both retained')}
  }elseif($la -and -not $ca){$warnings.Add('Queue AutoRunner missing; OneDrive AutoRunner retained')}

  # HP: Direct is canonical. Disable legacy only when Direct is confirmed running.
  $direct='AFZ HPLaptop Direct Remote Worker';$legacy='AFZ HPLaptop Remote Worker'
  $dt=Task $direct;$lt=Task $legacy
  if($lt){
    if(-not $dt){$warnings.Add('Direct HP worker missing; legacy retained')}
    else{
      [void](Backup-Task $legacy)
      try{
        if(-not [bool]$dt.Settings.Enabled){Enable-ScheduledTask -TaskName $direct -TaskPath $dt.TaskPath -ErrorAction Stop|Out-Null}
        if((Task-State $direct) -ne 'Running'){Start-ScheduledTask -TaskName $direct -TaskPath $dt.TaskPath -ErrorAction Stop;Start-Sleep -Seconds 3}
        if((Task-State $direct) -ne 'Running'){throw "Direct HP worker state=$(Task-State $direct)"}
        if((Task-State $legacy) -eq 'Running'){Stop-ScheduledTask -TaskName $legacy -TaskPath $lt.TaskPath -ErrorAction SilentlyContinue;Start-Sleep -Seconds 2}
        if([bool]$lt.Settings.Enabled){Disable-ScheduledTask -TaskName $legacy -TaskPath $lt.TaskPath -ErrorAction Stop|Out-Null}
        $actions.Add([pscustomobject]@{item=$legacy;action='legacy-disabled';replacement=$direct;ok=$true})
      }catch{
        try{Enable-ScheduledTask -TaskName $legacy -TaskPath $lt.TaskPath -ErrorAction SilentlyContinue|Out-Null}catch{}
        $warnings.Add("HP consolidation rolled back: $($_.Exception.Message)")
      }
    }
  }

  # Startup file was already renamed in the user-context pass. Remove only the old resident startup controller;
  # AFZ Priority Controller scheduled task remains authoritative and enabled.
  $pt=Task 'AFZ Priority Controller'
  if($pt -and [bool]$pt.Settings.Enabled -and (Task-State 'AFZ Priority Controller') -in @('Running','Ready')){
    foreach($proc in @(Process-ByScript 'AFZ-Priority-Controller.ps1')){
      try{
        Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction Stop
        $actions.Add([pscustomobject]@{item='AFZ-Priority-Controller.ps1';action='stopped-obsolete-startup-process';pid=[int]$proc.ProcessId;ok=$true})
      }catch{$warnings.Add("could not stop obsolete Priority startup PID $($proc.ProcessId): $($_.Exception.Message)")}
    }
  }else{$warnings.Add('Priority scheduled task not healthy; no startup process termination attempted')}

  Start-Sleep -Seconds 3
  $after=Snapshot
  $taskStates=@()
  foreach($n in @('AFZ Queue AutoRunner','AFZ OneDrive Auto Runner','AFZ HPLaptop Direct Remote Worker','AFZ HPLaptop Remote Worker','AFZ HPLaptop Enrollment Watch','AFZ Lenovo WOL Test Monitor','AFZ Priority Controller','AFZ WindowsMain Worker','AFZ Control V2 Worker','AFZ Ops Console','AFZ Queue Safety Watchdog')){
    $t=Task $n
    $taskStates+=[pscustomobject]@{name=$n;state=$(if($t){[string]$t.State}else{'Missing'});enabled=$(if($t){[bool]$t.Settings.Enabled}else{$false})}
  }
  $payload=[ordered]@{schema=2;jobId=$jobId;ok=$true;identity=$identity.Name;isAdmin=$isAdmin;time=(Get-Date -Format o);backupRoot=$backupRoot;before=$before;after=$after;actions=@($actions);warnings=@($warnings);taskStates=$taskStates;priorityStartupProcessCount=(Process-ByScript 'AFZ-Priority-Controller.ps1').Count;corePreserved=$true}
  Write-Result $payload
  Set-Content -LiteralPath $stateFile -Value $jobId -Encoding ASCII
}catch{
  $after=Snapshot
  $payload=[ordered]@{schema=2;jobId=$jobId;ok=$false;identity=$identity.Name;isAdmin=$isAdmin;time=(Get-Date -Format o);backupRoot=$backupRoot;before=$before;after=$after;actions=@($actions);warnings=@($warnings);error=$_.Exception.Message;corePreserved=$true}
  try{Write-Result $payload}catch{}
}
exit 0
