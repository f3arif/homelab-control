#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){ throw "WRONG_HOST $env:COMPUTERNAME" }

$srcLetter='I'
$dstLetter='F'

$srcPart=Get-Partition -DriveLetter $srcLetter -ErrorAction Stop
$srcDisk=Get-Disk -Number $srcPart.DiskNumber -ErrorAction Stop
$dstPart=Get-Partition -DriveLetter $dstLetter -ErrorAction Stop
$dstDisk=Get-Disk -Number $dstPart.DiskNumber -ErrorAction Stop
$dstVol=Get-Volume -DriveLetter $dstLetter -ErrorAction Stop

if($srcDisk.Number -eq $dstDisk.Number){ throw 'SOURCE_AND_DESTINATION_SAME_DISK' }
if($srcDisk.IsBoot -or $srcDisk.IsSystem){ throw 'SOURCE_IS_BOOT_OR_SYSTEM_DISK' }
if(-not (Test-Path 'I:\Windows')){ throw 'SOURCE_WINDOWS_FOLDER_MISSING' }
if(-not (Test-Path 'I:\Users')){ throw 'SOURCE_USERS_FOLDER_MISSING' }
if([string]$dstVol.FileSystemLabel -ne 'AFZ_MEDIA'){ throw "DESTINATION_LABEL_MISMATCH actual=$($dstVol.FileSystemLabel)" }

$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$root="F:\Backups\WindowsMain-Recovery-$stamp"
New-Item -ItemType Directory -Force -Path $root | Out-Null

$manifest=[ordered]@{
  schema=1
  host=$env:COMPUTERNAME
  startedAt=(Get-Date -Format o)
  source=[ordered]@{
    drive='I:'
    diskNumber=$srcDisk.Number
    friendlyName=$srcDisk.FriendlyName
    serialNumber=$srcDisk.SerialNumber
    busType=[string]$srcDisk.BusType
    size=[int64]$srcDisk.Size
    isBoot=[bool]$srcDisk.IsBoot
    isSystem=[bool]$srcDisk.IsSystem
    isReadOnly=[bool]$srcDisk.IsReadOnly
  }
  destination=[ordered]@{
    drive='F:'
    label=$dstVol.FileSystemLabel
    diskNumber=$dstDisk.Number
    friendlyName=$dstDisk.FriendlyName
    serialNumber=$dstDisk.SerialNumber
    busType=[string]$dstDisk.BusType
    size=[int64]$dstDisk.Size
    free=[int64]$dstVol.SizeRemaining
  }
  operations=@()
  sourceWrites=$false
  chkdskRun=$false
  repairRun=$false
  formatRun=$false
}
[IO.File]::WriteAllText((Join-Path $root 'manifest-precopy.json'),($manifest|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))

function Copy-PriorityPath {
  param([string]$Source,[string]$Name)
  $entry=[ordered]@{name=$Name;source=$Source;exists=$false;copied=$false;exitCode=$null;destination=$null}
  if(Test-Path -LiteralPath $Source){
    $entry.exists=$true
    $safeName=($Name -replace '[^A-Za-z0-9._-]','_')
    $dest=Join-Path $root $safeName
    $entry.destination=$dest
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    & robocopy.exe $Source $dest /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NP /NJH /NJS
    $code=$LASTEXITCODE
    $entry.exitCode=$code
    if($code -lt 8){$entry.copied=$true}else{throw "ROBOCOPY_FAILED $Name exit=$code"}
  }
  $script:manifest.operations += [pscustomobject]$entry
}

$priority=@(
  @{p='I:\Users\Faiz\.ssh'; n='01-SSH-Keys'},
  @{p='I:\AFZ'; n='02-AFZ-Root'},
  @{p='I:\ProgramData\AFZ'; n='03-ProgramData-AFZ'},
  @{p='I:\ProgramData\AFZRemoteOps'; n='04-ProgramData-AFZRemoteOps'},
  @{p='I:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Control Hub'; n='05-Control-Hub'},
  @{p='I:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'; n='06-ChatGPT-Termius'},
  @{p='I:\Users\Faiz\AppData\Local\Docker\wsl'; n='07-Docker-WSL'},
  @{p='I:\Users\Faiz\AppData\Local\Packages'; n='08-WSL-Packages'}
)

foreach($x in $priority){ Copy-PriorityPath -Source $x.p -Name $x.n }

# Capture focused source inventory without changing source.
$inventory=[ordered]@{
  users=@(Get-ChildItem 'I:\Users' -Force -ErrorAction SilentlyContinue | Select-Object Name,FullName,LastWriteTime)
  afzTop=if(Test-Path 'I:\AFZ'){@(Get-ChildItem 'I:\AFZ' -Force -ErrorAction SilentlyContinue | Select-Object Name,FullName,LastWriteTime,Mode)}else{@()}
  userFaizTop=if(Test-Path 'I:\Users\Faiz'){@(Get-ChildItem 'I:\Users\Faiz' -Force -ErrorAction SilentlyContinue | Select-Object Name,FullName,LastWriteTime,Mode)}else{@()}
}
[IO.File]::WriteAllText((Join-Path $root 'source-inventory.json'),($inventory|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))

$manifest.completedAt=(Get-Date -Format o)
[IO.File]::WriteAllText((Join-Path $root 'manifest-final.json'),($manifest|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))

Write-Output ('RECOVERY_ROOT='+$root)
Write-Output ('SOURCE_DISK='+$srcDisk.FriendlyName+' #'+$srcDisk.Number+' '+$srcDisk.Size)
Write-Output ('DEST_DISK='+$dstDisk.FriendlyName+' #'+$dstDisk.Number+' '+$dstDisk.Size)
foreach($op in $manifest.operations){
  Write-Output ("ITEM="+$op.name+" EXISTS="+$op.exists+" COPIED="+$op.copied+" EXIT="+$op.exitCode)
}
Write-Output 'SOURCE_WRITES=false'
Write-Output 'DONE'
