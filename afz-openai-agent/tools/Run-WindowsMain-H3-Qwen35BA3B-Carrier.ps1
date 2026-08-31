#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$JobId
)

$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only carrier; host=$env:COMPUTERNAME"}
if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha required'}
if($JobId -ne 'qwen35b-a3b-website-20260830-r1'){throw "Unexpected 35B benchmark JobId: $JobId"}
$ExpectedSha=$ExpectedSha.ToLowerInvariant()

$key='C:\Users\Faiz\.ssh\afz_h3_worker'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$h3='Faiz@100.106.186.118'
$h3Ip='100.106.186.118'
$h3Mac='4C-ED-FB-3F-B0-9E'
$broadcast='192.168.50.255'
$launcherUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/Launch-H3-Qwen35BA3B-WebsiteTest.ps1"
$resultRoot='C:\Users\Faiz\AppData\Local\AFZ\H3Qwen35BA3BCarrier'
$resultFile=Join-Path $resultRoot ($JobId+'.json')
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $resultRoot|Out-Null

function Save-Result([bool]$Ok,[string]$Status,[string]$Message,$Extra=$null){
  $o=[ordered]@{ok=$Ok;status=$Status;message=$Message;jobId=$JobId;expectedSha=$ExpectedSha;host=$env:COMPUTERNAME;target='DESKTOP-H3R6CQN';transport='interactive-carrier+wake+strict-ssh-stdin+github-exact-sha';updatedAt=(Get-Date -Format o)}
  if($Extra){foreach($p in $Extra.PSObject.Properties){$o[$p.Name]=$p.Value}}
  [IO.File]::WriteAllText($resultFile,($o|ConvertTo-Json -Depth 20 -Compress),$utf8)
}
function Send-H3Wake {
  $bytes=$h3Mac -split '[:-]'|ForEach-Object {[Convert]::ToByte($_,16)}
  $packet=New-Object byte[] 102
  0..5|ForEach-Object {$packet[$_]=0xFF}
  for($i=1;$i -le 16;$i++){[Array]::Copy($bytes,0,$packet,6+(($i-1)*6),6)}
  $client=New-Object Net.Sockets.UdpClient
  try{
    $client.EnableBroadcast=$true
    foreach($round in 1..5){
      foreach($port in @(9,7)){
        $ep=New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($broadcast)),$port
        [void]$client.Send($packet,$packet.Length,$ep)
      }
      Start-Sleep -Milliseconds 400
    }
  }finally{$client.Dispose()}
}
function Test-Tcp([string]$HostName,[int]$Port,[int]$TimeoutMs=1200){
  $c=New-Object Net.Sockets.TcpClient
  try{
    $ar=$c.BeginConnect($HostName,$Port,$null,$null)
    if(-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs,$false)){return $false}
    $c.EndConnect($ar);return $true
  }catch{return $false}finally{try{$c.Close()}catch{}}
}

try{
  if(-not(Test-Path -LiteralPath $key -PathType Leaf)){throw "H3 SSH key missing: $key"}
  if(-not(Test-Path -LiteralPath $known -PathType Leaf)){throw "H3 known-hosts file missing: $known"}
  $ssh=(Get-Command ssh.exe -ErrorAction Stop).Source
  Save-Result $false 'running' '35B carrier started; waking H3 and waiting for Tailscale SSH.'

  if(-not(Test-Tcp $h3Ip 22 1200)){Send-H3Wake}
  $online=$false
  for($i=1;$i -le 90;$i++){
    if(Test-Tcp $h3Ip 22 1200){$online=$true;break}
    if($i -in @(30,60)){try{Send-H3Wake}catch{}}
    Start-Sleep -Seconds 2
  }
  if(-not $online){throw 'H3 Tailscale SSH did not become reachable within the bounded Wake-on-LAN window.'}

  $remote=@"
`$ErrorActionPreference='Stop'
if(`$env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: `$env:COMPUTERNAME"}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
`$uri='$launcherUrl'
`$tmp=Join-Path `$env:TEMP 'AFZ-H3-Qwen35BA3B-Launch-$ExpectedSha.ps1'
try {
  Invoke-WebRequest -Uri `$uri -OutFile `$tmp -UseBasicParsing -Headers @{'User-Agent'='AFZ-H3-Qwen35BA3B-Carrier';'Cache-Control'='no-cache';'Pragma'='no-cache'} -TimeoutSec 60
  `$tokens=`$null;`$errors=`$null
  [void][System.Management.Automation.Language.Parser]::ParseFile(`$tmp,[ref]`$tokens,[ref]`$errors)
  if(`$errors.Count -gt 0){throw ('35B launcher parse failure: '+(`$errors.Message -join '; '))}
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `$tmp -ExpectedSha '$ExpectedSha' -JobId '$JobId'
  exit `$LASTEXITCODE
} finally {
  Remove-Item -LiteralPath `$tmp -Force -ErrorAction SilentlyContinue
}
"@

  $sshArgs=@('-i',$key,'-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$h3,'powershell.exe','-NoProfile','-NonInteractive','-Command','-')
  $all=@($remote | & $ssh @sshArgs 2>&1)
  $code=$LASTEXITCODE
  $raw=($all|Out-String).Trim()
  if($code -ne 0){throw "H3 35B SSH/launcher failed exit=$code output=$raw"}
  $line=@(($all|ForEach-Object {[string]$_})|Where-Object {$_.Trim() -match '^\{.*\}$'}|Select-Object -Last 1)
  if(-not $line){throw "H3 35B launcher returned no JSON proof. output=$raw"}
  $extra=([string]$line).Trim()|ConvertFrom-Json
  if(-not [bool]$extra.ok){throw ('H3 35B launcher returned ok=false: '+[string]$extra.message)}
  Save-Result $true 'completed' 'H3 35B guarded runner state proved through strict SSH stdin transport.' $extra
  Write-Output ((Get-Content $resultFile -Raw|ConvertFrom-Json)|ConvertTo-Json -Depth 20 -Compress)
}catch{
  $msg=$_.Exception.Message
  Save-Result $false 'failed' $msg
  Write-Error $msg
  exit 1
}
