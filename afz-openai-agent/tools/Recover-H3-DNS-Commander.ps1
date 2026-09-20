#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){
  throw "WRONG_HOST expected=DESKTOP-H3R6CQN actual=$env:COMPUTERNAME"
}

$root=Join-Path $env:LOCALAPPDATA 'AFZ\DesktopCommander'
New-Item -ItemType Directory -Force -Path $root|Out-Null
$state=Join-Path $root 'H3-DNS-COMMANDER-RECOVERY-LATEST.json'
$log=Join-Path $root 'h3-dns-commander-recovery.log'
$hostsPath=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$backup=Join-Path $root ('hosts.before-h3-dns-recovery-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.txt')
Copy-Item -LiteralPath $hostsPath -Destination $backup -Force

function Resolve-DoH([string]$Name){
  $urls=@(
    "https://1.1.1.1/dns-query?name=$Name&type=A",
    "https://1.0.0.1/dns-query?name=$Name&type=A"
  )
  foreach($u in $urls){
    try{
      $raw=& curl.exe --silent --show-error --connect-timeout 8 --max-time 15 -H "accept: application/dns-json" $u
      if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$raw)){continue}
      $j=$raw|ConvertFrom-Json
      $a=@($j.Answer|Where-Object { [int]$_.type -eq 1 -and [string]$_.data -match '^\d{1,3}(\.\d{1,3}){3}$' }|Select-Object -ExpandProperty data)
      if($a.Count -gt 0){return [string]$a[0]}
    }catch{}
  }

  foreach($ip in @('104.16.248.249','104.16.249.249')){
    try{
      $raw=& curl.exe --silent --show-error --connect-timeout 8 --max-time 15 --resolve "cloudflare-dns.com:443:$ip" -H "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=$Name&type=A"
      if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$raw)){continue}
      $j=$raw|ConvertFrom-Json
      $a=@($j.Answer|Where-Object { [int]$_.type -eq 1 -and [string]$_.data -match '^\d{1,3}(\.\d{1,3}){3}$' }|Select-Object -ExpandProperty data)
      if($a.Count -gt 0){return [string]$a[0]}
    }catch{}
  }
  return $null
}

$mcpIp=Resolve-DoH 'mcp.desktopcommander.app'
$rawIp=Resolve-DoH 'raw.githubusercontent.com'
if(-not $mcpIp){throw 'DOH_RESOLUTION_FAILED mcp.desktopcommander.app'}

$marker='# AFZ_TEMP_DNS_FAILOVER_20260920'
$lines=@(Get-Content -LiteralPath $hostsPath -ErrorAction Stop|Where-Object {$_ -notmatch [regex]::Escape($marker)})
$lines += "$mcpIp mcp.desktopcommander.app $marker"
if($rawIp){$lines += "$rawIp raw.githubusercontent.com $marker"}
[IO.File]::WriteAllLines($hostsPath,$lines,(New-Object Text.UTF8Encoding($false)))
Clear-DnsClientCache

$node=(Get-Command node.exe -ErrorAction Stop).Source
$dc=Join-Path $env:APPDATA 'npm\node_modules\@wonderwhy-er\desktop-commander\dist\index.js'
if(-not(Test-Path -LiteralPath $dc -PathType Leaf)){throw "DESKTOP_COMMANDER_MISSING $dc"}

foreach($task in @('AFZ H3 Desktop Commander Remote','AFZ Desktop Commander Remote MCP Boot','AFZ Desktop Commander Remote Pairing')){
  try{Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue}catch{}
}
try{
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|
    Where-Object {$_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match '(?i)desktop-commander.*\bremote\b'}|
    ForEach-Object {Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
}catch{}
Start-Sleep -Seconds 2
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue

$cmd='"'+$node+'" "'+$dc+'" remote >> "'+$log+'" 2>&1'
Start-Process -FilePath $env:ComSpec -ArgumentList '/d','/s','/c',$cmd -WindowStyle Hidden|Out-Null
Start-Sleep -Seconds 10

$tail=''
if(Test-Path -LiteralPath $log){$tail=(Get-Content -LiteralPath $log -Tail 80 -ErrorAction SilentlyContinue)-join [Environment]::NewLine}
$classification=if($tail -match '(?i)Connected to Remote MCP'){'REMOTE_CONNECTED'}elseif($tail -match '(?i)Please complete authentication|device authorization'){'AUTHORIZATION_REQUIRED'}elseif($tail -match '(?i)fetch failed'){'REMOTE_FETCH_FAILED'}else{'REMOTE_START_PENDING'}
$code=$null
if($tail -match '\b([A-Z0-9]{4}-[A-Z0-9]{4})\b'){$code=$Matches[1]}

$result=[ordered]@{
  schema=1
  host=$env:COMPUTERNAME
  classification=$classification
  mcpIp=$mcpIp
  rawGithubIp=$rawIp
  hostsBackup=$backup
  pairingCode=$code
  verifyUrl=$(if($code){'https://mcp.desktopcommander.app/device/verify'}else{$null})
  ssdTouched=$false
  updatedAt=(Get-Date -Format o)
}
[IO.File]::WriteAllText($state,($result|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
$result|ConvertTo-Json -Depth 6
