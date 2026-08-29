#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$SyncedSha
)
$ErrorActionPreference='Stop'
if($SyncedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SyncedSha must be a 40-character Git commit SHA'}
$SyncedSha=$SyncedSha.ToLowerInvariant()
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-direct-return-generation'
$stateFile=Join-Path $stateRoot 'latest.json'
$bootstrapState='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-github-direct-bootstrap\latest.json'
$request=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-direct-bootstrap-generation.json'
$bootstrap=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-H3-GitHub-DirectBenchmark.ps1'
$logFile=Join-Path $stateRoot 'latest.log'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'H3-DIRECT-RETURN-GENERATION-LATEST.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
function Write-State($Object){[IO.File]::WriteAllText($stateFile,($Object|ConvertTo-Json -Depth 12 -Compress),$utf8)}
function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return $null}}
function Read-LogTail{
  if(-not(Test-Path -LiteralPath $logFile -PathType Leaf)){return @()}
  try{return @(Get-Content -LiteralPath $logFile -Tail 80 -ErrorAction Stop|ForEach-Object {[string]$_})}catch{return @('LOG_READ_FAILED: '+$_.Exception.Message)}
}
function Invoke-OneShotSshDiagnostic([int]$Generation){
  $diagState=Join-Path $stateRoot ("ssh-diagnostic-g$Generation-v2.json")
  $existing=Read-Json $diagState
  if($existing){return $existing}
  $key='C:\Users\Faiz\.ssh\afz_h3_worker'
  $known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
  $ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
  $target='Faiz@100.106.186.118'
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  $aclOwner=$null;$aclProtected=$null;$aclPrincipals=@()
  try{
    $acl=Get-Acl -LiteralPath $key -ErrorAction Stop
    $aclOwner=[string]$acl.Owner
    $aclProtected=[bool]$acl.AreAccessRulesProtected
    $aclPrincipals=@($acl.Access|ForEach-Object {([string]$_.IdentityReference)+'|'+([string]$_.FileSystemRights)+'|'+([string]$_.AccessControlType)})
  }catch{$aclPrincipals=@('ACL_READ_FAILED: '+$_.Exception.Message)}
  $stdout=Join-Path $env:TEMP ('afz-h3-sshdiag-out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $stderr=Join-Path $env:TEMP ('afz-h3-sshdiag-err-'+[guid]::NewGuid().ToString('n')+'.txt')
  $exit=$null;$timedOut=$false;$out='';$err=''
  try{
    if(-not(Test-Path -LiteralPath $ssh -PathType Leaf)){throw "ssh.exe missing: $ssh"}
    if(-not(Test-Path -LiteralPath $key -PathType Leaf)){throw "H3 key missing: $key"}
    if(-not(Test-Path -LiteralPath $known -PathType Leaf)){throw "H3 known-hosts missing: $known"}
    $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o',("UserKnownHostsFile="+$known),'-o','ConnectTimeout=8',$target,'hostname')
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow
    if(-not $p.WaitForExit(15000)){$timedOut=$true;try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{}}
    if(-not $timedOut){$p.WaitForExit();$exit=[int]$p.ExitCode}
    if(Test-Path -LiteralPath $stdout){$out=[IO.File]::ReadAllText($stdout).Trim()}
    if(Test-Path -LiteralPath $stderr){$err=[IO.File]::ReadAllText($stderr).Trim()}
  }catch{$err=('DIAGNOSTIC_EXCEPTION: '+$_.Exception.Message)}
  finally{Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue}
  $o=[ordered]@{
    schema=1;generation=$Generation;diagnosticVersion=2;readOnly=$true;remoteCommand='hostname';identityName=[string]$identity.Name;identitySid=[string]$identity.User.Value;
    keyPath=$key;aclOwner=$aclOwner;aclProtected=$aclProtected;aclPrincipals=$aclPrincipals;strictHostKeyChecking=$true;target=$target;
    exitCode=$exit;timedOut=$timedOut;stdout=$out;stderr=$err;capturedAt=(Get-Date -Format o)
  }
  [IO.File]::WriteAllText($diagState,($o|ConvertTo-Json -Depth 12 -Compress),$utf8)
  return $o
}
function Invoke-OneShotPublisherDiagnostic([int]$Generation){
  $diagState=Join-Path $stateRoot ("publisher-diagnostic-g$Generation-v2.json")
  $existing=Read-Json $diagState
  if($existing){return $existing}
  $key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
  $known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
  $ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
  $target='Faiz@100.106.186.118'
  $stdoutFile=Join-Path $env:TEMP ('afz-h3-pubdiag2-out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $stderrFile=Join-Path $env:TEMP ('afz-h3-pubdiag2-err-'+[guid]::NewGuid().ToString('n')+'.txt')
  $remote=@'
$ErrorActionPreference='Stop'
$taskName='AFZ H3 GitHub Direct Return Publisher'
$publisher='C:\AFZ\GitHubDirect\Publish-H3-GitHub-DirectReturn-V3.ps1'
$statePath='C:\ProgramData\AFZ\H3GitHubDirect\return-publisher-v3.json'
$returnEnvelope='C:\ProgramData\AFZ\H3GitHubDirect\return-envelope.json'
$t=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$i=$null
if($t){$i=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue}
$stateRaw=$null
$stateObj=$null
if(Test-Path -LiteralPath $statePath -PathType Leaf){try{$stateRaw=[IO.File]::ReadAllText($statePath);$stateObj=$stateRaw|ConvertFrom-Json}catch{}}
$envelopeRaw=$null
$envelopeObj=$null
if(Test-Path -LiteralPath $returnEnvelope -PathType Leaf){try{$envelopeRaw=[IO.File]::ReadAllText($returnEnvelope);$envelopeObj=$envelopeRaw|ConvertFrom-Json}catch{}}
$controllerCount=0
try{
  foreach($p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"){
    $cmd=[string]$p.CommandLine
    if($cmd -and $cmd.Contains('Run-H3-Qwen27B-WebsiteBenchmark.ps1') -and $cmd.Contains('Qwen38-27B-Website-Benchmark-20260826-174739')){$controllerCount++}
  }
}catch{}
$legacy=Get-ScheduledTask -TaskName 'AFZ H3 GitHub Direct Benchmark Watcher' -ErrorAction SilentlyContinue
$action=$null;$principal=$null
if($t){
  $action=@($t.Actions|ForEach-Object {[ordered]@{execute=[string]$_.Execute;arguments=[string]$_.Arguments}})
  $principal=[ordered]@{userId=[string]$t.Principal.UserId;logonType=[string]$t.Principal.LogonType;runLevel=[string]$t.Principal.RunLevel}
}
$o=[ordered]@{
  host=$env:COMPUTERNAME
  readOnly=$true
  taskExists=[bool]$t
  taskState=$(if($t){[string]$t.State}else{$null})
  taskLastResult=$(if($i){[int]$i.LastTaskResult}else{$null})
  taskLastRunTime=$(if($i){$i.LastRunTime.ToString('o')}else{$null})
  taskNextRunTime=$(if($i){$i.NextRunTime.ToString('o')}else{$null})
  taskActions=$action
  taskPrincipal=$principal
  publisherExists=(Test-Path -LiteralPath $publisher -PathType Leaf)
  publisherSha256=$(if(Test-Path -LiteralPath $publisher -PathType Leaf){(Get-FileHash -LiteralPath $publisher -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null})
  publisherLastWrite=$(if(Test-Path -LiteralPath $publisher -PathType Leaf){(Get-Item -LiteralPath $publisher).LastWriteTime.ToString('o')}else{$null})
  stateFileExists=(Test-Path -LiteralPath $statePath -PathType Leaf)
  publisherState=$stateObj
  publisherStateRaw=$(if($stateObj){$null}else{$stateRaw})
  returnEnvelopeExists=(Test-Path -LiteralPath $returnEnvelope -PathType Leaf)
  returnEnvelope=$envelopeObj
  returnEnvelopeRaw=$(if($envelopeObj){$null}else{$envelopeRaw})
  controllerCount=$controllerCount
  legacyWatcherState=$(if($legacy){[string]$legacy.State}else{$null})
  capturedAt=(Get-Date -Format o)
}
Write-Output ($o|ConvertTo-Json -Depth 20 -Compress)
'@
  $exit=$null;$timedOut=$false;$stdout='';$stderr='';$parsed=$null;$exception=$null
  try{
    if(-not(Test-Path -LiteralPath $ssh -PathType Leaf)){throw "ssh.exe missing: $ssh"}
    if(-not(Test-Path -LiteralPath $key -PathType Leaf)){throw "SYSTEM H3 key missing: $key"}
    if(-not(Test-Path -LiteralPath $known -PathType Leaf)){throw "H3 known-hosts missing: $known"}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
    $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',("UserKnownHostsFile="+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',$encoded)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -PassThru -NoNewWindow
    if(-not $p.WaitForExit(30000)){$timedOut=$true;try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{}}
    if(-not $timedOut){$p.WaitForExit();$exit=[int]$p.ExitCode}
    if(Test-Path -LiteralPath $stdoutFile){$stdout=[IO.File]::ReadAllText($stdoutFile)}
    if(Test-Path -LiteralPath $stderrFile){$stderr=[IO.File]::ReadAllText($stderrFile)}
    $jsonLine=@(($stdout -split '\r?\n')|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1)
    if($jsonLine){try{$parsed=$jsonLine|ConvertFrom-Json}catch{}}
  }catch{$exception=$_.Exception.Message}
  finally{Remove-Item -LiteralPath $stdoutFile,$stderrFile -Force -ErrorAction SilentlyContinue}
  $o=[ordered]@{
    schema=1;generation=$Generation;diagnosticVersion=2;readOnly=$true;transport='ssh-encoded-command';target=$target;exitCode=$exit;timedOut=$timedOut;
    remote=$parsed;stdout=$(if($parsed){$null}else{$stdout});stderr=$stderr.Trim();exception=$exception;capturedAt=(Get-Date -Format o)
  }
  [IO.File]::WriteAllText($diagState,($o|ConvertTo-Json -Depth 30 -Compress),$utf8)
  return $o
}
function Publish-Diagnostic($Object){
  try{
    if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){return}
    $d=[ordered]@{schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';source='windows-main';controlPlane='github';observedAt=(Get-Date -Format o);state=$Object}
    [IO.File]::WriteAllText($diagFile,($d|ConvertTo-Json -Depth 30 -Compress),$utf8)
  }catch{}
}
function Emit($Object){Publish-Diagnostic $Object;Write-Output ($Object|ConvertTo-Json -Depth 30 -Compress);exit 0}

$generation=0
try{
  if(-not(Test-Path -LiteralPath $request -PathType Leaf)){Emit ([ordered]@{ok=$true;status='not-requested';generation=0;syncedSha=$SyncedSha})}
  $r=Get-Content -LiteralPath $request -Raw|ConvertFrom-Json
  if([int]$r.schema -ne 1){throw 'Return generation request schema must be 1'}
  if([string]$r.purpose -ne 'force-exact-sha-bootstrap-generation'){throw 'Unexpected return generation request purpose'}
  if([string]$r.target -ne 'DESKTOP-H3R6CQN'){throw 'Unexpected return generation target'}
  if([string]$r.lane -ne 'h3-direct-github-benchmark'){throw 'Unexpected return generation lane'}
  if([string]$r.benchmark_job_id -ne 'qwen27b-website-20260827-i02'){throw 'Unexpected benchmark job id in return generation request'}
  $generation=[int]$r.generation
  if($generation -lt 1){throw 'Return generation must be >= 1'}

  $prior=Read-Json $stateFile
  if($prior -and [int]$prior.generation -ge $generation){
    $sshDiagnostic=$null
    $publisherDiagnostic=$null
    if($generation -le 4){$sshDiagnostic=Invoke-OneShotSshDiagnostic $generation}
    if($generation -ge 5){$publisherDiagnostic=Invoke-OneShotPublisherDiagnostic $generation}
    Emit ([ordered]@{ok=([bool]$prior.ok);status='already-attempted';generation=$generation;priorStatus=[string]$prior.status;syncedSha=$SyncedSha;prior=$prior;bootstrapLogTail=(Read-LogTail);sshDiagnostic=$sshDiagnostic;publisherDiagnostic=$publisherDiagnostic})
  }
  if(-not(Test-Path -LiteralPath $bootstrap -PathType Leaf)){throw "Return bootstrap missing: $bootstrap"}
  $text=Get-Content -LiteralPath $bootstrap -Raw
  if($text -notmatch [regex]::Escape('Return-only recovery: this script never launches Qwen or creates a benchmark iteration.')){throw 'Return-only bootstrap safety marker missing'}
  if($text -notmatch 'Bootstrap-H3-GitHub-DirectReturnV4\.ps1'){throw 'Return bootstrap is not wired to stdin/V4 transport'}

  $running=[ordered]@{ok=$false;status='running';generation=$generation;syncedSha=$SyncedSha;benchmarkJobId=[string]$r.benchmark_job_id;mode='return-only-v4';startedAt=(Get-Date -Format o)}
  Write-State $running
  Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bootstrap -ExpectedSha $SyncedSha -InstallRoot $InstallRoot *> $logFile
  $code=$LASTEXITCODE
  $bs=Read-Json $bootstrapState
  $completed=($code -eq 0 -and $bs -and [string]$bs.status -eq 'completed')
  $terminal=[ordered]@{
    ok=$completed
    status=$(if($completed){'completed'}else{'failed'})
    generation=$generation
    syncedSha=$SyncedSha
    benchmarkJobId=[string]$r.benchmark_job_id
    mode='return-only-v4'
    bootstrapExit=$code
    bootstrapStatus=$(if($bs){[string]$bs.status}else{$null})
    bootstrapMessage=$(if($bs){[string]$bs.message}else{$null})
    bootstrapLogTail=(Read-LogTail)
    finishedAt=(Get-Date -Format o)
  }
  Write-State $terminal
  Emit $terminal
}catch{
  $failed=[ordered]@{ok=$false;status='failed';generation=$generation;syncedSha=$SyncedSha;mode='return-only-v4';error=$_.Exception.Message;bootstrapLogTail=(Read-LogTail);finishedAt=(Get-Date -Format o)}
  if($generation -gt 0){try{Write-State $failed}catch{}}
  Emit $failed
}
