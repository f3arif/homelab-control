#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalSeconds=5
)

$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$IntervalSeconds=[math]::Max(3,[math]::Min($IntervalSeconds,30))

$requestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\familyptt-transport-audit.json'
$sourceState='C:\ProgramData\AFZ\OpenAIAgent\source-state.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\familyptt-transport-audit'
$stateFile=Join-Path $stateRoot 'latest.json'
$logFile=Join-Path $stateRoot 'watcher.log'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Log([string]$Message){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8}
function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path)){return $null};try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}}
function Save-State($Object){$Object|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $stateFile -Encoding UTF8}
function Get-SourceSha{$s=Read-Json $sourceState;if($s -and ([string]$s.remoteSha) -match '^[0-9a-fA-F]{40}$'){return ([string]$s.remoteSha).ToLowerInvariant()};return ''}
function Valid-HostName([string]$Value){return ($Value -match '^[A-Za-z0-9][A-Za-z0-9.-]{1,251}[A-Za-z0-9]$' -and $Value -notmatch '\.\.')}
function Valid-Request($r){
  if(-not $r){return $false}
  if([int]$r.schema -ne 1){return $false}
  if([string]$r.project -ne 'familyptt'){return $false}
  if([string]$r.action -ne 'audit-secure-transport'){return $false}
  if([int]$r.issue -lt 1){return $false}
  if(([string]$r.job_id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){return $false}
  if(([string]$r.backend_host) -notmatch '^100\.(?:\d{1,3}\.){2}\d{1,3}$'){return $false}
  if([int]$r.token_port -ne 7883 -or [int]$r.livekit_port -ne 7880){return $false}
  if(-not(Valid-HostName ([string]$r.api_hostname))){return $false}
  if(-not(Valid-HostName ([string]$r.livekit_hostname))){return $false}
  return $true
}
function Test-Tcp([string]$HostName,[int]$Port,[int]$TimeoutMs=3000){
  $client=New-Object Net.Sockets.TcpClient
  try{
    $iar=$client.BeginConnect($HostName,$Port,$null,$null)
    if(-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs,$false)){return $false}
    $client.EndConnect($iar);return $true
  }catch{return $false}finally{$client.Close()}
}
function Resolve-IPv4([string]$HostName){
  try{return @([Net.Dns]::GetHostAddresses($HostName)|Where-Object {$_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork}|ForEach-Object {$_.IPAddressToString}|Sort-Object -Unique)}catch{return @()}
}
function Test-Tls443([string]$HostName){
  $tcp=New-Object Net.Sockets.TcpClient
  try{
    $iar=$tcp.BeginConnect($HostName,443,$null,$null)
    if(-not $iar.AsyncWaitHandle.WaitOne(4000,$false)){return [ordered]@{tcp=$false;valid=$false;error='connect-timeout'}}
    $tcp.EndConnect($iar)
    $ssl=New-Object Net.Security.SslStream($tcp.GetStream(),$false)
    try{
      $ssl.AuthenticateAsClient($HostName)
      $cert=New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
      return [ordered]@{tcp=$true;valid=$true;subject=$cert.Subject;notAfter=$cert.NotAfter.ToUniversalTime().ToString('o')}
    }finally{$ssl.Dispose()}
  }catch{return [ordered]@{tcp=$true;valid=$false;error=$_.Exception.Message}}finally{$tcp.Close()}
}
function Invoke-HttpCode([string]$Uri,[int]$TimeoutSec=8){
  try{$r=Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec;return [int]$r.StatusCode}catch{try{return [int]$_.Exception.Response.StatusCode.value__}catch{return 0}}
}
function Publish-GitHubIssue([int]$Issue,[string]$Markdown){
  $gh=Get-Command gh.exe -ErrorAction SilentlyContinue
  if(-not $gh){return [ordered]@{ok=$false;method='gh';error='gh.exe unavailable'}}
  $payload=Join-Path $env:TEMP ('familyptt-audit-'+[guid]::NewGuid().ToString('n')+'.json')
  try{
    [ordered]@{body=$Markdown}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $payload -Encoding UTF8
    $raw=& $gh.Source api --method POST "repos/f3arif/homelab-control/issues/$Issue/comments" --input $payload 2>&1 | Out-String
    if($LASTEXITCODE -eq 0){return [ordered]@{ok=$true;method='gh-issue-comment'}}
    return [ordered]@{ok=$false;method='gh';error=($raw.Trim())}
  }catch{return [ordered]@{ok=$false;method='gh';error=$_.Exception.Message}}finally{Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue}
}
function Publish-GitBranch([string]$JobId,$ResultObject){
  $git=Get-Command git.exe -ErrorAction SilentlyContinue
  if(-not $git){return [ordered]@{ok=$false;method='git';error='git.exe unavailable'}}
  $tmp=Join-Path $env:TEMP ('familyptt-audit-publish-'+[guid]::NewGuid().ToString('n'))
  $repo=Join-Path $tmp 'repo'
  $branch=('afz-results/'+$JobId).ToLowerInvariant()
  try{
    New-Item -ItemType Directory -Force -Path $repo|Out-Null
    & $git.Source -C $repo init --quiet; if($LASTEXITCODE -ne 0){throw 'git init failed'}
    & $git.Source -C $repo remote add origin 'https://github.com/f3arif/homelab-control.git'; if($LASTEXITCODE -ne 0){throw 'git remote add failed'}
    & $git.Source -C $repo fetch --quiet --depth 1 origin main; if($LASTEXITCODE -ne 0){throw 'git fetch main failed'}
    & $git.Source -C $repo checkout --quiet -b $branch FETCH_HEAD; if($LASTEXITCODE -ne 0){throw 'git checkout result branch failed'}
    $dir=Join-Path $repo 'afz-openai-agent\results';New-Item -ItemType Directory -Force -Path $dir|Out-Null
    $out=Join-Path $dir ($JobId+'.json')
    $ResultObject|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $out -Encoding UTF8
    & $git.Source -C $repo config user.name 'AFZ Windows Worker'
    & $git.Source -C $repo config user.email '77086535+f3arif@users.noreply.github.com'
    & $git.Source -C $repo add -- 'afz-openai-agent/results'; if($LASTEXITCODE -ne 0){throw 'git add failed'}
    & $git.Source -C $repo commit --quiet -m "FamilyPTT transport audit $JobId"; if($LASTEXITCODE -ne 0){throw 'git commit failed'}
    & $git.Source -C $repo push --quiet origin "HEAD:refs/heads/$branch"; if($LASTEXITCODE -ne 0){throw 'git push result branch failed'}
    return [ordered]@{ok=$true;method='git-result-branch';branch=$branch;path=('afz-openai-agent/results/'+$JobId+'.json')}
  }catch{return [ordered]@{ok=$false;method='git';error=$_.Exception.Message}}finally{Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue}
}

function Handle-Request {
  if(-not(Test-Path -LiteralPath $requestFile)){return}
  $req=Read-Json $requestFile
  if(-not(Valid-Request $req)){throw "Invalid FamilyPTT typed request: $requestFile"}
  $jobId=[string]$req.job_id
  $prior=Read-Json $stateFile
  if($prior -and [string]$prior.jobId -eq $jobId -and [string]$prior.status -eq 'completed'){return}

  $sourceSha=Get-SourceSha
  if($sourceSha -notmatch '^[0-9a-f]{40}$'){throw 'Exact GitHub source SHA unavailable'}
  $hostName=[string]$req.backend_host
  $apiPort=[int]$req.token_port
  $lkPort=[int]$req.livekit_port
  $apiHost=[string]$req.api_hostname
  $lkHost=[string]$req.livekit_hostname
  $issue=[int]$req.issue

  Save-State ([ordered]@{ok=$true;status='running';jobId=$jobId;sourceSha=$sourceSha;startedAt=(Get-Date -Format o)})
  Log "AUDIT_START job=$jobId sha=$sourceSha"

  $apiTcp=Test-Tcp $hostName $apiPort
  $lkTcp=Test-Tcp $hostName $lkPort
  $healthCode=Invoke-HttpCode "http://$hostName`:$apiPort/health"
  $floorCode=Invoke-HttpCode "http://$hostName`:$apiPort/floor/status?room=family-main"

  $tokenCode=0;$tokenPresent=$false;$serverScheme='none';$serverHost='';$serverPort=0;$tokenRoom=''
  try{
    $uri="http://$hostName`:$apiPort/token?identity=afz-transport-audit-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())&name=AFZ%20Transport%20Audit&room=family-main"
    $tokenResponse=Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 10
    $tokenCode=[int]$tokenResponse.StatusCode
    $tokenData=$tokenResponse.Content|ConvertFrom-Json
    $tokenPresent=([string]$tokenData.participantToken).Length -gt 20
    $tokenRoom=[string]$tokenData.room
    $serverUrl=[string]$tokenData.serverUrl
    if($serverUrl){
      try{$u=[Uri]$serverUrl;$serverScheme=$u.Scheme.ToLowerInvariant();$serverHost=$u.Host;$serverPort=$u.Port}catch{$serverScheme='invalid'}
    }
    $tokenData=$null;$tokenResponse=$null;$serverUrl=$null
  }catch{try{$tokenCode=[int]$_.Exception.Response.StatusCode.value__}catch{$tokenCode=0}}

  $apiIps=Resolve-IPv4 $apiHost
  $lkIps=Resolve-IPv4 $lkHost
  $apiTls=Test-Tls443 $apiHost
  $lkTls=Test-Tls443 $lkHost
  $publicHealthCode=Invoke-HttpCode "https://$apiHost/health"

  $classification='PRIVATE_BACKEND_REVIEW_REQUIRED'
  if($apiTcp -and $lkTcp -and $tokenCode -eq 200 -and $tokenPresent){
    if($apiIps.Count -eq 0 -or $lkIps.Count -eq 0){$classification='PRIVATE_BACKEND_READY_EDGE_DNS_MISSING'}
    elseif(-not [bool]$apiTls.valid -or -not [bool]$lkTls.valid){$classification='PRIVATE_BACKEND_READY_TLS_EDGE_NOT_READY'}
    elseif($publicHealthCode -lt 200 -or $publicHealthCode -ge 400){$classification='TLS_EDGE_PRESENT_PUBLIC_API_NOT_READY'}
    elseif($serverScheme -ne 'wss'){$classification='TLS_API_READY_LIVEKIT_WSS_NOT_READY'}
    else{$classification='SECURE_TRANSPORT_READY'}
  }

  $finished=(Get-Date -Format o)
  $result=[ordered]@{
    schema=1;project='familyptt';action='audit-secure-transport';jobId=$jobId;sourceSha=$sourceSha
    startedAt=$(if($prior -and $prior.startedAt){[string]$prior.startedAt}else{$finished});finishedAt=$finished
    classification=$classification
    privateBackend=[ordered]@{apiTcp=$apiTcp;livekitTcp=$lkTcp;healthHttpCode=$healthCode;tokenHttpCode=$tokenCode;tokenPresent=$tokenPresent;tokenRoom=$tokenRoom;floorStatusHttpCode=$floorCode;returnedLiveKitScheme=$serverScheme;returnedLiveKitHost=$serverHost;returnedLiveKitPort=$serverPort}
    candidateEdge=[ordered]@{apiHostname=$apiHost;apiIpv4=@($apiIps);apiTlsValid=[bool]$apiTls.valid;apiTlsNotAfter=$apiTls.notAfter;livekitHostname=$lkHost;livekitIpv4=@($lkIps);livekitTlsValid=[bool]$lkTls.valid;livekitTlsNotAfter=$lkTls.notAfter;publicApiHealthHttpCode=$publicHealthCode}
    safety=[ordered]@{readOnly=$true;jwtLogged=$false;credentialsLogged=$false;backendMutation=$false;dnsMutation=$false;proxyMutation=$false;firewallMutation=$false}
  }

  $md=@"
## FamilyPTT transport audit — $jobId

Windows-main executed the typed audit after pulling exact GitHub source `$sourceSha`. This was read-only: no DNS, proxy, firewall, backend, LiveKit, or application settings were changed, and JWT contents were discarded in memory.

| Check | Result |
|---|---|
| Private API TCP | $apiTcp |
| Private LiveKit TCP | $lkTcp |
| Private API health HTTP | $healthCode |
| Token HTTP | $tokenCode |
| Token present (value not logged) | $tokenPresent |
| Floor status HTTP | $floorCode |
| Returned LiveKit scheme | $serverScheme |
| Candidate API DNS | $($apiIps -join ',') |
| Candidate API TLS valid | $([bool]$apiTls.valid) |
| Candidate LiveKit DNS | $($lkIps -join ',') |
| Candidate LiveKit TLS valid | $([bool]$lkTls.valid) |
| Public API health HTTPS | $publicHealthCode |

**Classification:** `$classification`
"@

  $publish=Publish-GitHubIssue $issue $md
  if(-not $publish.ok){$publish=Publish-GitBranch $jobId $result}
  $result['publish']=$publish
  $result['status']='completed'
  $result['ok']=$true
  Save-State $result
  Log "AUDIT_DONE job=$jobId classification=$classification publish=$($publish.method) publishOk=$($publish.ok)"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZFamilyPTTTransportAuditWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s"
  while($true){
    try{Handle-Request}catch{
      $msg=$_.Exception.Message;Log "ERROR $msg"
      $req=Read-Json $requestFile
      Save-State ([ordered]@{ok=$false;status='error';jobId=$(if($req){[string]$req.job_id}else{''});error=$msg;updatedAt=(Get-Date -Format o)})
    }
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{if($locked){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
