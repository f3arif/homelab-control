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
$remoteWatcher='C:\AFZ\GitHubDirect\H3-GitHub-Direct-Benchmark-Watcher.ps1'
$rawUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/H3-GitHub-Direct-Benchmark-Watcher.ps1"
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-github-direct-bootstrap'
$stateFile=Join-Path $stateRoot 'latest.json'
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
function Save-State([string]$Status,[string]$Message,$Extra=$null){$o=[ordered]@{ok=($Status -eq 'completed');status=$Status;message=$Message;target='DESKTOP-H3R6CQN';transport='one-time-ssh-bootstrap';expectedSha=$ExpectedSha;updatedAt=(Get-Date -Format o)};if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}};[IO.File]::WriteAllText($stateFile,($o|ConvertTo-Json -Depth 10 -Compress),$utf8)}
try{
  if(-not(Test-Path $key)){throw "H3 SSH key missing: $key"}
  $ssh=(Get-Command ssh.exe -ErrorAction Stop).Source
  Save-State 'running' 'Installing persistent H3-local GitHub direct watcher.'
  $remote=@"
`$ErrorActionPreference='Stop'
if(`$env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: `$env:COMPUTERNAME"}
`$dir='C:\AFZ\GitHubDirect'
New-Item -ItemType Directory -Force -Path `$dir|Out-Null
`$watcher='$remoteWatcher'
Invoke-WebRequest -Uri '$rawUrl' -OutFile `$watcher -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-Direct-Bootstrap'} -TimeoutSec 60
`$tokens=`$null;`$errors=`$null
[void][System.Management.Automation.Language.Parser]::ParseFile(`$watcher,[ref]`$tokens,[ref]`$errors)
if(`$errors.Count -gt 0){throw ('Watcher parse failed: '+(`$errors.Message -join '; '))}
`$task='AFZ H3 GitHub Direct Benchmark Watcher'
`$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File ```"`$watcher```" -IntervalSeconds 10"
`$trigger=New-ScheduledTaskTrigger -AtLogOn -User `$env:USERNAME
`$principal=New-ScheduledTaskPrincipal -UserId "`$env:USERDOMAIN\`$env:USERNAME" -LogonType Interactive -RunLevel Highest
`$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName `$task -Action `$action -Trigger `$trigger -Principal `$principal -Settings `$settings -Force|Out-Null
try{Stop-ScheduledTask -TaskName `$task -ErrorAction SilentlyContinue}catch{}
Start-ScheduledTask -TaskName `$task
Start-Sleep -Seconds 3
`$t=Get-ScheduledTask -TaskName `$task
[pscustomobject]@{host=`$env:COMPUTERNAME;task=`$task;taskState=[string]`$t.State;watcher=`$watcher}|ConvertTo-Json -Compress
"@
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
  $out=& $ssh -i $key -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known" $h3 powershell.exe -NoProfile -EncodedCommand $encoded 2>&1
  if($LASTEXITCODE -ne 0){throw "H3 bootstrap SSH failed exit=$LASTEXITCODE output=$($out|Out-String)"}
  $line=@($out|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1)
  $extra=$null;if($line){try{$extra=$line|ConvertFrom-Json}catch{}}
  Save-State 'completed' 'H3-local GitHub watcher installed and started.' $extra
  $state=Get-Content $stateFile -Raw|ConvertFrom-Json
  Write-Output ('AFZ_BOOTSTRAP_JSON='+($state|ConvertTo-Json -Depth 10 -Compress))
}catch{
  $msg=$_.Exception.Message
  Save-State 'failed' $msg
  Write-Error $msg
  exit 1
}
