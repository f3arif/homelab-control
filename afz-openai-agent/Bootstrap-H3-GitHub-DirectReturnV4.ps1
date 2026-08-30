#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$ExpectedSha,
  [string]$InstallRoot='C:\AFZ\homelab-control'
)
$ErrorActionPreference='Stop'
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha required'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$h3='Faiz@100.106.186.118'
$publisherName='Publish-H3-GitHub-DirectReturn-V3.ps1'
$publisherRemote='C:\AFZ\GitHubDirect\Publish-H3-GitHub-DirectReturn-V3.ps1'
$launcherRemote='C:\AFZ\GitHubDirect\Run-H3-GitHub-DirectReturn-Hidden.vbs'
$publisherUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/$publisherName"
$launcherText=@'
Option Explicit
Dim shell, ps, cmd, rc
Set shell = CreateObject("WScript.Shell")
ps = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
cmd = Chr(34) & ps & Chr(34) & " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & Chr(34) & "C:\AFZ\GitHubDirect\Publish-H3-GitHub-DirectReturn-V3.ps1" & Chr(34)
rc = shell.Run(cmd, 0, True)
WScript.Quit rc
'@
$launcherBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($launcherText))
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-github-direct-bootstrap'
$stateFile=Join-Path $stateRoot 'latest.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Save-State([string]$Status,[string]$Message,$Extra=$null){
  $o=[ordered]@{
    ok=($Status -eq 'completed')
    status=$Status
    message=$Message
    target='DESKTOP-H3R6CQN'
    transport='one-time-ssh-bootstrap-stdin-v4'
    mode='return-only-v3'
    expectedSha=$ExpectedSha
    updatedAt=(Get-Date -Format o)
  }
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  [IO.File]::WriteAllText($stateFile,($o|ConvertTo-Json -Depth 12 -Compress),$utf8)
}

try{
  if(-not(Test-Path -LiteralPath $key -PathType Leaf)){throw "SYSTEM H3 SSH key missing: $key"}
  if(-not(Test-Path -LiteralPath $known -PathType Leaf)){throw "H3 known-hosts file missing: $known"}
  $acl=Get-Acl -LiteralPath $key -ErrorAction Stop
  if(-not $acl.AreAccessRulesProtected){throw 'SYSTEM H3 SSH key still inherits ACLs'}
  $unexpected=@($acl.Access | Where-Object {[string]$_.IdentityReference -ne 'NT AUTHORITY\SYSTEM'})
  if($unexpected.Count -gt 0){throw 'SYSTEM H3 SSH key has non-SYSTEM ACL entries'}
  $ssh=(Get-Command ssh.exe -ErrorAction Stop).Source

  Save-State 'running' 'Installing H3 return publisher through stdin transport; Qwen is not launched.'

  $remote=@"
`$ErrorActionPreference='Stop'
if(`$env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: `$env:COMPUTERNAME"}
`$dir='C:\AFZ\GitHubDirect'
`$stateRoot='C:\ProgramData\AFZ\H3GitHubDirect'
New-Item -ItemType Directory -Force -Path `$dir,`$stateRoot | Out-Null
Invoke-WebRequest -Uri '$publisherUrl' -OutFile '$publisherRemote' -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-Return-V4-Bootstrap'} -TimeoutSec 60
`$tokens=`$null
`$errors=`$null
[void][System.Management.Automation.Language.Parser]::ParseFile('$publisherRemote',[ref]`$tokens,[ref]`$errors)
if(`$errors.Count -gt 0){throw ('Publisher parse failure: '+(`$errors.Message -join '; '))}
[IO.File]::WriteAllBytes('$launcherRemote',[Convert]::FromBase64String('$launcherBase64'))

`$controllerRunning=`$false
try{
  foreach(`$p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"){
    `$cmd=[string]`$p.CommandLine
    if(`$cmd -and `$cmd.Contains('Run-H3-Qwen27B-WebsiteBenchmark.ps1') -and `$cmd.Contains('Qwen38-27B-Website-Benchmark-20260826-174739')){
      `$controllerRunning=`$true
      break
    }
  }
}catch{}

`$legacyTask='AFZ H3 GitHub Direct Benchmark Watcher'
try{Disable-ScheduledTask -TaskName `$legacyTask -ErrorAction SilentlyContinue | Out-Null}catch{}
try{Stop-ScheduledTask -TaskName `$legacyTask -ErrorAction SilentlyContinue}catch{}

`$stopped=@()
try{
  foreach(`$p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"){
    if(`$p.ProcessId -eq `$PID){continue}
    `$cmd=[string]`$p.CommandLine
    if(`$cmd -and (`$cmd.Contains('H3-GitHub-Direct-Benchmark-Watcher.ps1') -or `$cmd.Contains('Start-H3-GitHub-Direct-Benchmark.ps1'))){
      try{Stop-Process -Id `$p.ProcessId -Force -ErrorAction Stop; `$stopped+=`$p.ProcessId}catch{}
    }
  }
}catch{}

`$task='AFZ H3 GitHub Direct Return Publisher'
# Preserve the interactive user principal because gh.exe authentication was
# explicitly provisioned in that profile. Remove the visible console at the
# action boundary instead: wscript.exe is a GUI-subsystem launcher and passes
# the real PowerShell child exit code back to Task Scheduler.
`$action=New-ScheduledTaskAction -Execute "`$env:SystemRoot\System32\wscript.exe" -Argument "//B //Nologo ```"$launcherRemote```""
`$trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(15) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
`$principal=New-ScheduledTaskPrincipal -UserId "`$env:USERDOMAIN\`$env:USERNAME" -LogonType Interactive -RunLevel Highest
`$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
Register-ScheduledTask -TaskName `$task -Action `$action -Trigger `$trigger -Principal `$principal -Settings `$settings -Force | Out-Null
Start-ScheduledTask -TaskName `$task
Start-Sleep -Seconds 5

`$t=Get-ScheduledTask -TaskName `$task
`$i=Get-ScheduledTaskInfo -TaskName `$task -ErrorAction SilentlyContinue
`$pubState=`$null
`$pubStatePath=Join-Path `$stateRoot 'return-publisher-v3.json'
if(Test-Path -LiteralPath `$pubStatePath){
  try{`$pubState=Get-Content -LiteralPath `$pubStatePath -Raw | ConvertFrom-Json}catch{}
}
`$installedAction=@(`$t.Actions)[0]
[pscustomobject]@{
  host=`$env:COMPUTERNAME
  controllerRunning=`$controllerRunning
  legacyWatcherDisabled=`$true
  stoppedLegacyPids=`$stopped
  publisher='$publisherRemote'
  publisherSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath '$publisherRemote').Hash.ToLowerInvariant()
  launcher='$launcherRemote'
  launcherSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath '$launcherRemote').Hash.ToLowerInvariant()
  task=`$task
  taskState=[string]`$t.State
  taskExecute=[string]`$installedAction.Execute
  taskArguments=[string]`$installedAction.Arguments
  taskLogonType=[string]`$t.Principal.LogonType
  taskLastResult=`$(if(`$i){`$i.LastTaskResult}else{`$null})
  publisherOk=`$(if(`$pubState){[bool]`$pubState.ok}else{`$false})
  publisherStatus=`$(if(`$pubState){[string]`$pubState.status}else{'pending'})
  publisherError=`$(if(`$pubState -and `$pubState.error){[string]`$pubState.error}else{`$null})
} | ConvertTo-Json -Compress
"@

  $stdinFile=Join-Path $env:TEMP ('AFZ-H3-ReturnV4-In-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $stdoutFile=Join-Path $env:TEMP ('AFZ-H3-ReturnV4-Out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $stderrFile=Join-Path $env:TEMP ('AFZ-H3-ReturnV4-Err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    [IO.File]::WriteAllText($stdinFile,$remote,[Text.Encoding]::ASCII)
    $sshArgs=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',("UserKnownHostsFile="+$known),$h3,'powershell.exe','-NoProfile','-NonInteractive','-Command','-')
    $p=Start-Process -FilePath $ssh -ArgumentList $sshArgs -RedirectStandardInput $stdinFile -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -PassThru -NoNewWindow
    if(-not $p.WaitForExit(90000)){
      try{$p.Kill()}catch{}
      try{$p.WaitForExit()}catch{}
      throw 'H3 return bootstrap SSH stdin timed out after 90 seconds'
    }
    $p.WaitForExit()
    $exit=[int]$p.ExitCode
    $stdout=$(if(Test-Path -LiteralPath $stdoutFile){[IO.File]::ReadAllText($stdoutFile)}else{''})
    $stderr=$(if(Test-Path -LiteralPath $stderrFile){[IO.File]::ReadAllText($stderrFile)}else{''})
    if($exit -ne 0){throw "H3 return bootstrap SSH stdin failed exit=$exit stdout=$stdout stderr=$stderr"}

    $line=@(($stdout -split "`r?`n") | Where-Object {$_ -match '^\{.*\}$'} | Select-Object -Last 1)
    $extra=$null
    if($line){try{$extra=$line | ConvertFrom-Json}catch{}}
    if($extra){$extra | Add-Member -NotePropertyName sshStderr -NotePropertyValue $stderr.Trim() -Force}
  }finally{
    Remove-Item -LiteralPath $stdinFile,$stdoutFile,$stderrFile -Force -ErrorAction SilentlyContinue
  }

  Save-State 'completed' 'H3 return-only V4 installed with no-window launcher through stdin transport; no benchmark/Qwen launch performed.' $extra
  $state=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
  Write-Output ('AFZ_BOOTSTRAP_JSON='+($state|ConvertTo-Json -Depth 12 -Compress))
}catch{
  $msg=$_.Exception.Message
  Save-State 'failed' $msg
  Write-Error $msg
  exit 1
}
