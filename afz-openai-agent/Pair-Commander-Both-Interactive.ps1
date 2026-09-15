#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$PrivateResultRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Control Hub\Commander'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "Windows-main only orchestrator; host=$env:COMPUTERNAME"}
if($env:USERNAME -ne 'Faiz'){throw "Interactive Faiz profile required; user=$env:USERNAME"}
$pair=Join-Path $InstallRoot 'afz-openai-agent\Pair-Commander-Interactive.ps1'
if(-not(Test-Path -LiteralPath $pair -PathType Leaf)){throw "Pair helper missing: $pair"}
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $PrivateResultRoot|Out-Null

function Decode-Marker([object[]]$Lines){
  foreach($line in @($Lines)){
    $s=[string]$line
    if($s.StartsWith('AFZ_COMMANDER_PAIR_RESULT_B64=')){
      $raw=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s.Substring('AFZ_COMMANDER_PAIR_RESULT_B64='.Length)))
      return ($raw|ConvertFrom-Json)
    }
  }
  return $null
}

$wmOut=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pair -Target windows-main -PrivateResultRoot $PrivateResultRoot 2>&1)
$wmExit=$LASTEXITCODE
$wm=Decode-Marker $wmOut
if($wmExit -ne 0 -or -not $wm -or [string]$wm.status -ne 'AUTHORIZATION_REQUIRED'){
  throw "Windows-main Commander pairing failed exit=$wmExit"
}

$h3=$null
$h3Error=$null
try{
  $ssh=(Get-Command ssh.exe -ErrorAction Stop).Source
  $stdin=Join-Path $env:TEMP ('afz-h3-commander-pair-'+[guid]::NewGuid().ToString('N')+'.ps1')
  $stdout=Join-Path $env:TEMP ('afz-h3-commander-pair-'+[guid]::NewGuid().ToString('N')+'.out')
  $stderr=Join-Path $env:TEMP ('afz-h3-commander-pair-'+[guid]::NewGuid().ToString('N')+'.err')
  try{
    [IO.File]::WriteAllText($stdin,(Get-Content -LiteralPath $pair -Raw -Encoding UTF8),$utf8)
    $args=@('-o','BatchMode=yes','-o','ConnectTimeout=15','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2','Faiz@100.106.186.118','powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-Command','-')
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $stdin -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow -PassThru
    if(-not $p.WaitForExit(150000)){try{$p.Kill()}catch{};throw 'H3 Commander pairing SSH timed out'}
    $outLines=@();if(Test-Path $stdout){$outLines=@(Get-Content -LiteralPath $stdout)}
    $errText='';if(Test-Path $stderr){$errText=Get-Content -LiteralPath $stderr -Raw}
    if([int]$p.ExitCode -ne 0){throw "H3 SSH pairing failed exit=$($p.ExitCode): $errText"}
    $h3=Decode-Marker $outLines
    if(-not $h3 -or [string]$h3.status -ne 'AUTHORIZATION_REQUIRED'){throw 'H3 returned no usable Commander pairing result'}
    [IO.File]::WriteAllText((Join-Path $PrivateResultRoot 'PAIRING-H3-LATEST.json'),($h3|ConvertTo-Json -Depth 8),$utf8)
  }finally{
    Remove-Item -LiteralPath $stdin,$stdout,$stderr -Force -ErrorAction SilentlyContinue
  }
}catch{
  $h3Error=$_.Exception.Message
}

$summary=[ordered]@{
  schema=1
  status=$(if($h3){'AUTHORIZATION_REQUIRED_BOTH'}else{'AUTHORIZATION_REQUIRED_WINDOWSMAIN_H3_BLOCKED'})
  windowsMain=[ordered]@{ok=$true;result='PAIRING-WINDOWSMAIN-LATEST.json'}
  h3=[ordered]@{ok=[bool]$h3;result=$(if($h3){'PAIRING-H3-LATEST.json'}else{$null});error=$h3Error}
  privateResultRoot=$PrivateResultRoot
  generatedAt=(Get-Date -Format o)
}
[IO.File]::WriteAllText((Join-Path $PrivateResultRoot 'PAIRING-SUMMARY-LATEST.json'),($summary|ConvertTo-Json -Depth 10),$utf8)
Write-Output ('AFZ_COMMANDER_PAIR_ORCHESTRATOR='+($summary|ConvertTo-Json -Depth 10 -Compress))
if(-not $h3){exit 3}
