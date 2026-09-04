#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "required transport path missing: $p"}}

$remote=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "wrong host: $env:COMPUTERNAME"}
$setup=Join-Path $env:TEMP 'OllamaSetup-0.33.2.exe'
$url='https://github.com/ollama/ollama/releases/download/v0.33.2/OllamaSetup.exe'
$expected='5A91C1CF92480E28A84CD99E437219BE719DF5A50D5FA0FD5FE5B5C4A122F506'
$installRoot='C:\Users\Faiz\AppData\Local\Programs\Ollama'
$ollama=Join-Path $installRoot 'ollama.exe'
$server=Join-Path $installRoot 'lib\ollama\llama-server.exe'
$modelDir='C:\Users\Faiz\.ollama\models'
$hermes='C:\Users\Faiz\AppData\Local\hermes\bin\hermes.exe'
if(-not(Test-Path $modelDir -PathType Container)){throw 'model store missing'}
$before=Get-ChildItem $modelDir -File -Recurse -ErrorAction Stop|Measure-Object Length -Sum
if($before.Count -lt 1 -or $before.Sum -lt 1000000000){throw 'model store unexpectedly empty'}

if(-not(Test-Path $setup -PathType Leaf)){Invoke-WebRequest -Uri $url -OutFile $setup -UseBasicParsing}
$hash=(Get-FileHash $setup -Algorithm SHA256).Hash.ToUpperInvariant()
if($hash -ne $expected){
  Remove-Item $setup -Force -ErrorAction SilentlyContinue
  Invoke-WebRequest -Uri $url -OutFile $setup -UseBasicParsing
  $hash=(Get-FileHash $setup -Algorithm SHA256).Hash.ToUpperInvariant()
}
if($hash -ne $expected){throw "installer hash mismatch: $hash"}

try{Stop-ScheduledTask -TaskName 'AFZ H3 Ollama Server' -ErrorAction SilentlyContinue}catch{}
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
  ($_.Name -in @('ollama.exe','ollama app.exe')) -and
  ([string]$_.ExecutablePath -like 'C:\Users\Faiz\AppData\Local\Programs\Ollama\*')
}|ForEach-Object{try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
Start-Sleep -Seconds 2

$p=Start-Process -FilePath $setup -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/CLOSEAPPLICATIONS','/FORCECLOSEAPPLICATIONS') -Wait -PassThru
Start-Sleep -Seconds 5
if(-not(Test-Path $ollama -PathType Leaf)){throw 'ollama.exe missing after reinstall'}
if(-not(Test-Path $server -PathType Leaf)){throw 'llama-server.exe missing after reinstall'}

try{Start-ScheduledTask -TaskName 'AFZ H3 Ollama Server' -ErrorAction Stop}catch{
  $a=New-ScheduledTaskAction -Execute $ollama -Argument 'serve' -WorkingDirectory $installRoot
  $tr=New-ScheduledTaskTrigger -AtStartup
  $st=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
  $pr=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType S4U -RunLevel Highest
  Register-ScheduledTask -TaskName 'AFZ H3 Ollama Server' -Action $a -Trigger $tr -Settings $st -Principal $pr -Force|Out-Null
  Start-ScheduledTask -TaskName 'AFZ H3 Ollama Server'
}

$models=$null
for($i=0;$i -lt 30;$i++){
  Start-Sleep -Seconds 2
  try{$models=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/v1/models' -TimeoutSec 5;break}catch{}
}
if($null -eq $models){throw 'Ollama endpoint did not recover'}
$ids=@($models.data|ForEach-Object{[string]$_.id})
if($ids -notcontains 'qwen3.6:35b-a3b'){throw '35B model missing after repair'}

$payload=[ordered]@{model='qwen3.6:35b-a3b';messages=@(@{role='user';content='Reply exactly OK'});stream=$false;think=$false;options=@{num_predict=8}}|ConvertTo-Json -Depth 8 -Compress
$gen=Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:11434/api/chat' -ContentType 'application/json' -Body $payload -TimeoutSec 240
$reply=[string]$gen.message.content
if([string]::IsNullOrWhiteSpace($reply)){throw '35B generation returned empty content'}

$after=Get-ChildItem $modelDir -File -Recurse -ErrorAction Stop|Measure-Object Length -Sum
if($after.Count -ne $before.Count -or $after.Sum -ne $before.Sum){throw 'model store changed during application repair'}

$gateway=''
if(Test-Path $hermes -PathType Leaf){$gateway=(& $hermes gateway status 2>&1|Out-String).Trim()}
$o=[ordered]@{
  ok=$true
  host=$env:COMPUTERNAME
  installerSha256=$hash
  installerExit=$p.ExitCode
  llamaServerPresent=(Test-Path $server -PathType Leaf)
  endpointReachable=$true
  model35BListed=$true
  generationReply=$reply
  modelFilesBefore=$before.Count
  modelBytesBefore=$before.Sum
  modelFilesAfter=$after.Count
  modelBytesAfter=$after.Sum
  gatewayStatus=$gateway
  completedAt=(Get-Date -Format o)
}
$o|ConvertTo-Json -Depth 8 -Compress
'@

$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
$routes=@(
  [pscustomobject]@{target='Faiz@100.106.186.118';extra=@();transport='tailscale'},
  [pscustomobject]@{target='Faiz@192.168.50.185';extra=@('-o','HostKeyAlias=100.106.186.118');transport='lan'}
)
$attempts=@()
foreach($route in $routes){
  $outFile=Join-Path $env:TEMP ('h3-ollama-repair-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('h3-ollama-repair-'+[guid]::NewGuid().ToString('n')+'.err')
  try{
    $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known))
    $args+=@($route.extra)
    $args+=@($route.target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    $timedOut=(-not $p.WaitForExit(650000))
    if($timedOut){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{}}
    $stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
    $stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
    $exit=$(if($timedOut){$null}else{[int]$p.ExitCode})
    $parsed=$null
    foreach($line in @($stdout -split "`r?`n"|Where-Object{$_})){try{$parsed=$line|ConvertFrom-Json}catch{}}
    $attempts+=[ordered]@{transport=$route.transport;timedOut=$timedOut;exit=$exit;stdoutBytes=[Text.Encoding]::UTF8.GetByteCount($stdout);stderrPresent=(-not[string]::IsNullOrWhiteSpace($stderr))}
    if($parsed -and [bool]$parsed.ok){
      [ordered]@{ok=$true;classification='H3_OLLAMA_0332_REPAIR_VERIFIED';transport=$route.transport;result=$parsed;attempts=$attempts}|ConvertTo-Json -Depth 12 -Compress
      exit 0
    }
  }finally{Remove-Item $outFile,$errFile -Force -ErrorAction SilentlyContinue}
}
[ordered]@{ok=$false;classification='H3_OLLAMA_0332_REPAIR_FAILED';attempts=$attempts}|ConvertTo-Json -Depth 12 -Compress
exit 1
