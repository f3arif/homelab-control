#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$jobId='qwen35b-a3b-website-20260830-r1'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-postreturn-inspect'
$statePath=Join-Path $stateRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-QWEN35B-POSTRETURN-INSPECT-LATEST.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 50 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  Write-Output $json
}

try{
  if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only inspector; host=$env:COMPUTERNAME"}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  if([string]$identity.User.Value -ne 'S-1-5-18'){throw "Qwen35B inspector requires SYSTEM; identity=$([string]$identity.Name)"}
  foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required path missing: $p"}}

  $remote=@"
`$ErrorActionPreference='Stop'
if(`$env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: `$env:COMPUTERNAME"}
`$job='$jobId'
`$state='C:\ProgramData\AFZ\H3Qwen35BA3B\'+`$job+'.json'
`$result='C:\Projects\Qwen36-35B-A3B-Website-Test-20260830-r1\AFZ-BENCHMARK-RESULT.json'
`$raw='C:\Projects\Qwen36-35B-A3B-Website-Test-20260830-r1\AFZ-QWEN-RAW.txt'
`$response='C:\Projects\Qwen36-35B-A3B-Website-Test-20260830-r1\AFZ-OLLAMA-RESPONSE.json'
`$stateObj=`$null;if(Test-Path -LiteralPath `$state -PathType Leaf){try{`$stateObj=Get-Content -LiteralPath `$state -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}
`$resultObj=`$null;if(Test-Path -LiteralPath `$result -PathType Leaf){try{`$resultObj=Get-Content -LiteralPath `$result -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}
`$responseSummary=`$null
if(Test-Path -LiteralPath `$response -PathType Leaf){
  try{
    `$r=Get-Content -LiteralPath `$response -Raw -Encoding UTF8|ConvertFrom-Json
    `$responseSummary=[ordered]@{done=`$(if(`$r.PSObject.Properties.Name -contains 'done'){[bool]`$r.done}else{`$null});done_reason=`$(if(`$r.PSObject.Properties.Name -contains 'done_reason'){[string]`$r.done_reason}else{`$null});prompt_eval_count=`$(if(`$r.PSObject.Properties.Name -contains 'prompt_eval_count'){`$r.prompt_eval_count}else{`$null});prompt_eval_duration=`$(if(`$r.PSObject.Properties.Name -contains 'prompt_eval_duration'){`$r.prompt_eval_duration}else{`$null});eval_count=`$(if(`$r.PSObject.Properties.Name -contains 'eval_count'){`$r.eval_count}else{`$null});eval_duration=`$(if(`$r.PSObject.Properties.Name -contains 'eval_duration'){`$r.eval_duration}else{`$null});total_duration=`$(if(`$r.PSObject.Properties.Name -contains 'total_duration'){`$r.total_duration}else{`$null});response_length=`$(if(`$r.PSObject.Properties.Name -contains 'response'){([string]`$r.response).Length}else{0})}
  }catch{}
}
`$taskObj=`$null
try{`$t=Get-ScheduledTask -TaskName 'AFZ H3 Qwen35B A3B PostReturn Recovery' -ErrorAction Stop;`$ti=Get-ScheduledTaskInfo -TaskName `$t.TaskName -ErrorAction SilentlyContinue;`$taskObj=[ordered]@{state=[string]`$t.State;last_result=`$(if(`$ti){[int64]`$ti.LastTaskResult}else{`$null});last_run=`$(if(`$ti){`$ti.LastRunTime.ToString('o')}else{`$null})}}catch{`$taskObj=[ordered]@{error=`$_.Exception.Message}}
[ordered]@{schema=1;ok=`$true;classification='QWEN35B_POSTRETURN_READONLY_STATE';jobId=`$job;modelCallIssued=`$false;host=`$env:COMPUTERNAME;state=`$stateObj;result=`$resultObj;response=`$responseSummary;raw_exists=(Test-Path -LiteralPath `$raw -PathType Leaf);task=`$taskObj;observed_at=(Get-Date -Format o)}|ConvertTo-Json -Depth 50 -Compress
"@
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  $tag=[guid]::NewGuid().ToString('n');$out=Join-Path $env:TEMP ($tag+'.out.txt');$err=Join-Path $env:TEMP ($tag+'.err.txt')
  try{
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(60000)){try{$p.Kill()}catch{};throw 'Qwen35B read-only H3 inspection timed out.'}
    $stdout=$(if(Test-Path $out){[IO.File]::ReadAllText($out)}else{''});$stderr=$(if(Test-Path $err){[IO.File]::ReadAllText($err)}else{''})
    if([int]$p.ExitCode -ne 0){throw "H3 inspector SSH failed exit=$($p.ExitCode) stdout=$stdout stderr=$stderr"}
    $line=@(($stdout -split "`r?`n")|Where-Object {$_.Trim() -match '^\{.*\}$'}|Select-Object -Last 1)
    if(-not $line){throw "H3 inspector returned no JSON. stdout=$stdout stderr=$stderr"}
    $proof=([string]$line).Trim()|ConvertFrom-Json -ErrorAction Stop
    Save-State ([ordered]@{schema=1;ok=$true;status='completed';classification='QWEN35B_POSTRETURN_INSPECTED';jobId=$jobId;modelCallIssued=$false;proof=$proof;time=(Get-Date -Format o)})
    exit 0
  }finally{Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue}
}catch{
  Save-State ([ordered]@{schema=1;ok=$false;status='failed';classification='QWEN35B_POSTRETURN_INSPECT_FAILED';jobId=$jobId;modelCallIssued=$false;error=$_.Exception.Message;time=(Get-Date -Format o)})
  exit 20
}