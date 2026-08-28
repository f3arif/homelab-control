#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId
)

$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only carrier helper; host=$env:COMPUTERNAME"}
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha required'}
if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid JobId'}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()

$key='C:\Users\Faiz\.ssh\afz_h3_worker'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$h3='Faiz@100.106.186.118'
$h3Lan='192.168.50.213'
$h3Mac='4C-ED-FB-3F-B0-9E'
$broadcast='192.168.50.255'
$launcherUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/Launch-H3-QwenRidge16K-WebsiteTest.ps1"
$resultRoot='C:\Users\Faiz\AppData\Local\AFZ\H3QwenRidge16KCarrier'
$resultFile=Join-Path $resultRoot ($JobId+'.json')
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $resultRoot|Out-Null

function Save-Result([bool]$Ok,[string]$Status,[string]$Message,$Extra=$null){
  $o=[ordered]@{ok=$Ok;status=$Status;message=$Message;jobId=$JobId;expectedSha=$ExpectedSha;host=$env:COMPUTERNAME;target='DESKTOP-H3R6CQN';transport='interactive-carrier+wake+strict-ssh+github-exact-sha';updatedAt=(Get-Date -Format o)}
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  [IO.File]::WriteAllText($resultFile,($o|ConvertTo-Json -Depth 12 -Compress),$utf8)
}
function Send-H3Wake {
  try{
    $bytes=$h3Mac -split '[:-]'|ForEach-Object {[Convert]::ToByte($_,16)}
    $packet=New-Object byte[] 102
    0..5|ForEach-Object {$packet[$_]=0xFF}
    for($i=1;$i -le 16;$i++){[Array]::Copy($bytes,0,$packet,6+(($i-1)*6),6)}
    $client=New-Object Net.Sockets.UdpClient
    try{
      $client.EnableBroadcast=$true
      foreach($round in 1..5){foreach($port in @(9,7)){$ep=New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($broadcast)),$port;[void]$client.Send($packet,$packet.Length,$ep)};Start-Sleep -Milliseconds 400}
    }finally{$client.Dispose()}
  }catch{}
}
function Invoke-NativeCapture {
  param([Parameter(Mandatory=$true)][string]$FilePath,[string[]]$Arguments=@(),[int]$TimeoutSeconds=120)
  $tag=[guid]::NewGuid().ToString('N');$outFile=Join-Path $env:TEMP ($tag+'.out');$errFile=Join-Path $env:TEMP ($tag+'.err')
  try{
    $sp=@{FilePath=$FilePath;PassThru=$true;NoNewWindow=$true;RedirectStandardOutput=$outFile;RedirectStandardError=$errFile};if($Arguments.Count){$sp.ArgumentList=$Arguments}
    $p=Start-Process @sp
    if(-not $p.WaitForExit([math]::Max(1,$TimeoutSeconds)*1000)){try{$p.Kill()}catch{};throw "Process timeout after ${TimeoutSeconds}s: $FilePath"}
    $out=if(Test-Path $outFile){Get-Content $outFile -Raw}else{''};$err=if(Test-Path $errFile){Get-Content $errFile -Raw}else{''}
    return [pscustomobject]@{ExitCode=[int]$p.ExitCode;StdOut=[string]$out;StdErr=[string]$err}
  }finally{Remove-Item $outFile,$errFile -Force -ErrorAction SilentlyContinue}
}

try{
  if(-not(Test-Path -LiteralPath $key -PathType Leaf)){throw "H3 SSH key missing: $key"}
  if(-not(Test-Path -LiteralPath $known -PathType Leaf)){throw "H3 known-hosts file missing: $known"}
  $ssh=(Get-Command ssh.exe -ErrorAction Stop).Source
  Save-Result $false 'running' 'Interactive carrier started; waking H3 if needed before strict SSH.'
  Send-H3Wake

  $online=$false
  foreach($i in 1..24){
    if(Test-Connection -ComputerName $h3Lan -Count 1 -Quiet -ErrorAction SilentlyContinue){$online=$true;break}
    if(Test-Connection -ComputerName '100.106.186.118' -Count 1 -Quiet -ErrorAction SilentlyContinue){$online=$true;break}
    Start-Sleep -Seconds 3
  }
  if(-not $online){throw 'H3 did not become reachable after Wake-on-LAN wait.'}

  $remote=@"
`$ErrorActionPreference='Stop'
if(`$env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: `$env:COMPUTERNAME"}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
`$uri='$launcherUrl'
`$tmp=Join-Path `$env:TEMP 'AFZ-H3-QwenRidge16K-Launch-$ExpectedSha.ps1'
try{
  Invoke-WebRequest -Uri `$uri -OutFile `$tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-QwenRidge16K-Carrier';'Cache-Control'='no-cache';'Pragma'='no-cache'} -TimeoutSec 60
  `$tokens=`$null;`$errors=`$null
  [void][System.Management.Automation.Language.Parser]::ParseFile(`$tmp,[ref]`$tokens,[ref]`$errors)
  if(`$errors.Count -gt 0){throw ('H3 Ridge16K launcher parse failure: '+(`$errors.Message -join '; '))}
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `$tmp -ExpectedSha '$ExpectedSha' -JobId '$JobId'
  exit `$LASTEXITCODE
}finally{Remove-Item -LiteralPath `$tmp -Force -ErrorAction SilentlyContinue}
"@
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
  $args=@('-i',$key,'-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$h3,'powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',$encoded)
  $r=Invoke-NativeCapture -FilePath $ssh -Arguments $args -TimeoutSeconds 120
  if($r.ExitCode -ne 0){throw "H3 carrier SSH failed exit=$($r.ExitCode) stderr=$($r.StdErr) stdout=$($r.StdOut)"}
  $line=@(($r.StdOut -split '\r?\n')|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1)
  if(-not $line){throw "H3 carrier returned no JSON launch proof. stdout=$($r.StdOut) stderr=$($r.StdErr)"}
  $extra=$line|ConvertFrom-Json
  if(-not [bool]$extra.ok){throw 'H3 detached launcher returned ok=false'}
  Save-Result $true 'completed' 'H3 Ridge16K detached runner launch proved under interactive credential carrier.' $extra
  Write-Output ((Get-Content $resultFile -Raw|ConvertFrom-Json)|ConvertTo-Json -Depth 12 -Compress)
}catch{
  $msg=$_.Exception.Message
  Save-Result $false 'failed' $msg
  Write-Error $msg
  exit 1
}
