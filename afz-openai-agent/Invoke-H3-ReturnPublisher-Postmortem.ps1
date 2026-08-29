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
$marker=Join-Path $root 'postmortem-v2.json'
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
    [IO.File]::WriteAllText($diagFile,($d|ConvertTo-Json -Depth 40 -Compress),$utf8)
  }catch{}
}
function Save($Object){[IO.File]::WriteAllText($marker,($Object|ConvertTo-Json -Depth 40 -Compress),$utf8);Publish-Diagnostic $Object;Write-Output ($Object|ConvertTo-Json -Depth 40 -Compress)}

$prior=Read-Json $marker
if($prior){Publish-Diagnostic $prior;Write-Output ($prior|ConvertTo-Json -Depth 40 -Compress);exit 0}
$g=Read-Json $generationState
if(-not $g -or [int]$g.generation -ne 5 -or [string]$g.status -ne 'completed' -or -not [bool]$g.ok){
  $na=[ordered]@{schema=1;version=2;ok=$false;status='not-applicable';reason='generation-5-not-completed';syncedSha=$SyncedSha;readOnly=$true;updatedAt=(Get-Date -Format o)}
  Save $na
  exit 0
}
if(-not(Test-Path -LiteralPath $key -PathType Leaf)){Save ([ordered]@{schema=1;version=2;ok=$false;status='failed';stage='local-key';error="SYSTEM H3 key missing: $key";syncedSha=$SyncedSha;readOnly=$true;updatedAt=(Get-Date -Format o)});exit 0}
if(-not(Test-Path -LiteralPath $known -PathType Leaf)){Save ([ordered]@{schema=1;version=2;ok=$false;status='failed';stage='local-known-hosts';error="H3 known-hosts missing: $known";syncedSha=$SyncedSha;readOnly=$true;updatedAt=(Get-Date -Format o)});exit 0}
if(-not(Test-Path -LiteralPath $ssh -PathType Leaf)){Save ([ordered]@{schema=1;version=2;ok=$false;status='failed';stage='local-ssh';error="ssh.exe missing: $ssh";syncedSha=$SyncedSha;readOnly=$true;updatedAt=(Get-Date -Format o)});exit 0}

$remote=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$VerbosePreference='SilentlyContinue'
$InformationPreference='SilentlyContinue'
function Fmt-Date($v){if($null -eq $v){return $null};try{return ([datetime]$v).ToString('o')}catch{return [string]$v}}
function Find-Gh{
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path -LiteralPath $p -PathType Leaf){return $p}}
  return $null
}
function Run-GhRead([string]$Gh,[string[]]$GhArgs){
  if(-not $Gh -or -not $GhArgs -or $GhArgs.Count -eq 0){return [ordered]@{exit=$null;stdout='';stderr='missing-gh-or-args'}}
  $o=Join-Path $env:TEMP ('afz-h3-post2-gh-out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $e=Join-Path $env:TEMP ('afz-h3-post2-gh-err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    $p=Start-Process -FilePath $Gh -ArgumentList $GhArgs -RedirectStandardOutput $o -RedirectStandardError $e -PassThru -NoNewWindow
    if(-not $p.WaitForExit(20000)){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{};return [ordered]@{exit=$null;stdout='';stderr='timeout'}}
    $p.WaitForExit()
    return [ordered]@{exit=[int]$p.ExitCode;stdout=$(if(Test-Path -LiteralPath $o){[IO.File]::ReadAllText($o).Trim()}else{''});stderr=$(if(Test-Path -LiteralPath $e){[IO.File]::ReadAllText($e).Trim()}else{''})}
  }finally{Remove-Item -LiteralPath $o,$e -Force -ErrorAction SilentlyContinue}
}
$taskName='AFZ H3 GitHub Direct Return Publisher'
$publisher='C:\AFZ\GitHubDirect\Publish-H3-GitHub-DirectReturn-V3.ps1'
$statePath='C:\ProgramData\AFZ\H3GitHubDirect\return-publisher-v3.json'
$envelopePath='C:\ProgramData\AFZ\H3GitHubDirect\return-envelope.json'
$t=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$i=$null;if($t){$i=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue}
$publisherText=$null;$publisherHash=$null;$publisherWrite=$null
if(Test-Path -LiteralPath $publisher -PathType Leaf){$publisherText=[IO.File]::ReadAllText($publisher);$publisherHash=(Get-FileHash -LiteralPath $publisher -Algorithm SHA256).Hash.ToLowerInvariant();$publisherWrite=Fmt-Date (Get-Item -LiteralPath $publisher).LastWriteTime}
$stateObj=$null;$stateRaw=$null;if(Test-Path -LiteralPath $statePath -PathType Leaf){try{$stateRaw=[IO.File]::ReadAllText($statePath);$stateObj=$stateRaw|ConvertFrom-Json}catch{}}
$envelopeObj=$null;$envelopeRaw=$null;if(Test-Path -LiteralPath $envelopePath -PathType Leaf){try{$envelopeRaw=[IO.File]::ReadAllText($envelopePath);$envelopeObj=$envelopeRaw|ConvertFrom-Json}catch{}}
$controllerCount=0
try{foreach($p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"){$cmd=[string]$p.CommandLine;if($cmd -and $cmd.Contains('Run-H3-Qwen27B-WebsiteBenchmark.ps1') -and $cmd.Contains('Qwen38-27B-Website-Benchmark-20260826-174739')){$controllerCount++}}}catch{}
$legacy=Get-ScheduledTask -TaskName 'AFZ H3 GitHub Direct Benchmark Watcher' -ErrorAction SilentlyContinue
$gh=Find-Gh
$ghUser=$(if($gh){Run-GhRead $gh @('api','user','--jq','.login')}else{$null})
$ghPush=$(if($gh){Run-GhRead $gh @('api','repos/f3arif/homelab-control','--jq','.permissions.push')}else{$null})
[ordered]@{
  host=$env:COMPUTERNAME;readOnly=$true;taskExists=[bool]$t;taskState=$(if($t){[string]$t.State}else{$null});
  taskLastResult=$(if($i){[int]$i.LastTaskResult}else{$null});taskLastRunTime=$(if($i){Fmt-Date $i.LastRunTime}else{$null});taskNextRunTime=$(if($i){Fmt-Date $i.NextRunTime}else{$null});
  publisherExists=[bool]$publisherText;publisherSha256=$publisherHash;publisherLastWrite=$publisherWrite;
  publisherHasGhArgsFix=$(if($publisherText){$publisherText.Contains('function Invoke-Gh([string[]]$GhArgs)')}else{$false});
  publisherStillHasArgsBug=$(if($publisherText){$publisherText.Contains('function Invoke-Gh([string[]]$Args)')}else{$false});
  publisherState=$stateObj;publisherStateRaw=$(if($stateObj){$null}else{$stateRaw});returnEnvelope=$envelopeObj;returnEnvelopeRaw=$(if($envelopeObj){$null}else{$envelopeRaw});
  ghPath=$gh;ghUser=$ghUser;ghPushPermission=$ghPush;controllerCount=$controllerCount;legacyWatcherState=$(if($legacy){[string]$legacy.State}else{$null});capturedAt=(Get-Date -Format o)
}|ConvertTo-Json -Depth 30 -Compress
'@
$stdinFile=Join-Path $env:TEMP ('afz-h3-postmortem-v2-in-'+[guid]::NewGuid().ToString('n')+'.ps1')
$out=Join-Path $env:TEMP ('afz-h3-postmortem-v2-out-'+[guid]::NewGuid().ToString('n')+'.txt')
$err=Join-Path $env:TEMP ('afz-h3-postmortem-v2-err-'+[guid]::NewGuid().ToString('n')+'.txt')
try{
  [IO.File]::WriteAllText($stdinFile,$remote,[Text.Encoding]::ASCII)
  $sshArgs=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',("UserKnownHostsFile="+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-Command','-')
  $p=Start-Process -FilePath $ssh -ArgumentList $sshArgs -RedirectStandardInput $stdinFile -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
  if(-not $p.WaitForExit(90000)){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{};$r=[ordered]@{schema=1;version=2;ok=$false;status='failed';stage='ssh-stdin';error='postmortem v2 timeout';syncedSha=$SyncedSha;readOnly=$true;updatedAt=(Get-Date -Format o)};Save $r;exit 0}
  $p.WaitForExit();$sshExit=[int]$p.ExitCode
  $stdout=$(if(Test-Path -LiteralPath $out){[IO.File]::ReadAllText($out)}else{''})
  $stderr=$(if(Test-Path -LiteralPath $err){[IO.File]::ReadAllText($err)}else{''})
  $line=@(($stdout -split '\r?\n')|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1)
  $remoteResult=$null;if($line){try{$remoteResult=$line|ConvertFrom-Json}catch{}}
  $ok=($sshExit -eq 0 -and $remoteResult)
  $r=[ordered]@{schema=1;version=2;ok=$ok;status=$(if($ok){'captured'}else{'failed'});syncedSha=$SyncedSha;target='DESKTOP-H3R6CQN';transport='system-ssh-stdin-command';readOnly=$true;sshExit=$sshExit;remote=$remoteResult;stdout=$(if($remoteResult){$null}else{$stdout});stderr=$stderr.Trim();updatedAt=(Get-Date -Format o)}
  Save $r
  exit 0
}finally{Remove-Item -LiteralPath $stdinFile,$out,$err -Force -ErrorAction SilentlyContinue}
