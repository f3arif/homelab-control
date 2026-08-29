#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$SyncedSha
)
$ErrorActionPreference='Stop'
if($SyncedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SyncedSha must be a 40-character Git commit SHA'}
$SyncedSha=$SyncedSha.ToLowerInvariant()

$generationState='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-direct-return-generation\latest.json'
$root='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-return-publisher-postmortem'
$marker=Join-Path $root 'postmortem-v3.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'H3-RETURN-PUBLISHER-POSTMORTEM-LATEST.json'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return $null}}
function Publish-Diagnostic($Object){
  try{
    if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){return}
    $d=[ordered]@{schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';source='windows-main';controlPlane='github';observedAt=(Get-Date -Format o);postmortem=$Object}
    [IO.File]::WriteAllText($diagFile,($d|ConvertTo-Json -Depth 50 -Compress),$utf8)
  }catch{}
}
function Save($Object){[IO.File]::WriteAllText($marker,($Object|ConvertTo-Json -Depth 50 -Compress),$utf8);Publish-Diagnostic $Object;Write-Output ($Object|ConvertTo-Json -Depth 50 -Compress)}
function Invoke-SshJson([string]$Name,[string]$Script,[int]$TimeoutMs=30000){
  $out=Join-Path $env:TEMP ('afz-h3-post3-'+$Name+'-out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $err=Join-Path $env:TEMP ('afz-h3-post3-'+$Name+'-err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $sshArgs=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',("UserKnownHostsFile="+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',$encoded)
    $p=Start-Process -FilePath $ssh -ArgumentList $sshArgs -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
    $timedOut=$false
    if(-not $p.WaitForExit($TimeoutMs)){$timedOut=$true;try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{}}
    if(-not $timedOut){$p.WaitForExit();$exit=[int]$p.ExitCode}else{$exit=$null}
    $stdout=$(if(Test-Path -LiteralPath $out){[IO.File]::ReadAllText($out)}else{''})
    $stderr=$(if(Test-Path -LiteralPath $err){[IO.File]::ReadAllText($err)}else{''})
    $line=@(($stdout -split '\r?\n')|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1)
    $remote=$null;if($line){try{$remote=$line|ConvertFrom-Json}catch{}}
    return [ordered]@{name=$Name;exit=$exit;timedOut=$timedOut;remote=$remote;stdout=$(if($remote){$null}else{$stdout.Trim()});stderr=$stderr.Trim()}
  }catch{return [ordered]@{name=$Name;exit=$null;timedOut=$false;remote=$null;stdout='';stderr=('LOCAL_PROBE_EXCEPTION: '+$_.Exception.Message)}}
  finally{Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue}
}

$prior=Read-Json $marker
if($prior){Publish-Diagnostic $prior;Write-Output ($prior|ConvertTo-Json -Depth 50 -Compress);exit 0}
$g=Read-Json $generationState
if(-not $g -or [int]$g.generation -ne 5 -or [string]$g.status -ne 'completed' -or -not [bool]$g.ok){Save ([ordered]@{schema=1;version=3;ok=$false;status='not-applicable';reason='generation-5-not-completed';syncedSha=$SyncedSha;readOnly=$true;updatedAt=(Get-Date -Format o)});exit 0}
if(-not(Test-Path -LiteralPath $key -PathType Leaf)){Save ([ordered]@{schema=1;version=3;ok=$false;status='failed';stage='local-key';error="SYSTEM H3 key missing: $key";syncedSha=$SyncedSha;readOnly=$true;updatedAt=(Get-Date -Format o)});exit 0}
if(-not(Test-Path -LiteralPath $known -PathType Leaf)){Save ([ordered]@{schema=1;version=3;ok=$false;status='failed';stage='local-known-hosts';error="H3 known-hosts missing: $known";syncedSha=$SyncedSha;readOnly=$true;updatedAt=(Get-Date -Format o)});exit 0}
if(-not(Test-Path -LiteralPath $ssh -PathType Leaf)){Save ([ordered]@{schema=1;version=3;ok=$false;status='failed';stage='local-ssh';error="ssh.exe missing: $ssh";syncedSha=$SyncedSha;readOnly=$true;updatedAt=(Get-Date -Format o)});exit 0}

$probeTask=@'
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
function F($v){if($null -eq $v){return $null};try{return ([datetime]$v).ToString('o')}catch{return [string]$v}}
$n='AFZ H3 GitHub Direct Return Publisher';$p='C:\AFZ\GitHubDirect\Publish-H3-GitHub-DirectReturn-V3.ps1'
$t=Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue;$i=$null;if($t){$i=Get-ScheduledTaskInfo -TaskName $n -ErrorAction SilentlyContinue}
$txt=$null;$hash=$null;$lw=$null;if(Test-Path -LiteralPath $p -PathType Leaf){$txt=[IO.File]::ReadAllText($p);$hash=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant();$lw=F (Get-Item -LiteralPath $p).LastWriteTime}
[ordered]@{host=$env:COMPUTERNAME;taskExists=[bool]$t;taskState=$(if($t){[string]$t.State}else{$null});taskLastResult=$(if($i){[int]$i.LastTaskResult}else{$null});taskLastRunTime=$(if($i){F $i.LastRunTime}else{$null});taskNextRunTime=$(if($i){F $i.NextRunTime}else{$null});publisherExists=[bool]$txt;publisherSha256=$hash;publisherLastWrite=$lw;publisherHasGhArgsFix=$(if($txt){$txt.Contains('function Invoke-Gh([string[]]$GhArgs)')}else{$false});publisherStillHasArgsBug=$(if($txt){$txt.Contains('function Invoke-Gh([string[]]$Args)')}else{$false})}|ConvertTo-Json -Compress
'@
$probeState=@'
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$s='C:\ProgramData\AFZ\H3GitHubDirect\return-publisher-v3.json';$e='C:\ProgramData\AFZ\H3GitHubDirect\return-envelope.json'
$so=$null;$sr=$null;if(Test-Path -LiteralPath $s -PathType Leaf){try{$sr=[IO.File]::ReadAllText($s);$so=$sr|ConvertFrom-Json}catch{}}
$eo=$null;$er=$null;if(Test-Path -LiteralPath $e -PathType Leaf){try{$er=[IO.File]::ReadAllText($e);$eo=$er|ConvertFrom-Json}catch{}}
[ordered]@{publisherState=$so;publisherStateRaw=$(if($so){$null}else{$sr});returnEnvelope=$eo;returnEnvelopeRaw=$(if($eo){$null}else{$er})}|ConvertTo-Json -Depth 25 -Compress
'@
$probeGh=@'
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$gh=$null;$c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Source){$gh=[string]$c.Source}elseif($c.Path){$gh=[string]$c.Path}}
if(-not $gh){foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path -LiteralPath $p -PathType Leaf){$gh=$p;break}}}
$u='';$ue=$null;$pu='';$pe=$null
if($gh){$u=((& $gh api user --jq .login 2>&1)|Out-String).Trim();$ue=$LASTEXITCODE;$pu=((& $gh api repos/f3arif/homelab-control --jq .permissions.push 2>&1)|Out-String).Trim();$pe=$LASTEXITCODE}
[ordered]@{ghPath=$gh;userExit=$ue;userOutput=$u;pushExit=$pe;pushOutput=$pu}|ConvertTo-Json -Compress
'@
$probeRuntime=@'
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$c=0;try{foreach($p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"){$x=[string]$p.CommandLine;if($x -and $x.Contains('Run-H3-Qwen27B-WebsiteBenchmark.ps1') -and $x.Contains('Qwen38-27B-Website-Benchmark-20260826-174739')){$c++}}}catch{}
$l=Get-ScheduledTask -TaskName 'AFZ H3 GitHub Direct Benchmark Watcher' -ErrorAction SilentlyContinue
[ordered]@{controllerCount=$c;legacyWatcherState=$(if($l){[string]$l.State}else{$null})}|ConvertTo-Json -Compress
'@

$task=Invoke-SshJson 'task' $probeTask
$state=Invoke-SshJson 'state' $probeState
$gh=Invoke-SshJson 'gh' $probeGh
$runtime=Invoke-SshJson 'runtime' $probeRuntime
$all=@($task,$state,$gh,$runtime)
$captured=(@($all|Where-Object {$_.exit -ne 0 -or $_.timedOut -or -not $_.remote}).Count -eq 0)
$r=[ordered]@{schema=1;version=3;ok=$captured;status=$(if($captured){'captured'}else{'partial-or-failed'});syncedSha=$SyncedSha;target='DESKTOP-H3R6CQN';transport='system-ssh-split-encoded';readOnly=$true;task=$task;state=$state;gh=$gh;runtime=$runtime;updatedAt=(Get-Date -Format o)}
Save $r
exit 0
