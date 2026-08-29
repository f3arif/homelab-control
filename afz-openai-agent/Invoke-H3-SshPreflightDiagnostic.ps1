#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$SyncedSha
)
$ErrorActionPreference='Stop'
if($SyncedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SyncedSha must be a 40-character Git commit SHA'}
$SyncedSha=$SyncedSha.ToLowerInvariant()

$request=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-direct-bootstrap-generation.json'
$returnState='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-direct-return-generation\latest.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-ssh-preflight-diagnostic'
$stateFile=Join-Path $stateRoot 'generation-4.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'H3-SSH-PREFLIGHT-G4-LATEST.json'
$key='C:\Users\Faiz\.ssh\afz_h3_worker'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$target='Faiz@100.106.186.118'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return $null}}
function Save($Object){
  [IO.File]::WriteAllText($stateFile,($Object|ConvertTo-Json -Depth 12 -Compress),$utf8)
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagFile,($Object|ConvertTo-Json -Depth 12 -Compress),$utf8)}}catch{}
  Write-Output ($Object|ConvertTo-Json -Depth 12 -Compress)
}

$existing=Read-Json $stateFile
if($existing){Save $existing;exit 0}
$r=Read-Json $request
$s=Read-Json $returnState
if(-not $r -or [int]$r.generation -ne 4){Save ([ordered]@{schema=1;status='not-applicable';reason='generation-is-not-4';syncedSha=$SyncedSha;capturedAt=(Get-Date -Format o)});exit 0}
if(-not $s -or [int]$s.generation -ne 4 -or [string]$s.status -ne 'failed' -or [string]$s.error -notmatch 'H3 SSH preflight reached unexpected host'){
  Save ([ordered]@{schema=1;status='not-applicable';reason='generation-4-preflight-failure-not-present';syncedSha=$SyncedSha;capturedAt=(Get-Date -Format o)});exit 0
}

$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$aclOwner=$null;$aclProtected=$null;$aclPrincipals=@()
try{
  $acl=Get-Acl -LiteralPath $key -ErrorAction Stop
  $aclOwner=[string]$acl.Owner
  $aclProtected=[bool]$acl.AreAccessRulesProtected
  $aclPrincipals=@($acl.Access|ForEach-Object {([string]$_.IdentityReference)+'|'+([string]$_.FileSystemRights)+'|'+([string]$_.AccessControlType)})
}catch{$aclPrincipals=@('ACL_READ_FAILED: '+$_.Exception.Message)}

$outFile=Join-Path $env:TEMP ('afz-h3-ssh-preflight-g4-out-'+[guid]::NewGuid().ToString('n')+'.txt')
$errFile=Join-Path $env:TEMP ('afz-h3-ssh-preflight-g4-err-'+[guid]::NewGuid().ToString('n')+'.txt')
$exit=$null;$timedOut=$false;$stdout='';$stderr='';$exception=$null
try{
  if(-not(Test-Path -LiteralPath $ssh -PathType Leaf)){throw "ssh.exe missing: $ssh"}
  if(-not(Test-Path -LiteralPath $key -PathType Leaf)){throw "H3 key missing: $key"}
  if(-not(Test-Path -LiteralPath $known -PathType Leaf)){throw "H3 known-hosts missing: $known"}
  $args=@('-vvv','-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',("UserKnownHostsFile="+$known),$target,'hostname')
  $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -NoNewWindow
  if(-not $p.WaitForExit(15000)){$timedOut=$true;try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{}}
  if(-not $timedOut){$p.WaitForExit();$exit=[int]$p.ExitCode}
}catch{$exception=$_.Exception.Message}
finally{
  try{if(Test-Path -LiteralPath $outFile){$stdout=[IO.File]::ReadAllText($outFile)}}catch{$stdout='OUTPUT_READ_FAILED: '+$_.Exception.Message}
  try{if(Test-Path -LiteralPath $errFile){$stderr=[IO.File]::ReadAllText($errFile)}}catch{$stderr='ERROR_READ_FAILED: '+$_.Exception.Message}
  Remove-Item -LiteralPath $outFile,$errFile -Force -ErrorAction SilentlyContinue
}

$o=[ordered]@{
  schema=1;status='captured';generation=4;readOnly=$true;remoteCommand='hostname';syncedSha=$SyncedSha;
  identityName=[string]$identity.Name;identitySid=[string]$identity.User.Value;target=$target;keyPath=$key;
  aclOwner=$aclOwner;aclProtected=$aclProtected;aclPrincipals=$aclPrincipals;strictHostKeyChecking=$true;
  exitCode=$exit;timedOut=$timedOut;stdout=$stdout;stderr=$stderr;exception=$exception;capturedAt=(Get-Date -Format o)
}
Save $o
exit 0
