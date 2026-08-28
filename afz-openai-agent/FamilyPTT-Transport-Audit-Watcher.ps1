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
$familyPttRepo='C:\Projects\FamilyPTT'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Log([string]$Message){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8}
function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path)){return $null};try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}}
function Save-State($Object){$Object|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $stateFile -Encoding UTF8}
function Get-SourceSha{$s=Read-Json $sourceState;if($s -and ([string]$s.remoteSha) -match '^[0-9a-fA-F]{40}$'){return ([string]$s.remoteSha).ToLowerInvariant()};return ''}
function Sanitize([string]$Text){
  if([string]::IsNullOrWhiteSpace($Text)){return ''}
  $v=$Text
  $v=[regex]::Replace($v,'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}','[REDACTED_JWT]')
  $v=[regex]::Replace($v,'(?i)(authorization:\s*bearer\s+)\S+','$1[REDACTED]')
  $v=[regex]::Replace($v,'(?i)(https?://)[^/@\s]+@','$1[REDACTED]@')
  if($v.Length -gt 1500){$v=$v.Substring(0,1500)}
  return $v
}
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
  try{$iar=$client.BeginConnect($HostName,$Port,$null,$null);if(-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs,$false)){return $false};$client.EndConnect($iar);return $true}catch{return $false}finally{$client.Close()}
}
function Resolve-IPv4([string]$HostName){try{return @([Net.Dns]::GetHostAddresses($HostName)|Where-Object {$_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork}|ForEach-Object {$_.IPAddressToString}|Sort-Object -Unique)}catch{return @()}}
function Test-Tls443([string]$HostName){
  $tcp=New-Object Net.Sockets.TcpClient
  try{
    $iar=$tcp.BeginConnect($HostName,443,$null,$null)
    if(-not $iar.AsyncWaitHandle.WaitOne(4000,$false)){return [ordered]@{tcp=$false;valid=$false;error='connect-timeout'}}
    $tcp.EndConnect($iar)
    $ssl=New-Object Net.Security.SslStream($tcp.GetStream(),$false)
    try{$ssl.AuthenticateAsClient($HostName);$cert=New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate);return [ordered]@{tcp=$true;valid=$true;subject=$cert.Subject;notAfter=$cert.NotAfter.ToUniversalTime().ToString('o')}}finally{$ssl.Dispose()}
  }catch{return [ordered]@{tcp=$true;valid=$false;error=(Sanitize $_.Exception.Message)}}finally{$tcp.Close()}
}
function Invoke-HttpCode([string]$Uri,[int]$TimeoutSec=8){try{$r=Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec;return [int]$r.StatusCode}catch{try{return [int]$_.Exception.Response.StatusCode.value__}catch{return 0}}}

function Publish-GitHubIssue([int]$Issue,[string]$Markdown){
  $gh=Get-Command gh.exe -ErrorAction SilentlyContinue
  if(-not $gh){return [ordered]@{ok=$false;method='gh-issue-comment';error='gh.exe unavailable'}}
  $payload=Join-Path $env:TEMP ('familyptt-audit-'+[guid]::NewGuid().ToString('n')+'.json')
  try{
    [ordered]@{body=$Markdown}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $payload -Encoding UTF8
    $raw=& $gh.Source api --method POST "repos/f3arif/homelab-control/issues/$Issue/comments" --input $payload 2>&1 | Out-String
    if($LASTEXITCODE -eq 0){return [ordered]@{ok=$true;method='gh-issue-comment'}}
    return [ordered]@{ok=$false;method='gh-issue-comment';error=(Sanitize $raw.Trim())}
  }catch{return [ordered]@{ok=$false;method='gh-issue-comment';error=(Sanitize $_.Exception.Message)}}finally{Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue}
}

function Get-FamilyPttRemoteUrl([string]$GitExe){
  if(-not(Test-Path -LiteralPath (Join-Path $familyPttRepo '.git'))){throw 'FamilyPTT local Git repository unavailable'}
  foreach($remote in @('github','origin')){
    $url=(& $GitExe -C $familyPttRepo remote get-url $remote 2>$null | Select-Object -First 1)
    if($LASTEXITCODE -eq 0 -and $url){
      $url=[string]$url
      if($url -match '(?i)github\.com[:/]f3arif/FamilyPTT(?:\.git)?$'){return $url}
    }
  }
  throw 'Expected FamilyPTT GitHub remote unavailable'
}

function Publish-FamilyPttResultBranch([string]$JobId,$ResultObject){
  $git=Get-Command git.exe -ErrorAction SilentlyContinue
  if(-not $git){return [ordered]@{ok=$false;method='familyptt-result-branch';error='git.exe unavailable'}}
  $tmp=Join-Path $env:TEMP ('familyptt-audit-publish-'+[guid]::NewGuid().ToString('n'))
  $repo=Join-Path $tmp 'repo'
  $branch=('afz-results/'+$JobId).ToLowerInvariant()
  try{
    $remoteUrl=Get-FamilyPttRemoteUrl $git.Source
    New-Item -ItemType Directory -Force -Path $repo|Out-Null
    & $git.Source -C $repo init --quiet; if($LASTEXITCODE -ne 0){throw 'git init failed'}
    & $git.Source -C $repo remote add origin $remoteUrl; if($LASTEXITCODE -ne 0){throw 'git remote add failed'}
    & $git.Source -C $repo fetch --quiet --depth 1 origin main; if($LASTEXITCODE -ne 0){throw 'FamilyPTT authenticated fetch failed'}
    & $git.Source -C $repo checkout --quiet -b $branch FETCH_HEAD; if($LASTEXITCODE -ne 0){throw 'git checkout result branch failed'}
    $dir=Join-Path $repo 'ops-results';New-Item -ItemType Directory -Force -Path $dir|Out-Null
    $out=Join-Path $dir ($JobId+'.json')
    $ResultObject|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $out -Encoding UTF8
    & $git.Source -C $repo config user.name 'AFZ Windows Worker'
    & $git.Source -C $repo config user.email '77086535+f3arif@users.noreply.github.com'
    & $git.Source -C $repo add -- 'ops-results'; if($LASTEXITCODE -ne 0){throw 'git add failed'}
    & $git.Source -C $repo commit --quiet -m "FamilyPTT transport audit $JobId"; if($LASTEXITCODE -ne 0){throw 'git commit failed'}
    & $git.Source -C $repo push --quiet origin "HEAD:refs/heads/$branch"; if($LASTEXITCODE -ne 0){throw 'FamilyPTT result push failed'}
    return [ordered]@{ok=$true;method='familyptt-result-branch';branch=$branch;path=('ops-results/'+$JobId+'.json')}
  }catch{return [ordered]@{ok=$false;method='familyptt-result-branch';error=(Sanitize $_.Exception.Message)}}finally{Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue}
}

function Format-Markdown($Result){
  if([string]$Result.classification -eq 'WATCHER_RUNTIME_ERROR'){
    return "## FamilyPTT transport audit — $($Result.jobId)`n`nWindows-main watcher reached a sanitized runtime error before completing the read-only audit.`n`n**Classification:** `WATCHER_RUNTIME_ERROR``n`n**Error:** $($Result.error)"
  }
  $p=$Result.privateBackend;$e=$Result.candidateEdge
  return @"
## FamilyPTT transport audit — $($Result.jobId)

Windows-main executed the typed audit after pulling exact GitHub source `$($Result.sourceSha)`. This was read-only: no DNS, proxy, firewall, backend, LiveKit, or application settings were changed, and JWT contents were discarded in memory.

| Check | Result |
|---|---|
| Private API TCP | $($p.apiTcp) |
| Private LiveKit TCP | $($p.livekitTcp) |
| Private API health HTTP | $($p.healthHttpCode) |
| Token HTTP | $($p.tokenHttpCode) |
| Token present (value not logged) | $($p.tokenPresent) |
| Floor status HTTP | $($p.floorStatusHttpCode) |
| Returned LiveKit scheme | $($p.returnedLiveKitScheme) |
| Candidate API DNS | $(@($e.apiIpv4) -join ',') |
| Candidate API TLS valid | $($e.apiTlsValid) |
| Candidate LiveKit DNS | $(@($e.livekitIpv4) -join ',') |
| Candidate LiveKit TLS valid | $($e.livekitTlsValid) |
| Public API health HTTPS | $($e.publicApiHealthHttpCode) |

**Classification:** `$($Result.classification)`
"@
}

function Publish-Durable([int]$Issue,[string]$JobId,$Result){
  $markdown=Format-Markdown $Result
  $a=Publish-GitHubIssue $Issue $markdown
  if($a.ok){return $a}
  $b=Publish-FamilyPttResultBranch $JobId $Result
  if($b.ok){return $b}
  return [ordered]@{ok=$false;method='none';issueError=(Sanitize ([string]$a.error));branchError=(Sanitize ([string]$b.error))}
}

function New-AuditResult($req,[string]$SourceSha){
  $jobId=[string]$req.job_id;$hostName=[string]$req.backend_host;$apiPort=[int]$req.token_port;$lkPort=[int]$req.livekit_port;$apiHost=[string]$req.api_hostname;$lkHost=[string]$req.livekit_hostname
  $started=(Get-Date -Format o)
  $apiTcp=Test-Tcp $hostName $apiPort;$lkTcp=Test-Tcp $hostName $lkPort
  $healthCode=Invoke-HttpCode "http://$hostName`:$apiPort/health";$floorCode=Invoke-HttpCode "http://$hostName`:$apiPort/floor/status?room=family-main"
  $tokenCode=0;$tokenPresent=$false;$serverScheme='none';$serverHost='';$serverPort=0;$tokenRoom=''
  try{
    $uri="http://$hostName`:$apiPort/token?identity=afz-transport-audit-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())&name=AFZ%20Transport%20Audit&room=family-main"
    $tokenResponse=Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 10;$tokenCode=[int]$tokenResponse.StatusCode;$tokenData=$tokenResponse.Content|ConvertFrom-Json
    $tokenPresent=([string]$tokenData.participantToken).Length -gt 20;$tokenRoom=[string]$tokenData.room;$serverUrl=[string]$tokenData.serverUrl
    if($serverUrl){try{$u=[Uri]$serverUrl;$serverScheme=$u.Scheme.ToLowerInvariant();$serverHost=$u.Host;$serverPort=$u.Port}catch{$serverScheme='invalid'}}
    $tokenData=$null;$tokenResponse=$null;$serverUrl=$null
  }catch{try{$tokenCode=[int]$_.Exception.Response.StatusCode.value__}catch{$tokenCode=0}}
  $apiIps=Resolve-IPv4 $apiHost;$lkIps=Resolve-IPv4 $lkHost;$apiTls=Test-Tls443 $apiHost;$lkTls=Test-Tls443 $lkHost;$publicHealthCode=Invoke-HttpCode "https://$apiHost/health"
  $classification='PRIVATE_BACKEND_REVIEW_REQUIRED'
  if($apiTcp -and $lkTcp -and $tokenCode -eq 200 -and $tokenPresent){
    if($apiIps.Count -eq 0 -or $lkIps.Count -eq 0){$classification='PRIVATE_BACKEND_READY_EDGE_DNS_MISSING'}
    elseif(-not [bool]$apiTls.valid -or -not [bool]$lkTls.valid){$classification='PRIVATE_BACKEND_READY_TLS_EDGE_NOT_READY'}
    elseif($publicHealthCode -lt 200 -or $publicHealthCode -ge 400){$classification='TLS_EDGE_PRESENT_PUBLIC_API_NOT_READY'}
    elseif($serverScheme -ne 'wss'){$classification='TLS_API_READY_LIVEKIT_WSS_NOT_READY'}
    else{$classification='SECURE_TRANSPORT_READY'}
  }
  return [ordered]@{
    schema=1;project='familyptt';action='audit-secure-transport';jobId=$jobId;sourceSha=$SourceSha;startedAt=$started;finishedAt=(Get-Date -Format o);classification=$classification
    privateBackend=[ordered]@{apiTcp=$apiTcp;livekitTcp=$lkTcp;healthHttpCode=$healthCode;tokenHttpCode=$tokenCode;tokenPresent=$tokenPresent;tokenRoom=$tokenRoom;floorStatusHttpCode=$floorCode;returnedLiveKitScheme=$serverScheme;returnedLiveKitHost=$serverHost;returnedLiveKitPort=$serverPort}
    candidateEdge=[ordered]@{apiHostname=$apiHost;apiIpv4=@($apiIps);apiTlsValid=[bool]$apiTls.valid;apiTlsNotAfter=$apiTls.notAfter;livekitHostname=$lkHost;livekitIpv4=@($lkIps);livekitTlsValid=[bool]$lkTls.valid;livekitTlsNotAfter=$lkTls.notAfter;publicApiHealthHttpCode=$publicHealthCode}
    safety=[ordered]@{readOnly=$true;jwtLogged=$false;credentialsLogged=$false;backendMutation=$false;dnsMutation=$false;proxyMutation=$false;firewallMutation=$false}
  }
}

function Handle-Request {
  if(-not(Test-Path -LiteralPath $requestFile)){return}
  $req=Read-Json $requestFile;if(-not(Valid-Request $req)){throw "Invalid FamilyPTT typed request: $requestFile"}
  $jobId=[string]$req.job_id;$issue=[int]$req.issue;$prior=Read-Json $stateFile
  if($prior -and [string]$prior.jobId -eq $jobId -and [string]$prior.status -eq 'completed'){return}
  if($prior -and [string]$prior.jobId -eq $jobId -and [string]$prior.status -in @('awaiting-publication','error-awaiting-publication') -and $prior.result){
    $publish=Publish-Durable $issue $jobId $prior.result
    if($publish.ok){$prior.status='completed';$prior.publish=$publish;$prior.updatedAt=(Get-Date -Format o);Save-State $prior;Log "PUBLISH_RETRY_OK job=$jobId method=$($publish.method)"}
    else{$prior.publish=$publish;$prior.updatedAt=(Get-Date -Format o);Save-State $prior}
    return
  }
  $sourceSha=Get-SourceSha;if($sourceSha -notmatch '^[0-9a-f]{40}$'){throw 'Exact GitHub source SHA unavailable'}
  Log "AUDIT_START job=$jobId sha=$sourceSha"
  $result=New-AuditResult $req $sourceSha
  $publish=Publish-Durable $issue $jobId $result
  $status=$(if($publish.ok){'completed'}else{'awaiting-publication'})
  Save-State ([ordered]@{ok=$true;status=$status;jobId=$jobId;result=$result;publish=$publish;updatedAt=(Get-Date -Format o)})
  Log "AUDIT_DONE job=$jobId classification=$($result.classification) publish=$($publish.method) publishOk=$($publish.ok)"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZFamilyPTTTransportAuditWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0);if(-not $locked){exit 0};Log "START interval=${IntervalSeconds}s"
  while($true){
    try{Handle-Request}catch{
      $msg=Sanitize $_.Exception.Message;Log "ERROR $msg";$req=Read-Json $requestFile;$jobId=$(if($req){[string]$req.job_id}else{''});$issue=$(if($req){[int]$req.issue}else{17});$sha=Get-SourceSha
      $result=[ordered]@{schema=1;project='familyptt';action='audit-secure-transport';jobId=$jobId;sourceSha=$sha;finishedAt=(Get-Date -Format o);classification='WATCHER_RUNTIME_ERROR';error=$msg;safety=[ordered]@{readOnly=$true;jwtLogged=$false;credentialsLogged=$false;backendMutation=$false;dnsMutation=$false;proxyMutation=$false;firewallMutation=$false}}
      $publish=Publish-Durable $issue $jobId $result;$status=$(if($publish.ok){'completed'}else{'error-awaiting-publication'});Save-State ([ordered]@{ok=$false;status=$status;jobId=$jobId;result=$result;publish=$publish;updatedAt=(Get-Date -Format o)})
    }
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{if($locked){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
