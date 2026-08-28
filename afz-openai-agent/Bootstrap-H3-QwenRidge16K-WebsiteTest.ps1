#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId
)

$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha required'}
if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid JobId'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()

$key='C:\Users\Faiz\.ssh\afz_h3_worker'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$h3='Faiz@100.106.186.118'
$launcherUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/Launch-H3-QwenRidge16K-WebsiteTest.ps1"
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwenridge16k-bootstrap'
$stateFile=Join-Path $stateRoot 'latest.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-State([string]$Status,[string]$Message,$Extra=$null){
  $o=[ordered]@{
    ok=($Status -eq 'completed')
    status=$Status
    message=$Message
    jobId=$JobId
    target='DESKTOP-H3R6CQN'
    transport='windows-main-ssh+github-exact-sha-detached-runner'
    expectedSha=$ExpectedSha
    updatedAt=(Get-Date -Format o)
  }
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  [IO.File]::WriteAllText($stateFile,($o|ConvertTo-Json -Depth 12 -Compress),$utf8)
}
function Invoke-NativeCapture {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string[]]$Arguments=@(),
    [int]$TimeoutSeconds=120
  )
  $tag=[guid]::NewGuid().ToString('N')
  $stdout=Join-Path $env:TEMP ($tag+'.stdout.txt')
  $stderr=Join-Path $env:TEMP ($tag+'.stderr.txt')
  try{
    $sp=@{FilePath=$FilePath;Wait=$false;PassThru=$true;NoNewWindow=$true;RedirectStandardOutput=$stdout;RedirectStandardError=$stderr}
    if($Arguments.Count -gt 0){$sp.ArgumentList=$Arguments}
    $p=Start-Process @sp
    if(-not $p.WaitForExit([math]::Max(1,$TimeoutSeconds)*1000)){
      try{$p.Kill()}catch{}
      throw "Process timeout after ${TimeoutSeconds}s: $FilePath"
    }
    $out=if(Test-Path -LiteralPath $stdout){Get-Content -LiteralPath $stdout -Raw}else{''}
    $err=if(Test-Path -LiteralPath $stderr){Get-Content -LiteralPath $stderr -Raw}else{''}
    [pscustomobject]@{ExitCode=[int]$p.ExitCode;StdOut=[string]$out;StdErr=[string]$err}
  }finally{Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue}
}

try{
  if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only bootstrap; host=$env:COMPUTERNAME"}
  if(-not(Test-Path -LiteralPath $key -PathType Leaf)){throw "H3 SSH key missing: $key"}
  if(-not(Test-Path -LiteralPath $known -PathType Leaf)){throw "H3 known-hosts file missing: $known"}
  $ssh=(Get-Command ssh.exe -ErrorAction Stop).Source
  Save-State 'running' 'Starting bounded exact-SHA H3 Ridge16K detached launcher over strict-host-key SSH.'

  $remote=@"
`$ErrorActionPreference='Stop'
if(`$env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: `$env:COMPUTERNAME"}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
`$uri='$launcherUrl'
`$tmp=Join-Path `$env:TEMP 'AFZ-H3-QwenRidge16K-Launch-$ExpectedSha.ps1'
try{
  Invoke-WebRequest -Uri `$uri -OutFile `$tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-QwenRidge16K-Bootstrap';'Cache-Control'='no-cache';'Pragma'='no-cache'} -TimeoutSec 60
  `$tokens=`$null;`$errors=`$null
  [void][System.Management.Automation.Language.Parser]::ParseFile(`$tmp,[ref]`$tokens,[ref]`$errors)
  if(`$errors.Count -gt 0){throw ('H3 Ridge16K launcher parse failure: '+(`$errors.Message -join '; '))}
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `$tmp -ExpectedSha '$ExpectedSha' -JobId '$JobId'
  exit `$LASTEXITCODE
}finally{Remove-Item -LiteralPath `$tmp -Force -ErrorAction SilentlyContinue}
"@
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
  if($encoded.Length -gt 7000){throw "Encoded H3 launcher unexpectedly large: $($encoded.Length) characters"}
  $args=@('-i',$key,'-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$h3,'powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',$encoded)
  $sshResult=Invoke-NativeCapture -FilePath $ssh -Arguments $args -TimeoutSeconds 120
  if($sshResult.ExitCode -ne 0){throw "H3 Ridge16K bootstrap SSH failed exit=$($sshResult.ExitCode) stderr=$($sshResult.StdErr) stdout=$($sshResult.StdOut)"}
  $line=@(($sshResult.StdOut -split '\r?\n')|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1)
  if(-not $line){throw "H3 Ridge16K bootstrap returned no JSON launch proof. stdout=$($sshResult.StdOut) stderr=$($sshResult.StdErr)"}
  $extra=$line|ConvertFrom-Json
  if(-not [bool]$extra.ok){throw 'H3 Ridge16K launcher returned ok=false'}
  Save-State 'completed' 'H3 Ridge16K exact-SHA runner launched and published running/completed state.' $extra
  Write-Output ('AFZ_QWENRIDGE16K_BOOTSTRAP_JSON='+((Get-Content $stateFile -Raw|ConvertFrom-Json)|ConvertTo-Json -Depth 12 -Compress))
}catch{
  $msg=$_.Exception.Message
  Save-State 'failed' $msg
  Write-Error $msg
  exit 1
}
