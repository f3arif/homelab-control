#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

$JobId='qwen35b-a3b-website-20260830-r1-repair01'
$Model='qwen3.6:35b-a3b'
$ExpectedHost='DESKTOP-H3R6CQN'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$h3Ip='100.106.186.118'
$h3Mac='4C-ED-FB-3F-B0-9E'
$broadcast='192.168.50.255'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-repair01'
$statePath=Join-Path $stateRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-QWEN35B-REPAIR01-LATEST.json'
$localRunner=Join-Path $PSScriptRoot 'tools\Start-H3-Qwen35BA3B-WebsiteRepair01.ps1'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 40 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  [Console]::Out.WriteLine($json)
}
function Test-Tcp([string]$HostName,[int]$Port,[int]$TimeoutMs=1200){
  $c=New-Object Net.Sockets.TcpClient
  try{
    $ar=$c.BeginConnect($HostName,$Port,$null,$null)
    if(-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs,$false)){return $false}
    $c.EndConnect($ar)
    return $true
  }catch{return $false}finally{try{$c.Close()}catch{}}
}
function Send-H3Wake{
  $bytes=$h3Mac -split '[:-]'|ForEach-Object {[Convert]::ToByte($_,16)}
  $packet=New-Object byte[] 102
  0..5|ForEach-Object {$packet[$_]=0xFF}
  for($i=1;$i -le 16;$i++){[Array]::Copy($bytes,0,$packet,6+(($i-1)*6),6)}
  $client=New-Object Net.Sockets.UdpClient
  try{
    $client.EnableBroadcast=$true
    foreach($round in 1..5){
      foreach($port in @(9,7)){
        $ep=New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($broadcast)),$port
        [void]$client.Send($packet,$packet.Length,$ep)
      }
      Start-Sleep -Milliseconds 400
    }
  }finally{$client.Dispose()}
}
function Invoke-H3([string]$RemoteScript){
  $bootstrap='$ProgressPreference=''SilentlyContinue'';$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''Qwen35B repair stdin empty.''};Invoke-Expression $script'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  $tag=[guid]::NewGuid().ToString('n')
  $inFile=Join-Path $env:TEMP ($tag+'.in.ps1')
  $outFile=Join-Path $env:TEMP ($tag+'.out.txt')
  $errFile=Join-Path $env:TEMP ($tag+'.err.txt')
  try{
    [IO.File]::WriteAllText($inFile,$RemoteScript,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(120000)){
      try{$p.Kill()}catch{}
      throw 'H3 repair bootstrap timed out after 120 seconds.'
    }
    [ordered]@{
      exit=[int]$p.ExitCode
      stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile)}else{''})
      stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile)}else{''})
    }
  }finally{
    Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue
  }
}

try{
  if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only repair launcher; host=$env:COMPUTERNAME"}
  if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha must be an exact 40-character commit SHA.'}
  $ExpectedSha=$ExpectedSha.ToLowerInvariant()
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  if([string]$identity.User.Value -ne 'S-1-5-18'){throw "Qwen35B repair launcher requires SYSTEM; identity=$([string]$identity.Name)"}
  foreach($p in @($key,$known,$ssh,$localRunner)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required path missing: $p"}}

  # The runner is already part of the exact GitHub-synced source tree. Stream its
  # bytes through SSH stdin instead of asking H3 to download raw GitHub content.
  # This removes the prior Invoke-WebRequest/progress-stream failure mode while
  # keeping the same exact-SHA and one-call state guards.
  $runnerText=[IO.File]::ReadAllText($localRunner)
  if($runnerText -notmatch [regex]::Escape($Model) -or $runnerText -notmatch 'max_repair_model_calls=1' -or $runnerText -notmatch 'repair_model_call_attempted'){
    throw 'Local Repair01 runner contract markers missing.'
  }
  if(($runnerText -split '127\.0\.0\.1:11434/api/generate').Count -ne 2){throw 'Local Repair01 runner must contain exactly one model endpoint.'}
  $runnerB64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($runnerText))

  if(-not(Test-Tcp $h3Ip 22 1200)){Send-H3Wake}
  $online=$false
  for($i=1;$i -le 90;$i++){
    if(Test-Tcp $h3Ip 22 1200){$online=$true;break}
    if($i -in @(30,60)){try{Send-H3Wake}catch{}}
    Start-Sleep -Seconds 2
  }
  if(-not $online){throw 'H3 Tailscale SSH did not become reachable within bounded WOL window.'}

  $remote=@"
`$ErrorActionPreference='Stop'
`$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
`$jobId='$JobId'
`$model='$Model'
`$statePath='C:\ProgramData\AFZ\H3Qwen35BA3BRepair\$JobId.json'
`$taskName='AFZ H3 Qwen35B A3B Repair01'
function Emit([object]`$o){[Console]::Out.WriteLine((`$o|ConvertTo-Json -Depth 40 -Compress))}
function Read-State{
  if(-not(Test-Path -LiteralPath `$statePath -PathType Leaf)){return `$null}
  try{return Get-Content -LiteralPath `$statePath -Raw -Encoding UTF8|ConvertFrom-Json}catch{return `$null}
}
try{
  if(`$env:COMPUTERNAME -ne '$ExpectedHost'){throw "Wrong host: `$env:COMPUTERNAME"}

  # Authoritative duplicate-call guard is checked before any file/task mutation.
  `$prior=Read-State
  if(`$prior){
    `$attempted=`$false
    if(`$prior.PSObject.Properties.Name -contains 'repair_model_call_attempted'){`$attempted=[bool]`$prior.repair_model_call_attempted}
    if(`$attempted -or [string]`$prior.status -eq 'completed'){
      Emit ([ordered]@{ok=`$true;classification='QWEN35B_REPAIR_ALREADY_STARTED';jobId=`$jobId;state=`$prior})
      exit 0
    }
  }

  `$root='C:\ProgramData\AFZ\H3Qwen35BA3BRepair'
  New-Item -ItemType Directory -Force -Path `$root|Out-Null
  `$scriptPath=Join-Path `$root 'Start-H3-Qwen35BA3B-WebsiteRepair01.ps1'
  `$runnerBytes=[Convert]::FromBase64String('$runnerB64')
  [IO.File]::WriteAllBytes(`$scriptPath,`$runnerBytes)
  `$tokens=`$null
  `$errors=`$null
  [void][System.Management.Automation.Language.Parser]::ParseFile(`$scriptPath,[ref]`$tokens,[ref]`$errors)
  if(`$errors.Count -gt 0){throw ('Repair runner parse failure: '+(`$errors.Message -join '; '))}
  `$text=[IO.File]::ReadAllText(`$scriptPath)
  if(`$text -notmatch [regex]::Escape(`$model) -or `$text -notmatch 'max_repair_model_calls=1' -or `$text -notmatch 'repair_model_call_attempted'){throw 'Repair runner contract markers missing.'}
  if((`$text -split '127\.0\.0\.1:11434/api/generate').Count -ne 2){throw 'Repair runner does not contain exactly one model endpoint.'}

  `$taskUser=[Security.Principal.WindowsIdentity]::GetCurrent().Name
  if([string]::IsNullOrWhiteSpace(`$taskUser)){throw 'Authenticated H3 identity is unavailable for Repair01 task principal.'}
  `$arg="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ```"`$scriptPath```" -SourceSha '$ExpectedSha'"
  `$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument `$arg
  `$principal=New-ScheduledTaskPrincipal -UserId `$taskUser -LogonType Interactive -RunLevel Highest
  `$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
  `$existing=Get-ScheduledTask -TaskName `$taskName -ErrorAction SilentlyContinue
  if(-not `$existing){
    Register-ScheduledTask -TaskName `$taskName -Action `$action -Principal `$principal -Settings `$settings -Force|Out-Null
  }else{
    Set-ScheduledTask -TaskName `$taskName -Action `$action -Principal `$principal -Settings `$settings|Out-Null
  }

  # Recheck after task registration and before Start-ScheduledTask. If an earlier
  # transport attempt crossed the model boundary meanwhile, no second call starts.
  `$prior=Read-State
  if(`$prior){
    `$attempted=`$false
    if(`$prior.PSObject.Properties.Name -contains 'repair_model_call_attempted'){`$attempted=[bool]`$prior.repair_model_call_attempted}
    if(`$attempted -or [string]`$prior.status -eq 'completed'){
      Emit ([ordered]@{ok=`$true;classification='QWEN35B_REPAIR_ALREADY_STARTED';jobId=`$jobId;state=`$prior})
      exit 0
    }
  }

  `$current=Get-ScheduledTask -TaskName `$taskName -ErrorAction Stop
  if([string]`$current.State -ne 'Running'){Start-ScheduledTask -TaskName `$taskName}
  `$deadline=(Get-Date).AddSeconds(75)
  do{
    Start-Sleep -Seconds 1
    `$s=Read-State
    if(`$s){
      `$attempted=`$false
      if(`$s.PSObject.Properties.Name -contains 'repair_model_call_attempted'){`$attempted=[bool]`$s.repair_model_call_attempted}
      if(`$attempted -or [string]`$s.status -in @('blocked','failed','completed')){break}
    }
  }while((Get-Date)-lt `$deadline)
  `$s=Read-State
  if(-not `$s){throw 'Repair task created but no state appeared within 75 seconds.'}
  `$classification='QWEN35B_REPAIR_STATE_READY'
  if([bool]`$s.repair_model_call_attempted){`$classification='QWEN35B_REPAIR_MODEL_CALL_STARTED'}
  elseif([string]`$s.status -eq 'blocked'){`$classification='QWEN35B_REPAIR_BLOCKED'}
  Emit ([ordered]@{ok=`$true;classification=`$classification;jobId=`$jobId;task=`$taskName;taskUser=`$taskUser;state=`$s})
}catch{
  Emit ([ordered]@{ok=`$false;classification='QWEN35B_REPAIR_REMOTE_FAILED';jobId=`$jobId;error=`$_.Exception.Message})
  exit 20
}
"@

  $r=Invoke-H3 $remote
  $line=@(([string]$r.stdout -split "`r?`n")|Where-Object {$_.Trim() -match '^\{.*\}$'}|Select-Object -Last 1)
  $proof=$null
  if($line){try{$proof=([string]$line).Trim()|ConvertFrom-Json -ErrorAction Stop}catch{}}
  if([int]$r.exit -ne 0){
    $remoteError=$(if($proof -and $proof.PSObject.Properties.Name -contains 'error'){[string]$proof.error}else{''})
    throw "H3 repair launcher failed exit=$($r.exit) remote=$remoteError stdout=$($r.stdout) stderr=$($r.stderr)"
  }
  if(-not $proof){throw "H3 repair launcher returned no JSON. stdout=$($r.stdout) stderr=$($r.stderr)"}
  if(-not [bool]$proof.ok){throw ('H3 repair launcher returned ok=false: '+[string]$proof.error)}

  Save-State ([ordered]@{
    schema=1
    ok=$true
    status='completed'
    classification=[string]$proof.classification
    jobId=$JobId
    model=$Model
    repairModelCallIssued=([string]$proof.classification -eq 'QWEN35B_REPAIR_MODEL_CALL_STARTED')
    expectedSha=$ExpectedSha
    h3Proof=$proof
    time=(Get-Date -Format o)
  })
  exit 0
}catch{
  Save-State ([ordered]@{
    schema=1
    ok=$false
    status='failed'
    classification='QWEN35B_REPAIR_LAUNCH_FAILED'
    jobId=$JobId
    model=$Model
    repairModelCallIssued=$false
    expectedSha=$ExpectedSha
    error=$_.Exception.Message
    time=(Get-Date -Format o)
  })
  exit 20
}
