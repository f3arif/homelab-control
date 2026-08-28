#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$ExpectedSha,
  [string]$InstallRoot='C:\AFZ\homelab-control'
)
$ErrorActionPreference='Stop'
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha required'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()
$key='C:\Users\Faiz\.ssh\afz_h3_worker'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$h3='Faiz@100.106.186.118'
$publisherName='Publish-H3-GitHub-DirectReturn-V3.ps1'
$publisherRemote='C:\AFZ\GitHubDirect\Publish-H3-GitHub-DirectReturn-V3.ps1'
$publisherUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/$publisherName"
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-github-direct-bootstrap'
$stateFile=Join-Path $stateRoot 'latest.json'
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
function Save-State([string]$Status,[string]$Message,$Extra=$null){
  $o=[ordered]@{ok=($Status -eq 'completed');status=$Status;message=$Message;target='DESKTOP-H3R6CQN';transport='one-time-ssh-bootstrap';mode='return-only-v3';expectedSha=$ExpectedSha;updatedAt=(Get-Date -Format o)}
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  [IO.File]::WriteAllText($stateFile,($o|ConvertTo-Json -Depth 12 -Compress),$utf8)
}
try{
  if(-not(Test-Path $key)){throw "H3 SSH key missing: $key"}
  $ssh=(Get-Command ssh.exe -ErrorAction Stop).Source
  Save-State 'running' 'Installing H3 return-only V3 publisher and retiring obsolete raw watcher without launching Qwen.'
  $remote=@"
`$ErrorActionPreference='Stop'
if(`$env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: `$env:COMPUTERNAME"}
`$dir='C:\AFZ\GitHubDirect';`$stateRoot='C:\ProgramData\AFZ\H3GitHubDirect'
New-Item -ItemType Directory -Force -Path `$dir,`$stateRoot|Out-Null
Invoke-WebRequest -Uri '$publisherUrl' -OutFile '$publisherRemote' -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-Return-V3-Bootstrap'} -TimeoutSec 60
`$tokens=`$null;`$errors=`$null
[void][System.Management.Automation.Language.Parser]::ParseFile('$publisherRemote',[ref]`$tokens,[ref]`$errors)
if(`$errors.Count -gt 0){throw ('Publisher parse failure: '+(`$errors.Message -join '; '))}
`$controllerRunning=`$false
try{
  foreach(`$p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"){
    `$cmd=[string]`$p.CommandLine
    if(`$cmd -and `$cmd.Contains('Run-H3-Qwen27B-WebsiteBenchmark.ps1') -and `$cmd.Contains('Qwen38-27B-Website-Benchmark-20260826-174739')){`$controllerRunning=`$true;break}
  }
}catch{}
`$legacyTask='AFZ H3 GitHub Direct Benchmark Watcher'
try{Disable-ScheduledTask -TaskName `$legacyTask -ErrorAction SilentlyContinue|Out-Null}catch{}
try{Stop-ScheduledTask -TaskName `$legacyTask -ErrorAction SilentlyContinue}catch{}
`$stopped=@()
try{
  foreach(`$p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"){
    if(`$p.ProcessId -eq `$PID){continue}
    `$cmd=[string]`$p.CommandLine
    if(`$cmd -and (`$cmd.Contains('H3-GitHub-Direct-Benchmark-Watcher.ps1') -or `$cmd.Contains('Start-H3-GitHub-Direct-Benchmark.ps1'))){
      try{Stop-Process -Id `$p.ProcessId -Force -ErrorAction Stop;`$stopped+=`$p.ProcessId}catch{}
    }
  }
}catch{}
`$wrapper=Join-Path `$dir 'Run-H3-GitHub-DirectReturn-V3.ps1'
`$log=Join-Path `$stateRoot 'return-publisher-task.log'
`$wrapperText=@'
$ErrorActionPreference='Continue'
$stamp=Get-Date -Format o
try{
  $out=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\AFZ\GitHubDirect\Publish-H3-GitHub-DirectReturn-V3.ps1' 2>&1)
  $code=$LASTEXITCODE
  Add-Content -LiteralPath 'C:\ProgramData\AFZ\H3GitHubDirect\return-publisher-task.log' -Value ("[$stamp] exit=$code") -Encoding UTF8
  foreach($line in $out){Add-Content -LiteralPath 'C:\ProgramData\AFZ\H3GitHubDirect\return-publisher-task.log' -Value ([string]$line) -Encoding UTF8}
  exit $code
}catch{Add-Content -LiteralPath 'C:\ProgramData\AFZ\H3GitHubDirect\return-publisher-task.log' -Value ("[$stamp] wrapper_error="+$_.Exception.Message) -Encoding UTF8;exit 1}
'@
[IO.File]::WriteAllText(`$wrapper,`$wrapperText,(New-Object Text.UTF8Encoding(`$false)))
`$task='AFZ H3 GitHub Direct Return Publisher'
`$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File ```"`$wrapper```""
`$trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(15) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
`$principal=New-ScheduledTaskPrincipal -UserId "`$env:USERDOMAIN\`$env:USERNAME" -LogonType Interactive -RunLevel Highest
`$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
Register-ScheduledTask -TaskName `$task -Action `$action -Trigger `$trigger -Principal `$principal -Settings `$settings -Force|Out-Null
Start-ScheduledTask -TaskName `$task
Start-Sleep -Seconds 5
`$t=Get-ScheduledTask -TaskName `$task
`$i=Get-ScheduledTaskInfo -TaskName `$task -ErrorAction SilentlyContinue
`$pubState=`$null;`$pubStatePath=Join-Path `$stateRoot 'return-publisher-v3.json'
if(Test-Path `$pubStatePath){try{`$pubState=Get-Content -LiteralPath `$pubStatePath -Raw|ConvertFrom-Json}catch{}}
[pscustomobject]@{
  host=`$env:COMPUTERNAME
  controllerRunning=`$controllerRunning
  legacyWatcherDisabled=`$true
  stoppedLegacyPids=`$stopped
  publisher='$publisherRemote'
  publisherSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath '$publisherRemote').Hash.ToLowerInvariant()
  task=`$task
  taskState=[string]`$t.State
  taskLastResult=`$(if(`$i){`$i.LastTaskResult}else{`$null})
  publisherOk=`$(if(`$pubState){[bool]`$pubState.ok}else{`$false})
  publisherStatus=`$(if(`$pubState){[string]`$pubState.status}else{'pending'})
  publisherError=`$(if(`$pubState -and `$pubState.error){[string]`$pubState.error}else{`$null})
}|ConvertTo-Json -Compress
"@
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
  $out=& $ssh -i $key -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known" $h3 powershell.exe -NoProfile -EncodedCommand $encoded 2>&1
  if($LASTEXITCODE -ne 0){throw "H3 return bootstrap SSH failed exit=$LASTEXITCODE output=$($out|Out-String)"}
  $line=@($out|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1)
  $extra=$null;if($line){try{$extra=$line|ConvertFrom-Json}catch{}}
  Save-State 'completed' 'H3 return-only V3 installed; obsolete raw watcher disabled; no benchmark/Qwen launch performed.' $extra
  $state=Get-Content $stateFile -Raw|ConvertFrom-Json
  Write-Output ('AFZ_BOOTSTRAP_JSON='+($state|ConvertTo-Json -Depth 12 -Compress))
}catch{
  $msg=$_.Exception.Message
  Save-State 'failed' $msg
  Write-Error $msg
  exit 1
}
