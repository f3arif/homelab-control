#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot = 'C:\AFZ\homelab-control',
  [int]$IntervalSeconds = 5
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$IntervalSeconds = [math]::Max(3, [math]::Min($IntervalSeconds, 30))

$requestFile = Join-Path $InstallRoot 'afz-openai-agent\requests\familyptt-transport-audit-r3.json'
$sourceState = 'C:\ProgramData\AFZ\OpenAIAgent\source-state.json'
$stateRoot = 'C:\ProgramData\AFZ\OpenAIAgent\jobs\familyptt-transport-audit-r3'
$stateFile = Join-Path $stateRoot 'latest.json'
$logFile = Join-Path $stateRoot 'watcher.log'
$familyPttRepo = 'C:\Projects\FamilyPTT'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Log([string]$Message) {
  Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8
}

function Read-Json([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { return $null }
}

function Save-State($Object) {
  $Object | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $stateFile -Encoding UTF8
}

function Get-SourceSha {
  $state = Read-Json $sourceState
  if ($state -and ([string]$state.remoteSha) -match '^[0-9a-fA-F]{40}$') {
    return ([string]$state.remoteSha).ToLowerInvariant()
  }
  return ''
}

function Sanitize([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $value = $Text
  $value = [regex]::Replace($value, 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}', '[REDACTED_JWT]')
  $value = [regex]::Replace($value, '(?i)(authorization:\s*bearer\s+)\S+', '$1[REDACTED]')
  $value = [regex]::Replace($value, '(?i)(https?://)[^/@\s]+@', '$1[REDACTED]@')
  if ($value.Length -gt 1500) { $value = $value.Substring(0, 1500) }
  return $value
}

function Valid-HostName([string]$Value) {
  return ($Value -match '^[A-Za-z0-9][A-Za-z0-9.-]{1,251}[A-Za-z0-9]$' -and $Value -notmatch '\.\.')
}

function Valid-Request($Request) {
  if (-not $Request) { return $false }
  if ([int]$Request.schema -ne 1) { return $false }
  if ([string]$Request.project -ne 'familyptt') { return $false }
  if ([string]$Request.action -ne 'audit-secure-transport') { return $false }
  if ([int]$Request.issue -lt 1) { return $false }
  if (([string]$Request.job_id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$') { return $false }
  if (([string]$Request.backend_host) -notmatch '^100\.(?:\d{1,3}\.){2}\d{1,3}$') { return $false }
  if ([int]$Request.token_port -ne 7883) { return $false }
  if ([int]$Request.livekit_port -ne 7880) { return $false }
  if (-not (Valid-HostName ([string]$Request.api_hostname))) { return $false }
  if (-not (Valid-HostName ([string]$Request.livekit_hostname))) { return $false }
  return $true
}

function Test-Tcp([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 3000) {
  $client = New-Object Net.Sockets.TcpClient
  try {
    $pending = $client.BeginConnect($TargetHost, $Port, $null, $null)
    if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
    $client.EndConnect($pending)
    return $true
  }
  catch { return $false }
  finally { $client.Close() }
}

function Resolve-IPv4([string]$TargetHost) {
  try {
    return @(
      [Net.Dns]::GetHostAddresses($TargetHost) |
        Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.IPAddressToString } |
        Sort-Object -Unique
    )
  }
  catch { return @() }
}

function Test-Tls443([string]$TargetHost) {
  $tcp = New-Object Net.Sockets.TcpClient
  try {
    $pending = $tcp.BeginConnect($TargetHost, 443, $null, $null)
    if (-not $pending.AsyncWaitHandle.WaitOne(4000, $false)) {
      return [ordered]@{ tcp=$false; valid=$false; error='connect-timeout' }
    }
    $tcp.EndConnect($pending)
    $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false)
    try {
      $ssl.AuthenticateAsClient($TargetHost)
      $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
      return [ordered]@{
        tcp = $true
        valid = $true
        subject = $cert.Subject
        notAfter = $cert.NotAfter.ToUniversalTime().ToString('o')
      }
    }
    finally { $ssl.Dispose() }
  }
  catch {
    return [ordered]@{ tcp=$true; valid=$false; error=(Sanitize $_.Exception.Message) }
  }
  finally { $tcp.Close() }
}

function Invoke-HttpCode([string]$Uri, [int]$TimeoutSec = 8) {
  try {
    $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec
    return [int]$response.StatusCode
  }
  catch {
    $response = $_.Exception.Response
    if ($response -and $response.StatusCode) { return [int]$response.StatusCode.value__ }
    return 0
  }
}

function Publish-GitHubIssue([int]$Issue, [string]$Markdown) {
  $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
  if (-not $gh) {
    return [ordered]@{ ok=$false; method='gh-issue-comment'; error='gh.exe unavailable' }
  }

  $payload = Join-Path $env:TEMP ('familyptt-audit-' + [guid]::NewGuid().ToString('n') + '.json')
  try {
    [ordered]@{ body=$Markdown } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $payload -Encoding UTF8
    $raw = & $gh.Source api --method POST "repos/f3arif/homelab-control/issues/$Issue/comments" --input $payload 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { return [ordered]@{ ok=$true; method='gh-issue-comment' } }
    return [ordered]@{ ok=$false; method='gh-issue-comment'; error=(Sanitize $raw.Trim()) }
  }
  catch {
    return [ordered]@{ ok=$false; method='gh-issue-comment'; error=(Sanitize $_.Exception.Message) }
  }
  finally { Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue }
}

function Get-FamilyPttRemoteUrl([string]$GitExe) {
  if (-not (Test-Path -LiteralPath (Join-Path $familyPttRepo '.git'))) {
    throw 'FamilyPTT local Git repository unavailable'
  }
  foreach ($remote in @('github','origin')) {
    $url = (& $GitExe -C $familyPttRepo remote get-url $remote 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $url) {
      $url = [string]$url
      if ($url -match '(?i)github\.com[:/]f3arif/FamilyPTT(?:\.git)?$') { return $url }
    }
  }
  throw 'Expected FamilyPTT GitHub remote unavailable'
}

function Publish-FamilyPttResultBranch([string]$JobId, $ResultObject) {
  $git = Get-Command git.exe -ErrorAction SilentlyContinue
  if (-not $git) {
    return [ordered]@{ ok=$false; method='familyptt-result-branch'; error='git.exe unavailable' }
  }

  $tmp = Join-Path $env:TEMP ('familyptt-audit-publish-' + [guid]::NewGuid().ToString('n'))
  $repo = Join-Path $tmp 'repo'
  $branch = ('afz-results/' + $JobId).ToLowerInvariant()
  try {
    $remoteUrl = Get-FamilyPttRemoteUrl $git.Source
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    & $git.Source -C $repo init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    & $git.Source -C $repo remote add origin $remoteUrl
    if ($LASTEXITCODE -ne 0) { throw 'git remote add failed' }
    & $git.Source -C $repo fetch --quiet --depth 1 origin main
    if ($LASTEXITCODE -ne 0) { throw 'FamilyPTT authenticated fetch failed' }
    & $git.Source -C $repo checkout --quiet -b $branch FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw 'git checkout result branch failed' }

    $dir = Join-Path $repo 'ops-results'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $out = Join-Path $dir ($JobId + '.json')
    $ResultObject | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $out -Encoding UTF8

    & $git.Source -C $repo config user.name 'AFZ Windows Worker'
    & $git.Source -C $repo config user.email '77086535+f3arif@users.noreply.github.com'
    & $git.Source -C $repo add -- 'ops-results'
    if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
    & $git.Source -C $repo commit --quiet -m "FamilyPTT transport audit $JobId"
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
    & $git.Source -C $repo push --quiet origin "HEAD:refs/heads/$branch"
    if ($LASTEXITCODE -ne 0) { throw 'FamilyPTT result push failed' }

    return [ordered]@{
      ok = $true
      method = 'familyptt-result-branch'
      branch = $branch
      path = ('ops-results/' + $JobId + '.json')
    }
  }
  catch {
    return [ordered]@{ ok=$false; method='familyptt-result-branch'; error=(Sanitize $_.Exception.Message) }
  }
  finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Format-Markdown($Result) {
  if ([string]$Result.classification -eq 'WATCHER_RUNTIME_ERROR') {
    return @"
## FamilyPTT transport audit - $($Result.jobId)

Windows-main reached a sanitized runtime error before completing the read-only audit.

Classification: WATCHER_RUNTIME_ERROR
Error: $($Result.error)
"@
  }

  $private = $Result.privateBackend
  $edge = $Result.candidateEdge
  return @"
## FamilyPTT transport audit - $($Result.jobId)

Windows-main executed the typed read-only audit after pulling exact GitHub source $($Result.sourceSha). JWT contents were discarded in memory.

Private API TCP: $($private.apiTcp)
Private LiveKit TCP: $($private.livekitTcp)
API health HTTP: $($private.healthHttpCode)
Token HTTP: $($private.tokenHttpCode)
Token present (value not logged): $($private.tokenPresent)
Floor status HTTP: $($private.floorStatusHttpCode)
Returned LiveKit scheme: $($private.returnedLiveKitScheme)
Candidate API DNS: $(@($edge.apiIpv4) -join ',')
Candidate API TLS valid: $($edge.apiTlsValid)
Candidate LiveKit DNS: $(@($edge.livekitIpv4) -join ',')
Candidate LiveKit TLS valid: $($edge.livekitTlsValid)
Public API health HTTPS: $($edge.publicApiHealthHttpCode)

Classification: $($Result.classification)
"@
}

function Publish-Durable([int]$Issue, [string]$JobId, $Result) {
  $issuePublish = Publish-GitHubIssue $Issue (Format-Markdown $Result)
  if ($issuePublish.ok) { return $issuePublish }

  $branchPublish = Publish-FamilyPttResultBranch $JobId $Result
  if ($branchPublish.ok) { return $branchPublish }

  return [ordered]@{
    ok = $false
    method = 'none'
    issueError = Sanitize ([string]$issuePublish.error)
    branchError = Sanitize ([string]$branchPublish.error)
  }
}

function New-AuditResult($Request, [string]$SourceSha) {
  $jobId = [string]$Request.job_id
  $backendHost = [string]$Request.backend_host
  $apiPort = [int]$Request.token_port
  $liveKitPort = [int]$Request.livekit_port
  $apiHost = [string]$Request.api_hostname
  $liveKitHost = [string]$Request.livekit_hostname
  $started = Get-Date -Format o

  $apiTcp = Test-Tcp $backendHost $apiPort
  $liveKitTcp = Test-Tcp $backendHost $liveKitPort
  $privateHealthUri = 'http://{0}:{1}/health' -f $backendHost, $apiPort
  $floorUri = 'http://{0}:{1}/floor/status?room=family-main' -f $backendHost, $apiPort
  $healthCode = Invoke-HttpCode $privateHealthUri
  $floorCode = Invoke-HttpCode $floorUri

  $tokenCode = 0
  $tokenPresent = $false
  $serverScheme = 'none'
  $serverHost = ''
  $serverPort = 0
  $tokenRoom = ''
  try {
    $identity = 'afz-transport-audit-' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $tokenUri = 'http://{0}:{1}/token?identity={2}&name=AFZ%20Transport%20Audit&room=family-main' -f $backendHost, $apiPort, $identity
    $tokenResponse = Invoke-WebRequest -Uri $tokenUri -UseBasicParsing -TimeoutSec 10
    $tokenCode = [int]$tokenResponse.StatusCode
    $tokenData = $tokenResponse.Content | ConvertFrom-Json
    $tokenPresent = ([string]$tokenData.participantToken).Length -gt 20
    $tokenRoom = [string]$tokenData.room
    $serverUrl = [string]$tokenData.serverUrl
    if ($serverUrl) {
      try {
        $uri = [Uri]$serverUrl
        $serverScheme = $uri.Scheme.ToLowerInvariant()
        $serverHost = $uri.Host
        $serverPort = $uri.Port
      }
      catch { $serverScheme = 'invalid' }
    }
    $tokenData = $null
    $tokenResponse = $null
    $serverUrl = $null
  }
  catch {
    $response = $_.Exception.Response
    if ($response -and $response.StatusCode) { $tokenCode = [int]$response.StatusCode.value__ }
  }

  $apiIps = Resolve-IPv4 $apiHost
  $liveKitIps = Resolve-IPv4 $liveKitHost
  $apiTls = Test-Tls443 $apiHost
  $liveKitTls = Test-Tls443 $liveKitHost
  $publicHealthCode = Invoke-HttpCode ('https://{0}/health' -f $apiHost)

  $classification = 'PRIVATE_BACKEND_REVIEW_REQUIRED'
  if ($apiTcp -and $liveKitTcp -and $tokenCode -eq 200 -and $tokenPresent) {
    if ($apiIps.Count -eq 0 -or $liveKitIps.Count -eq 0) {
      $classification = 'PRIVATE_BACKEND_READY_EDGE_DNS_MISSING'
    }
    elseif (-not [bool]$apiTls.valid -or -not [bool]$liveKitTls.valid) {
      $classification = 'PRIVATE_BACKEND_READY_TLS_EDGE_NOT_READY'
    }
    elseif ($publicHealthCode -lt 200 -or $publicHealthCode -ge 400) {
      $classification = 'TLS_EDGE_PRESENT_PUBLIC_API_NOT_READY'
    }
    elseif ($serverScheme -ne 'wss') {
      $classification = 'TLS_API_READY_LIVEKIT_WSS_NOT_READY'
    }
    else {
      $classification = 'SECURE_TRANSPORT_READY'
    }
  }

  return [ordered]@{
    schema = 1
    project = 'familyptt'
    action = 'audit-secure-transport'
    jobId = $jobId
    sourceSha = $SourceSha
    startedAt = $started
    finishedAt = (Get-Date -Format o)
    classification = $classification
    privateBackend = [ordered]@{
      apiTcp = $apiTcp
      livekitTcp = $liveKitTcp
      healthHttpCode = $healthCode
      tokenHttpCode = $tokenCode
      tokenPresent = $tokenPresent
      tokenRoom = $tokenRoom
      floorStatusHttpCode = $floorCode
      returnedLiveKitScheme = $serverScheme
      returnedLiveKitHost = $serverHost
      returnedLiveKitPort = $serverPort
    }
    candidateEdge = [ordered]@{
      apiHostname = $apiHost
      apiIpv4 = @($apiIps)
      apiTlsValid = [bool]$apiTls.valid
      apiTlsNotAfter = $apiTls.notAfter
      livekitHostname = $liveKitHost
      livekitIpv4 = @($liveKitIps)
      livekitTlsValid = [bool]$liveKitTls.valid
      livekitTlsNotAfter = $liveKitTls.notAfter
      publicApiHealthHttpCode = $publicHealthCode
    }
    safety = [ordered]@{
      readOnly = $true
      jwtLogged = $false
      credentialsLogged = $false
      backendMutation = $false
      dnsMutation = $false
      proxyMutation = $false
      firewallMutation = $false
    }
  }
}

function Handle-Request {
  if (-not (Test-Path -LiteralPath $requestFile)) { return }
  $request = Read-Json $requestFile
  if (-not (Valid-Request $request)) { throw "Invalid FamilyPTT typed request: $requestFile" }

  $jobId = [string]$request.job_id
  $issue = [int]$request.issue
  $prior = Read-Json $stateFile
  if ($prior -and [string]$prior.jobId -eq $jobId -and [string]$prior.status -eq 'completed') { return }

  if ($prior -and [string]$prior.jobId -eq $jobId -and [string]$prior.status -in @('awaiting-publication','error-awaiting-publication') -and $prior.result) {
    $publish = Publish-Durable $issue $jobId $prior.result
    $prior.publish = $publish
    $prior.updatedAt = Get-Date -Format o
    if ($publish.ok) {
      $prior.status = 'completed'
      Log "PUBLISH_RETRY_OK job=$jobId method=$($publish.method)"
    }
    Save-State $prior
    return
  }

  $sourceSha = Get-SourceSha
  if ($sourceSha -notmatch '^[0-9a-f]{40}$') { throw 'Exact GitHub source SHA unavailable' }
  Log "AUDIT_START job=$jobId sha=$sourceSha"

  $result = New-AuditResult $request $sourceSha
  $publish = Publish-Durable $issue $jobId $result
  $status = if ($publish.ok) { 'completed' } else { 'awaiting-publication' }
  Save-State ([ordered]@{
    ok = $true
    status = $status
    jobId = $jobId
    result = $result
    publish = $publish
    updatedAt = (Get-Date -Format o)
  })
  Log "AUDIT_DONE job=$jobId classification=$($result.classification) publish=$($publish.method) publishOk=$($publish.ok)"
}

$mutex = New-Object Threading.Mutex($false, 'Global\AFZFamilyPTTTransportAuditWatcherR3')
$locked = $false
try {
  $locked = $mutex.WaitOne(0)
  if (-not $locked) { exit 0 }
  Log "START interval=${IntervalSeconds}s"

  while ($true) {
    try { Handle-Request }
    catch {
      $message = Sanitize $_.Exception.Message
      Log "ERROR $message"
      $request = Read-Json $requestFile
      $jobId = if ($request) { [string]$request.job_id } else { '' }
      $issue = if ($request) { [int]$request.issue } else { 17 }
      $result = [ordered]@{
        schema = 1
        project = 'familyptt'
        action = 'audit-secure-transport'
        jobId = $jobId
        sourceSha = Get-SourceSha
        finishedAt = (Get-Date -Format o)
        classification = 'WATCHER_RUNTIME_ERROR'
        error = $message
        safety = [ordered]@{
          readOnly = $true
          jwtLogged = $false
          credentialsLogged = $false
          backendMutation = $false
          dnsMutation = $false
          proxyMutation = $false
          firewallMutation = $false
        }
      }
      $publish = Publish-Durable $issue $jobId $result
      $status = if ($publish.ok) { 'completed' } else { 'error-awaiting-publication' }
      Save-State ([ordered]@{
        ok = $false
        status = $status
        jobId = $jobId
        result = $result
        publish = $publish
        updatedAt = (Get-Date -Format o)
      })
    }
    Start-Sleep -Seconds $IntervalSeconds
  }
}
finally {
  if ($locked) { try { $mutex.ReleaseMutex() } catch {} }
  $mutex.Dispose()
}
