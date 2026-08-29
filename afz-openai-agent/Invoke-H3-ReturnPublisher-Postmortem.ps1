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
$marker=Join-Path $root 'postmortem-v4-auth.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'H3-RETURN-PUBLISHER-POSTMORTEM-LATEST.json'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return $null}}
function Publish-Diagnostic($Object){try{if(Test-Path -LiteralPath $diagRoot -PathType Container){$d=[ordered]@{schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';source='windows-main';controlPlane='github';observedAt=(Get-Date -Format o);postmortem=$Object};[IO.File]::WriteAllText($diagFile,($d|ConvertTo-Json -Depth 40 -Compress),$utf8)}}catch{}}
function Save($Object){[IO.File]::WriteAllText($marker,($Object|ConvertTo-Json -Depth 40 -Compress),$utf8);Publish-Diagnostic $Object;Write-Output ($Object|ConvertTo-Json -Depth 40 -Compress)}
function Invoke-SshJson([string]$Script){
  $out=Join-Path $env:TEMP ('afz-h3-auth4-out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $err=Join-Path $env:TEMP ('afz-h3-auth4-err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $sshArgs=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',("UserKnownHostsFile="+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',$encoded)
    $p=Start-Process -FilePath $ssh -ArgumentList $sshArgs -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
    $timedOut=$false;if(-not $p.WaitForExit(30000)){$timedOut=$true;try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{}}
    if(-not $timedOut){$p.WaitForExit();$exit=[int]$p.ExitCode}else{$exit=$null}
    $stdout=$(if(Test-Path -LiteralPath $out){[IO.File]::ReadAllText($out)}else{''});$stderr=$(if(Test-Path -LiteralPath $err){[IO.File]::ReadAllText($err)}else{''})
    $line=@(($stdout -split '\r?\n')|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1);$remote=$null;if($line){try{$remote=$line|ConvertFrom-Json}catch{}}
    return [ordered]@{exit=$exit;timedOut=$timedOut;remote=$remote;stdout=$(if($remote){$null}else{$stdout.Trim()});stderr=$stderr.Trim()}
  }finally{Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue}
}

$prior=Read-Json $marker
if($prior){Publish-Diagnostic $prior;Write-Output ($prior|ConvertTo-Json -Depth 40 -Compress);exit 0}
$g=Read-Json $generationState
if(-not $g -or [int]$g.generation -ne 5 -or [string]$g.status -ne 'completed' -or -not [bool]$g.ok){Save ([ordered]@{schema=1;version=4;ok=$false;status='not-applicable';reason='generation-5-not-completed';syncedSha=$SyncedSha;readOnly=$true;updatedAt=(Get-Date -Format o)});exit 0}
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){Save ([ordered]@{schema=1;version=4;ok=$false;status='failed';stage='local-prerequisite';error="Missing prerequisite: $p";syncedSha=$SyncedSha;readOnly=$true;updatedAt=(Get-Date -Format o)});exit 0}}

$probe=@'
$ProgressPreference='SilentlyContinue';$ErrorActionPreference='Continue'
$gh=$null;$c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Source){$gh=[string]$c.Source}elseif($c.Path){$gh=[string]$c.Path}}
if(-not $gh){foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path -LiteralPath $p -PathType Leaf){$gh=$p;break}}}
$hasGhToken=Test-Path Env:GH_TOKEN;$hasGithubToken=Test-Path Env:GITHUB_TOKEN;$configDir=[string]$env:GH_CONFIG_DIR
$hosts=@();foreach($p in @((Join-Path $env:APPDATA 'GitHub CLI\hosts.yml'),(Join-Path $env:USERPROFILE 'AppData\Roaming\GitHub CLI\hosts.yml'))|Select-Object -Unique){if(Test-Path -LiteralPath $p -PathType Leaf){$f=Get-Item -LiteralPath $p;$hosts+=[ordered]@{path=$p;length=[long]$f.Length;lastWrite=$f.LastWriteTime.ToString('o')}}}
$before='';$beforeExit=$null;if($gh){$before=((& $gh api user --jq .login 2>&1)|Out-String).Trim();$beforeExit=$LASTEXITCODE}
if($hasGhToken){Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue};if($hasGithubToken){Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue}
$after='';$afterExit=$null;$push='';$pushExit=$null;if($gh){$after=((& $gh api user --jq .login 2>&1)|Out-String).Trim();$afterExit=$LASTEXITCODE;$push=((& $gh api repos/f3arif/homelab-control --jq .permissions.push 2>&1)|Out-String).Trim();$pushExit=$LASTEXITCODE}
[ordered]@{host=$env:COMPUTERNAME;ghPath=$gh;hadGhTokenEnv=$hasGhToken;hadGithubTokenEnv=$hasGithubToken;ghConfigDir=$configDir;hostsFiles=$hosts;beforeExit=$beforeExit;beforeOutput=$before;afterEnvRemovalExit=$afterExit;afterEnvRemovalOutput=$after;pushAfterEnvRemovalExit=$pushExit;pushAfterEnvRemovalOutput=$push}|ConvertTo-Json -Depth 8 -Compress
'@
$p=Invoke-SshJson $probe
$ok=($p.exit -eq 0 -and -not $p.timedOut -and $p.remote)
$r=[ordered]@{schema=1;version=4;ok=$ok;status=$(if($ok){'captured'}else{'failed'});syncedSha=$SyncedSha;target='DESKTOP-H3R6CQN';transport='system-ssh-auth-encoded';readOnly=$true;auth=$p;updatedAt=(Get-Date -Format o)}
Save $r
exit 0
