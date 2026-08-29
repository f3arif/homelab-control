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
$root='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-return-publisher-hotfix'
$marker=Join-Path $root 'gh-argument-binding-v1.json'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$publisherRel='afz-openai-agent/tools/Publish-H3-GitHub-DirectReturn-V3.ps1'
$publisherRemote='C:\AFZ\GitHubDirect\Publish-H3-GitHub-DirectReturn-V3.ps1'
$publisherUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$SyncedSha/$publisherRel"
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return $null}}
function Save($Object){[IO.File]::WriteAllText($marker,($Object|ConvertTo-Json -Depth 30 -Compress),$utf8);Write-Output ($Object|ConvertTo-Json -Depth 30 -Compress)}

$prior=Read-Json $marker
if($prior){Write-Output ($prior|ConvertTo-Json -Depth 30 -Compress);exit 0}
$g=Read-Json $generationState
if(-not $g -or [int]$g.generation -ne 5 -or [string]$g.status -ne 'completed' -or -not [bool]$g.ok){
  Write-Output ([ordered]@{schema=1;status='not-applicable';reason='generation-5-not-completed';syncedSha=$SyncedSha}|ConvertTo-Json -Compress)
  exit 0
}
if(-not(Test-Path -LiteralPath $key -PathType Leaf)){throw "SYSTEM H3 key missing: $key"}
if(-not(Test-Path -LiteralPath $known -PathType Leaf)){throw "H3 known-hosts missing: $known"}
if(-not(Test-Path -LiteralPath $ssh -PathType Leaf)){throw "ssh.exe missing: $ssh"}

$remote=@"
`$ErrorActionPreference='Stop'
`$ProgressPreference='SilentlyContinue'
if(`$env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: `$env:COMPUTERNAME"}
`$publisher='$publisherRemote'
`$tmp=`$publisher+'.hotfix.tmp'
`$state='C:\ProgramData\AFZ\H3GitHubDirect\return-publisher-v3.json'
`$envelope='C:\ProgramData\AFZ\H3GitHubDirect\return-envelope.json'
`$controllerCount=0
try{
  foreach(`$p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"){
    `$cmd=[string]`$p.CommandLine
    if(`$cmd -and `$cmd.Contains('Run-H3-Qwen27B-WebsiteBenchmark.ps1') -and `$cmd.Contains('Qwen38-27B-Website-Benchmark-20260826-174739')){`$controllerCount++}
  }
}catch{}
Invoke-WebRequest -Uri '$publisherUrl' -OutFile `$tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-Return-Publisher-Hotfix'} -TimeoutSec 60
`$tokens=`$null;`$errors=`$null
[void][System.Management.Automation.Language.Parser]::ParseFile(`$tmp,[ref]`$tokens,[ref]`$errors)
if(@(`$errors).Count -gt 0){throw ('Publisher hotfix parse failure: '+((@(`$errors)|ForEach-Object {`$_.Message}) -join '; '))}
`$text=[IO.File]::ReadAllText(`$tmp)
if(`$text -notmatch 'function Invoke-Gh\(\[string\[\]\]\$GhArgs\)'){throw 'Publisher hotfix does not contain the GhArgs binding fix'}
Move-Item -LiteralPath `$tmp -Destination `$publisher -Force
`$hash=(Get-FileHash -LiteralPath `$publisher -Algorithm SHA256).Hash.ToLowerInvariant()
`$outFile=Join-Path `$env:TEMP ('afz-h3-return-hotfix-out-'+[guid]::NewGuid().ToString('n')+'.txt')
`$errFile=Join-Path `$env:TEMP ('afz-h3-return-hotfix-err-'+[guid]::NewGuid().ToString('n')+'.txt')
try{
  `$p=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',`$publisher) -RedirectStandardOutput `$outFile -RedirectStandardError `$errFile -PassThru -NoNewWindow
  if(-not `$p.WaitForExit(90000)){try{`$p.Kill()}catch{};try{`$p.WaitForExit()}catch{};throw 'Publisher hotfix run timed out after 90 seconds'}
  `$p.WaitForExit();`$exit=[int]`$p.ExitCode
  `$stdout=`$(if(Test-Path -LiteralPath `$outFile){[IO.File]::ReadAllText(`$outFile)}else{''})
  `$stderr=`$(if(Test-Path -LiteralPath `$errFile){[IO.File]::ReadAllText(`$errFile)}else{''})
}finally{Remove-Item -LiteralPath `$outFile,`$errFile -Force -ErrorAction SilentlyContinue}
`$stateObj=`$null;`$envObj=`$null
if(Test-Path -LiteralPath `$state -PathType Leaf){try{`$stateObj=[IO.File]::ReadAllText(`$state)|ConvertFrom-Json}catch{}}
if(Test-Path -LiteralPath `$envelope -PathType Leaf){try{`$envObj=[IO.File]::ReadAllText(`$envelope)|ConvertFrom-Json}catch{}}
[ordered]@{
  schema=1;host=`$env:COMPUTERNAME;returnOnly=`$true;controllerCount=`$controllerCount;publisherSha256=`$hash;
  publisherExit=`$exit;publisherStdout=`$stdout.Trim();publisherStderr=`$stderr.Trim();publisherState=`$stateObj;returnEnvelope=`$envObj;finishedAt=(Get-Date -Format o)
}|ConvertTo-Json -Depth 30 -Compress
"@

$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
$out=Join-Path $env:TEMP ('afz-h3-hotfix-ssh-out-'+[guid]::NewGuid().ToString('n')+'.txt')
$err=Join-Path $env:TEMP ('afz-h3-hotfix-ssh-err-'+[guid]::NewGuid().ToString('n')+'.txt')
try{
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',("UserKnownHostsFile="+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',$encoded)
  $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
  if(-not $p.WaitForExit(120000)){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{};throw 'H3 return publisher hotfix SSH timed out after 120 seconds'}
  $p.WaitForExit();$sshExit=[int]$p.ExitCode
  $stdout=$(if(Test-Path -LiteralPath $out){[IO.File]::ReadAllText($out)}else{''})
  $stderr=$(if(Test-Path -LiteralPath $err){[IO.File]::ReadAllText($err)}else{''})
  $line=@(($stdout -split '\r?\n')|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1)
  $remoteResult=$null
  if($line){try{$remoteResult=$line|ConvertFrom-Json}catch{}}
  $ok=($sshExit -eq 0 -and $remoteResult -and [int]$remoteResult.publisherExit -eq 0 -and $remoteResult.publisherState -and [bool]$remoteResult.publisherState.ok)
  $result=[ordered]@{schema=1;ok=$ok;status=$(if($ok){'completed'}else{'failed'});syncedSha=$SyncedSha;target='DESKTOP-H3R6CQN';transport='system-ssh-encoded-command';returnOnly=$true;sshExit=$sshExit;remote=$remoteResult;stdout=$(if($remoteResult){$null}else{$stdout});stderr=$stderr.Trim();finishedAt=(Get-Date -Format o)}
  Save $result
  if(-not $ok){exit 1}
  exit 0
}finally{Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue}
