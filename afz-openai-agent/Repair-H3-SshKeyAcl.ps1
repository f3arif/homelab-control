#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$keyPath='C:\Users\Faiz\.ssh\afz_h3_worker'
$keygen=Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$knownHosts='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$expectedHost='DESKTOP-H3R6CQN'
$expectedFingerprint='SHA256:xUZpwFvzX4H4qhRFHYNrHsITVC6XZXJ8vYe6yoN7R7I'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'H3-SSH-KEY-ACL-REPAIR-LATEST.txt'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-ssh-key-acl-repair'
$statePath=Join-Path $stateRoot 'latest.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Save-Result($o){
  $json=$o | ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  Write-Output ($o | ConvertTo-Json -Depth 12 -Compress)
}

try{
  foreach($p in @($keyPath,$keygen,$ssh,$knownHosts)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required path missing: $p"}}
  $systemSidText='S-1-5-18'
  $systemSid=New-Object System.Security.Principal.SecurityIdentifier($systemSidText)

  # This is a dedicated AFZ automation key. The AFZ Agent and updater are SYSTEM tasks,
  # so current Win32 OpenSSH requires the private key to be owned/readable only by SYSTEM.
  # Key bytes are never changed or exported.
  $oldEap=$ErrorActionPreference;$ErrorActionPreference='Continue'
  $takeOwnOut=(& takeown.exe /F $keyPath /A 2>&1 | Out-String).Trim();$takeOwnExit=$LASTEXITCODE
  $ErrorActionPreference=$oldEap
  if($takeOwnExit -ne 0){throw "takeown failed: $takeOwnOut"}

  $security=New-Object System.Security.AccessControl.FileSecurity
  $security.SetOwner($systemSid)
  $security.SetAccessRuleProtection($true,$false)
  $rights=[System.Security.AccessControl.FileSystemRights]::FullControl
  $inherit=[System.Security.AccessControl.InheritanceFlags]::None
  $prop=[System.Security.AccessControl.PropagationFlags]::None
  $allow=[System.Security.AccessControl.AccessControlType]::Allow
  $rule=New-Object System.Security.AccessControl.FileSystemAccessRule($systemSid,$rights,$inherit,$prop,$allow)
  [void]$security.AddAccessRule($rule)
  Set-Acl -LiteralPath $keyPath -AclObject $security -ErrorAction Stop

  $acl=Get-Acl -LiteralPath $keyPath -ErrorAction Stop
  $ownerSid=$null
  try{$ownerSid=([System.Security.Principal.NTAccount]$acl.Owner).Translate([System.Security.Principal.SecurityIdentifier]).Value}catch{$ownerSid=[string]$acl.Owner}
  if($ownerSid -ne $systemSidText){throw "Unexpected owner after ACL repair: $ownerSid"}
  if(-not $acl.AreAccessRulesProtected){throw 'ACL inheritance remains enabled.'}
  $actual=@()
  foreach($r in @($acl.Access)){
    try{$sidText=$r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value}catch{$sidText=[string]$r.IdentityReference}
    $actual+=$sidText
    if($sidText -ne $systemSidText){throw "Unexpected ACL principal remains: $sidText"}
    if($r.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow){throw "Unexpected deny ACL remains: $sidText"}
  }
  if($actual.Count -ne 1 -or $actual[0] -ne $systemSidText){throw 'SYSTEM-only ACL verification failed.'}

  $oldEap=$ErrorActionPreference;$ErrorActionPreference='Continue'
  $derived=(& $keygen -y -f $keyPath 2>&1 | Select-Object -First 1);$deriveExit=$LASTEXITCODE
  $ErrorActionPreference=$oldEap
  if($deriveExit -ne 0 -or [string]::IsNullOrWhiteSpace([string]$derived)){throw "Could not read SYSTEM-owned H3 private key: $derived"}
  $tmpPub=Join-Path $env:TEMP ('afz-h3-acl-'+[guid]::NewGuid().ToString('n')+'.pub')
  try{
    ([string]$derived).Trim() | Set-Content -LiteralPath $tmpPub -Encoding ascii
    $oldEap=$ErrorActionPreference;$ErrorActionPreference='Continue'
    $fingerprint=((& $keygen -lf $tmpPub 2>&1) -join ' ').Trim();$fpExit=$LASTEXITCODE
    $ErrorActionPreference=$oldEap
  }finally{Remove-Item -LiteralPath $tmpPub -Force -ErrorAction SilentlyContinue}
  if($fpExit -ne 0 -or $fingerprint -notmatch [regex]::Escape($expectedFingerprint)){throw "Pinned H3 key fingerprint mismatch: $fingerprint"}

  $attempts=@(
    [ordered]@{transport='tailscale';target='Faiz@100.106.186.118';hostKeyAlias=$null},
    [ordered]@{transport='lan';target='Faiz@192.168.50.185';hostKeyAlias='100.106.186.118'}
  )
  $proofs=@();$success=$null
  foreach($a in $attempts){
    $args=@('-i',$keyPath,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$knownHosts))
    if($a.hostKeyAlias){$args+=@('-o',('HostKeyAlias='+$a.hostKeyAlias))}
    $args+=@($a.target,'hostname')
    $oldEap=$ErrorActionPreference;$ErrorActionPreference='Continue'
    $out=@(& $ssh @args 2>&1);$code=$LASTEXITCODE
    $ErrorActionPreference=$oldEap
    $text=($out|Out-String).Trim();$remoteHost=(($text -split "`r?`n")|Where-Object {$_.Trim()}|Select-Object -Last 1).Trim()
    $proofs+=[ordered]@{transport=$a.transport;exitCode=$code;remoteHost=$remoteHost;output=$text.Substring(0,[math]::Min(3000,$text.Length))}
    if($code -eq 0 -and $remoteHost -ieq $expectedHost){$success=$a.transport;break}
  }
  if(-not $success){throw 'Strict H3 SSH proof failed after SYSTEM-only ACL repair.'}

  $r=[ordered]@{schema=1;status='completed';classification='H3_SYSTEM_SSH_KEY_ACL_REPAIRED_AND_VERIFIED';computer=$env:COMPUTERNAME;ownerSid=$ownerSid;aclProtected=[bool]$acl.AreAccessRulesProtected;approvedAclSids=$systemSidText;fingerprint=$fingerprint;keyContentChanged=$false;keyExported=$false;remoteMutation=$false;transportUsed=$success;proofs=$proofs;time=(Get-Date -Format o)}
  Save-Result $r
  exit 0
}catch{
  $r=[ordered]@{schema=1;status='failed';classification='H3_SYSTEM_SSH_KEY_ACL_REPAIR_FAILED';computer=$env:COMPUTERNAME;keyContentChanged=$false;keyExported=$false;remoteMutation=$false;error=$_.Exception.Message;detail=($_|Out-String).Trim();time=(Get-Date -Format o)}
  Save-Result $r
  exit 20
}
