#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-docker-desktop-preflight.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Docker preflight request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid H3 Docker preflight request identity.'}
if([string]$req.action -ne 'preflight-docker-desktop' -or [string]$req.status -ne 'ACTIVE'){throw 'H3 Docker preflight request is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'H3 Docker preflight target mismatch.'}
if(-not [bool]$req.read_only -or [bool]$req.allow_install -or [bool]$req.allow_reboot -or [bool]$req.mutate_ollama){throw 'H3 Docker preflight safety flags mismatch.'}
$minDisk=[int]$req.minimum_free_disk_gb
if($minDisk -lt 10 -or $minDisk -gt 200){throw 'H3 Docker preflight disk threshold is invalid.'}

$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-docker-desktop-preflight'
$statePath=Join-Path $stateRoot ($id+'.json')
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-DOCKER-PREFLIGHT-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required H3 SSH path missing: $p"}}
function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$json,$utf8)}}catch{}
  Write-Output ($o|ConvertTo-Json -Depth 12 -Compress)
}

$remote=@"
`$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
function Test-PendingReboot{
  `$pending=`$false
  foreach(`$p in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
  )){if(Test-Path -LiteralPath `$p){`$pending=`$true}}
  try{`$v=(Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations;if(`$v){`$pending=`$true}}catch{}
  return `$pending
}
function Get-WslProbe{
  `$present=[bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
  `$version=`$null;`$statusOk=`$false;`$timedOut=`$false
  if(`$present){
    `$out=Join-Path `$env:TEMP ('afz-wsl-'+[guid]::NewGuid().ToString('n')+'.out')
    `$err=Join-Path `$env:TEMP ('afz-wsl-'+[guid]::NewGuid().ToString('n')+'.err')
    try{
      `$p=Start-Process -FilePath (Join-Path `$env:WINDIR 'System32\wsl.exe') -ArgumentList '--version' -RedirectStandardOutput `$out -RedirectStandardError `$err -PassThru -WindowStyle Hidden
      if(-not `$p.WaitForExit(10000)){`$timedOut=`$true;try{`$p.Kill()}catch{}}
      elseif(`$p.ExitCode -eq 0){`$version=(([IO.File]::ReadAllText(`$out)) -replace "`0",'').Trim();`$statusOk=`$true}
    }catch{}finally{Remove-Item -LiteralPath `$out,`$err -Force -ErrorAction SilentlyContinue}
  }
  return [ordered]@{present=`$present;version=`$version;statusOk=`$statusOk;timedOut=`$timedOut}
}
`$os=Get-CimInstance Win32_OperatingSystem
`$cpu=Get-CimInstance Win32_Processor|Select-Object -First 1
`$disk=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
`$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
`$isAdmin=`$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
`$winget=Get-Command winget.exe -ErrorAction SilentlyContinue|Select-Object -First 1
`$wsl=Get-WslProbe
`$dockerCli=Get-Command docker.exe -ErrorAction SilentlyContinue|Select-Object -First 1
`$dockerCliPath=if(`$dockerCli){[string]`$dockerCli.Source}else{`$null}
`$dockerDesktopPath='C:\Program Files\Docker\Docker\Docker Desktop.exe'
`$dockerFixedCli='C:\Program Files\Docker\Docker\resources\bin\docker.exe'
`$dockerInstalled=(Test-Path -LiteralPath `$dockerDesktopPath -PathType Leaf) -or (Test-Path -LiteralPath `$dockerFixedCli -PathType Leaf)
`$svc=Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
`$freeGb=[math]::Round(([double]`$disk.FreeSpace/1GB),1)
`$virtFirmware=`$null
try{if(`$cpu.PSObject.Properties.Name -contains 'VirtualizationFirmwareEnabled'){`$virtFirmware=[bool]`$cpu.VirtualizationFirmwareEnabled}}catch{}
`$pending=Test-PendingReboot
`$reasons=New-Object Collections.Generic.List[string]
if(-not `$isAdmin){`$reasons.Add('ssh-identity-not-administrator')}
if(-not `$winget){`$reasons.Add('winget-missing')}
if(-not `$wsl.present){`$reasons.Add('wsl-missing')}
elseif(-not `$wsl.statusOk){`$reasons.Add('wsl-version-check-failed')}
if(`$virtFirmware -eq `$false){`$reasons.Add('virtualization-disabled-in-firmware')}
if(`$freeGb -lt $minDisk){`$reasons.Add('insufficient-free-disk')}
if(`$pending){`$reasons.Add('pending-reboot')}
`$classification=if(`$dockerInstalled){'H3_DOCKER_DESKTOP_ALREADY_INSTALLED'}elseif(`$reasons.Count -eq 0){'H3_DOCKER_DESKTOP_INSTALL_READY'}else{'H3_DOCKER_DESKTOP_INSTALL_BLOCKED'}
[ordered]@{
  schema=1
  ok=(`$classification -ne 'H3_DOCKER_DESKTOP_INSTALL_BLOCKED')
  classification=`$classification
  host=`$env:COMPUTERNAME
  readOnly=`$true
  currentUser=[Security.Principal.WindowsIdentity]::GetCurrent().Name
  isAdministrator=`$isAdmin
  wingetPresent=[bool]`$winget
  wingetPath=if(`$winget){[string]`$winget.Source}else{`$null}
  wslPresent=[bool]`$wsl.present
  wslStatusOk=[bool]`$wsl.statusOk
  wslProbeTimedOut=[bool]`$wsl.timedOut
  wslVersion=[string]`$wsl.version
  virtualizationFirmwareEnabled=`$virtFirmware
  windowsCaption=[string]`$os.Caption
  windowsVersion=[string]`$os.Version
  windowsBuild=[string]`$os.BuildNumber
  freeDiskGb=`$freeGb
  minimumFreeDiskGb=$minDisk
  pendingReboot=`$pending
  dockerCliPresent=[bool]`$dockerCli
  dockerCliPath=`$dockerCliPath
  dockerDesktopInstalled=[bool]`$dockerInstalled
  dockerDesktopPath=`$dockerDesktopPath
  dockerServicePresent=[bool]`$svc
  dockerServiceStatus=if(`$svc){[string]`$svc.Status}else{'missing'}
  blockers=@(`$reasons)
  installStarted=`$false
  rebootStarted=`$false
  dockerMutationStarted=`$false
  ollamaMutationStarted=`$false
  observedAt=(Get-Date -Format o)
}|ConvertTo-Json -Depth 8 -Compress
"@

$inFile=Join-Path $env:TEMP ('afz-h3-docker-preflight-'+[guid]::NewGuid().ToString('n')+'.ps1')
$outFile=Join-Path $env:TEMP ('afz-h3-docker-preflight-'+[guid]::NewGuid().ToString('n')+'.out')
$errFile=Join-Path $env:TEMP ('afz-h3-docker-preflight-'+[guid]::NewGuid().ToString('n')+'.err')
$bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 Docker preflight remote stdin was empty.''};Invoke-Expression $script'
$bootstrapEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
$args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$bootstrapEncoded)
try{
  [IO.File]::WriteAllText($inFile,$remote,$utf8)
  $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
  if(-not $p.WaitForExit(120000)){try{$p.Kill()}catch{};throw 'H3 Docker Desktop preflight exceeded 120 seconds.'}
  $stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
  $stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
  if([string]::IsNullOrWhiteSpace($stdout)){throw "H3 Docker preflight SSH returned no result. exit=$($p.ExitCode) stderr=$stderr"}
  $lines=@($stdout -split "`r?`n"|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
  $result=$lines[$lines.Count-1]|ConvertFrom-Json
  $result|Add-Member -NotePropertyName jobId -NotePropertyValue $id -Force
  $result|Add-Member -NotePropertyName purpose -NotePropertyValue 'EMERGENCY_DIAGNOSTIC_ACK_ONLY' -Force
  $result|Add-Member -NotePropertyName controlPlane -NotePropertyValue 'github' -Force
  Save-State $result
  if([string]$result.classification -eq 'H3_DOCKER_DESKTOP_INSTALL_BLOCKED'){exit 31}
  exit 0
}catch{
  Save-State ([ordered]@{schema=1;ok=$false;classification='H3_DOCKER_DESKTOP_PREFLIGHT_TRANSPORT_FAILED';jobId=$id;host='DESKTOP-H3R6CQN';readOnly=$true;retryable=$true;transportError=$_.Exception.Message;installStarted=$false;rebootStarted=$false;dockerMutationStarted=$false;ollamaMutationStarted=$false;observedAt=(Get-Date -Format o);purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';controlPlane='github'})
  exit 75
}finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
