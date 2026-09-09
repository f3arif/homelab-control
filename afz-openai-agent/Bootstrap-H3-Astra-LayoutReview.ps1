#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [string]$ImageBase='http://100.70.25.8:3017',
  [string]$ResultPath='C:\AFZ\Temp\astra-layout-review-h3-final.json'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$actualHost=[Environment]::MachineName
if($actualHost -ne 'DESKTOP-10SKF0M'){throw "windows-main-only carrier; host=$actualHost"}
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha must be a 40-character Git commit SHA.'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()

$key='C:\Users\Faiz\.ssh\afz_h3_worker'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=(Get-Command ssh.exe -ErrorAction Stop).Source
$target='Faiz@100.106.186.118'
$utf8=New-Object Text.UTF8Encoding($false)
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required carrier path missing: $p"}}

function Capture([string]$File,[string[]]$ArgumentList,[int]$TimeoutSeconds=720){
  $tag=[guid]::NewGuid().ToString('N')
  $o=Join-Path $env:TEMP ($tag+'.out')
  $e=Join-Path $env:TEMP ($tag+'.err')
  try{
    $p=Start-Process -FilePath $File -ArgumentList $ArgumentList -PassThru -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e
    if(-not $p.WaitForExit($TimeoutSeconds*1000)){
      try{$p.Kill()}catch{}
      throw "H3 Astra layout review timed out after $TimeoutSeconds seconds."
    }
    return [pscustomobject]@{
      ExitCode=[int]$p.ExitCode
      StdOut=$(if(Test-Path $o){[IO.File]::ReadAllText($o)}else{''})
      StdErr=$(if(Test-Path $e){[IO.File]::ReadAllText($e)}else{''})
    }
  }finally{
    Remove-Item $o,$e -Force -ErrorAction SilentlyContinue
  }
}

$runnerUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/Run-H3-Astra-LayoutReview.py"
$remoteTemplate=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$actualHost=[Environment]::MachineName
if($actualHost -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: $actualHost"}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$runnerUrl='__RUNNER_URL__'
$imageBase='__IMAGE_BASE__'
$tmp=Join-Path $env:TEMP ('AFZ-H3-Astra-LayoutReview-'+[guid]::NewGuid().ToString('N')+'.py')
try{
  Invoke-WebRequest -Uri $runnerUrl -OutFile $tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-Astra-LayoutReview';'Cache-Control'='no-cache'} -TimeoutSec 60
  $pyCandidates=@(
    'C:\Users\Faiz\AppData\Local\hermes\hermes-agent\venv\Scripts\python.exe',
    'C:\Users\Faiz\AppData\Local\hermes\hermes-agent\.venv\Scripts\python.exe'
  )
  $py=$pyCandidates|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1
  if(-not $py){throw 'Hermes Python venv not found on H3.'}
  & $py $tmp --image-base $imageBase
  exit $LASTEXITCODE
}finally{
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
'@
$remote=$remoteTemplate.Replace('__RUNNER_URL__',$runnerUrl.Replace("'","''")).Replace('__IMAGE_BASE__',$ImageBase.Replace("'","''"))
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
$args=@(
  '-i',$key,
  '-o','IdentitiesOnly=yes',
  '-o','BatchMode=yes',
  '-o','ConnectTimeout=12',
  '-o','StrictHostKeyChecking=yes',
  '-o',('UserKnownHostsFile='+$known),
  $target,
  'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded
)

$r=Capture $ssh $args 720
$jsonLine=@(($r.StdOut -split '\r?\n')|Where-Object{$_ -match '^\{.*\}$'}|Select-Object -Last 1)
if($r.ExitCode -ne 0 -and -not $jsonLine){throw "H3 review failed exit=$($r.ExitCode) stderr=$($r.StdErr) stdout=$($r.StdOut)"}
if(-not $jsonLine){throw "H3 review returned no JSON. stderr=$($r.StdErr) stdout=$($r.StdOut)"}
$parsed=$jsonLine|ConvertFrom-Json -ErrorAction Stop
if(-not [bool]$parsed.ok){throw "H3 runner returned ok=false: $jsonLine"}
if([string]$parsed.host -ne 'DESKTOP-H3R6CQN'){throw "Unexpected result host: $($parsed.host)"}
if([string]$parsed.provider -ne 'openai-codex'){throw "Unexpected result provider: $($parsed.provider)"}
if([string]$parsed.model -ne 'gpt-6-astra'){throw "Unexpected result model: $($parsed.model)"}
if(-not [bool]$parsed.desktop.providerVerified -or -not [bool]$parsed.desktop.modelVerified){throw 'Desktop Astra route verification failed.'}
if(-not [bool]$parsed.mobile.providerVerified -or -not [bool]$parsed.mobile.modelVerified){throw 'Mobile Astra route verification failed.'}
$parent=Split-Path -Parent $ResultPath
if($parent -and -not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
[IO.File]::WriteAllText($ResultPath,$jsonLine,$utf8)
Write-Output $jsonLine
