#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$jobId='asus-runtime-cleanup-elevated-20260828-r1'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\asus-runtime-cleanup'
$stateFile=Join-Path $stateRoot 'last-job.txt'
$resultFile='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius\EMERGENCY_FALLBACK-AFZ-RUNTIME-CLEANUP-ELEVATED-LATEST.json'
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
function Get-ProcessByScript([string]$ScriptName){
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
  try{$payload|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $resultFile -Encoding UTF8}catch{}
}

if(Test-Path -LiteralPath $stateFile -PathType Leaf){
  try{
    if((Get-Content -LiteralPath $stateFile -Raw).Trim() -eq $jobId -and (Test-Path -LiteralPath $resultFile -PathType Leaf)){exit 0}
  }catch{}
}

$actions=New-Object System.Collections.Generic.List[object]
$warnings=New-Object System.Collections.Generic.List[string]
$before=Snapshot
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

try{
  if(-not $isAdmin){throw "elevated cleanup requires administrator/SYSTEM context; identity=$($identity.Name)"}

  # Remove disabled historical tasks after XML backup.
  foreach($name in @('AFZ HPLaptop Enrollment Watch','AFZ Lenovo WOL Test Monitor','AFZ RadioHilal Strict Batch2 DirectRun 20260824-2222','AFZ RadioHilal Strict Final DirectRun 20260824-2300')){
    $t=Task $name
    if(-not $t){$actions.Add([ordered]@{item=$name;action='already-absent';ok=$true});continue}
    if($t.Settings.Enabled){$warnings.Add("refused to remove enabled historical task: $name");continue}
    if(-not(Backup-Task $name)){$warnings.Add("backup failed; task retained: $name");continue}
    Unregister-ScheduledTask -TaskName $name -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
    $actions.Add([ordered]@{item=$name;action='removed-disabled-task';ok=$true})
  }

  # Canonicalize duplicate AutoRunner only if both task action signatures are exactly identical.
  $legacyAuto='AFZ OneDrive Auto Runner';$canonicalAuto='AFZ Queue AutoRunner'
  $la=Task $legacyAuto;$ca=Task $canonicalAuto
  if($la -and $ca){
    $sigLegacy=Action-Signature $la;$sigCanonical=Action-Signature $ca
    if($sigLegacy -and $sigLegacy -eq $sigCanonical){
      [void](Backup-Task $legacyAuto);[void](Backup-Task $canonicalAuto)
      $wasLegacyEnabled=[bool]$la.Settings.Enabled
      try{
        if([string]$la.State -eq 'Running'){Stop-ScheduledTask -TaskName $legacyAuto -TaskPath $la.TaskPath -ErrorAction SilentlyContinue;Start-Sleep -Seconds 2}
        Disable-ScheduledTask -TaskName $legacyAuto -TaskPath $la.TaskPath -ErrorAction Stop|Out-Null
        Enable-ScheduledTask -TaskName $canonicalAuto -TaskPath $ca.TaskPath -ErrorAction Stop|Out-Null
        Start-ScheduledTask -TaskName $canonicalAuto -TaskPath $ca.TaskPath -ErrorAction Stop
        $healthy=$false
        for($i=0;$i -lt 6;$i++){
          Start-Sleep -Seconds 2
          if((Get-ProcessByScript 'AFZ-AutoRunner.ps1').Count -gt 0 -or (Get-ProcessByScript 'AFZ-Queue-SafeRunner.ps1').Count -gt 0){$healthy=$true;break}
        }
        if(-not $healthy){throw 'canonical Queue AutoRunner produced no AutoRunner/Queue-SafeRunner process'}
        $actions.Add([ordered]@{item=$legacyAuto;action='disabled-duplicate';replacement=$canonicalAuto;ok=$true})
      }catch{
        try{if($wasLegacyEnabled){Enable-ScheduledTask -TaskName $legacyAuto -TaskPath $la.TaskPath -ErrorAction SilentlyContinue|Out-Null;Start-ScheduledTask -TaskName $legacyAuto -TaskPath $la.TaskPath -ErrorAction SilentlyContinue}}catch{}
        $warnings.Add("AutoRunner consolidation rolled back: $($_.Exception.Message)")
      }
    }else{$warnings.Add('AutoRunner tasks have different action signatures; left both unchanged')}
  }

  # HP: keep Direct path, disable older legacy worker only after Direct is healthy.
  $direct='AFZ HPLaptop Direct Remote Worker';$legacy='AFZ HPLaptop Remote Worker'
  $dt=Task $direct;$lt=Task $legacy
  if($lt){
    if(-not $dt){$warnings.Add('Direct HP worker missing; legacy HP worker retained')}
    else{
      [void](Backup-Task $direct);[void](Backup-Task $legacy)
      try{
        if(-not $dt.Settings.Enabled){Enable-ScheduledTask -TaskName $direct -TaskPath $dt.TaskPath -ErrorAction Stop|Out-Null}
        if((Task-State $direct) -ne 'Running'){Start-ScheduledTask -TaskName $direct -TaskPath $dt.TaskPath -ErrorAction Stop;Start-Sleep -Seconds 4}
        if((Task-State $direct) -ne 'Running'){throw "Direct HP worker state=$(Task-State $direct)"}
        if((Task-State $legacy) -eq 'Running'){Stop-ScheduledTask -TaskName $legacy -TaskPath $lt.TaskPath -ErrorAction SilentlyContinue;Start-Sleep -Seconds 2}
        Disable-ScheduledTask -TaskName $legacy -TaskPath $lt.TaskPath -ErrorAction Stop|Out-Null
        if((Task-State $direct) -ne 'Running'){throw 'Direct HP worker stopped during legacy disable'}
        $actions.Add([ordered]@{item=$legacy;action='disabled-legacy-worker';replacement=$direct;ok=$true})
      }catch{
        try{Enable-ScheduledTask -TaskName $legacy -TaskPath $lt.TaskPath -ErrorAction SilentlyContinue|Out-Null;Start-ScheduledTask -TaskName $legacy -TaskPath $lt.TaskPath -ErrorAction SilentlyContinue}catch{}
        $warnings.Add("HP worker consolidation rolled back: $($_.Exception.Message)")
      }
    }
  }

  # Priority startup launcher was renamed in the user-level pass. Stop the old launcher process only if
  # the scheduled Priority Loop remains enabled and running/ready.
  $pt=Task 'AFZ Priority Controller'
  if($pt -and $pt.Settings.Enabled -and (Task-State 'AFZ Priority Controller') -in @('Running','Ready')){
    $startupStillPresent=$false
    foreach($dir in @([Environment]::GetFolderPath('Startup'),[Environment]::GetFolderPath('CommonStartup'))){
      if($dir -and (Test-Path -LiteralPath $dir)){
        if(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue|Where-Object Name -ieq 'AFZ-Priority-Controller.cmd'){$startupStillPresent=$true}
      }
    }
    if(-not $startupStillPresent){
      $dup=@(Get-ProcessByScript 'AFZ-Priority-Controller.ps1')
      foreach($p in $dup){
        try{Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop;$actions.Add([ordered]@{item='AFZ-Priority-Controller.ps1';action='stopped-duplicate-startup-process';pid=[int]$p.ProcessId;ok=$true})}catch{$warnings.Add("could not stop duplicate Priority startup PID $($p.ProcessId): $($_.Exception.Message)")}
      }
    }else{$warnings.Add('Priority startup launcher still present; duplicate process not stopped')}
  }

  Start-Sleep -Seconds 4
  $after=Snapshot
  $taskStates=@()
  foreach($n in @('AFZ Queue AutoRunner','AFZ OneDrive Auto Runner','AFZ HPLaptop Direct Remote Worker','AFZ HPLaptop Remote Worker','AFZ Priority Controller','AFZ WindowsMain Worker','AFZ Control V2 Worker','AFZ Ops Console','AFZ Queue Safety Watchdog')){
    $t=Task $n;$taskStates+=[ordered]@{name=$n;state=$(if($t){[string]$t.State}else{'Missing'});enabled=$(if($t){[bool]$t.Settings.Enabled}else{$false})}
  }
  $payload=[ordered]@{schema=1;jobId=$jobId;ok=$true;identity=$identity.Name;isAdmin=$isAdmin;time=(Get-Date -Format o);backupRoot=$backupRoot;before=$before;after=$after;actions=@($actions);warnings=@($warnings);taskStates=$taskStates;corePreserved=$true}
  Write-Result $payload
  Set-Content -LiteralPath $stateFile -Value $jobId -Encoding ASCII
}catch{
  $after=Snapshot
  $payload=[ordered]@{schema=1;jobId=$jobId;ok=$false;identity=$identity.Name;isAdmin=$isAdmin;time=(Get-Date -Format o);backupRoot=$backupRoot;before=$before;after=$after;actions=@($actions);warnings=@($warnings);error=$_.Exception.Message;corePreserved=$true}
  Write-Result $payload
}
exit 0
