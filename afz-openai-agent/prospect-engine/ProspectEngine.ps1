# AFZ Prospect Engine extension for AFZ-OpenAI-Agent-v2.ps1.
# Server-side lead persistence, sourced web research, and review-only Outlook drafts.

$script:ProspectRoot = Join-Path $StateRoot 'ProspectEngine'
$script:ProspectStoreFile = Join-Path $script:ProspectRoot 'prospects.json'
$script:ProspectOutlookConfigFile = Join-Path $script:ProspectRoot 'outlook-config.json'
$script:ProspectOutlookTokenFile = Join-Path $script:ProspectRoot 'outlook-refresh-token.dpapi'
$script:ProspectAuditFile = Join-Path $script:ProspectRoot 'audit.ndjson'
$script:ProspectOutlookFlow = $null
$script:ProspectOutlookAccess = $null
$script:ProspectSearchActive = $false
New-Item -ItemType Directory -Force -Path $script:ProspectRoot | Out-Null

function Write-ProspectAudit {
  param([string]$Action,[string]$LeadId,[bool]$Ok,[string]$Detail)
  $safeDetail = [string]$Detail
  if ($safeDetail.Length -gt 500) { $safeDetail = $safeDetail.Substring(0,500) }
  [ordered]@{
    time=(Get-Date -Format o);action=$Action;leadId=$LeadId;ok=$Ok;detail=$safeDetail
  } | ConvertTo-Json -Compress | Add-Content -LiteralPath $script:ProspectAuditFile -Encoding UTF8
}

function New-ProspectStore {
  return [ordered]@{schema=2;updatedAt=(Get-Date -Format o);batches=@();leads=@()}
}

function Read-ProspectStore {
  if (-not (Test-Path -LiteralPath $script:ProspectStoreFile -PathType Leaf)) { return New-ProspectStore }
  try {
    $store = Get-Content -LiteralPath $script:ProspectStoreFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $store.leads) { $store | Add-Member -NotePropertyName leads -NotePropertyValue @() -Force }
    if (-not $store.batches) { $store | Add-Member -NotePropertyName batches -NotePropertyValue @() -Force }
    return $store
  } catch {
    Write-ProspectAudit 'store-read-failed' '' $false $_.Exception.Message
    throw 'Prospect store is unreadable; no data was overwritten.'
  }
}

function Write-ProspectStore {
  param($Store)
  $Store.updatedAt = Get-Date -Format o
  $tmp = $script:ProspectStoreFile + '.tmp.' + [guid]::NewGuid().ToString('n')
  try {
    $Store | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $script:ProspectStoreFile -Force
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Get-ProspectProperty {
  param($Object,[string]$Name,$Default=$null)
  if ($null -eq $Object) { return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p) { return $p.Value }
  return $Default
}

function Test-ProspectUrl {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  $uri = $null
  return [Uri]::TryCreate($Value,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -in @('http','https')
}

function Get-ProspectHost {
  param([string]$Value)
  try { return ([Uri]$Value).DnsSafeHost.ToLowerInvariant().Replace('www.','') } catch { return '' }
}

function Test-ProspectEmail {
  param([string]$Value)
  return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[^\s@]+@[^\s@]+\.[^\s@]+$'
}

function ConvertTo-StringArray {
  param($Value,[int]$Limit=20)
  $result = @()
  foreach ($item in @($Value)) {
    $s = ([string]$item).Trim()
    if ($s -and $result.Count -lt $Limit) { $result += $s }
  }
  return $result
}

function Resolve-ProspectResearchModel {
  param($Request)
  $choice = ([string](Get-ProspectProperty $Request 'model' 'sol')).Trim().ToLowerInvariant()
  switch ($choice) {
    'luna' { return [pscustomobject][ordered]@{key='luna';model=$ModelLuna;searchContextSize='medium'} }
    'sol' { return [pscustomobject][ordered]@{key='sol';model=$ModelSol;searchContextSize='high'} }
    default { throw 'Select an approved research model: Luna or Sol.' }
  }
}

function Test-ProspectExcludedLocation {
  param($Lead,$Locations=@('Brampton'))
  if (-not $Lead) { return $false }
  $texts = @(
    [string](Get-ProspectProperty $Lead 'city' ''),
    [string](Get-ProspectProperty $Lead 'websiteSummary' '')
  )
  $texts += @(ConvertTo-StringArray (Get-ProspectProperty $Lead 'serviceAreas' @()) 30)
  $texts += @(ConvertTo-StringArray (Get-ProspectProperty $Lead 'projectEvidence' @()) 20)
  $texts += @(ConvertTo-StringArray (Get-ProspectProperty $Lead 'fitReasons' @()) 20)
  foreach ($location in @(ConvertTo-StringArray $Locations 20)) {
    $name = ([string]$location).Trim()
    if (-not $name) { continue }
    $pattern = '(?i)(?<![A-Za-z0-9])' + [regex]::Escape($name) + '(?![A-Za-z0-9])'
    foreach ($text in $texts) { if ([string]$text -match $pattern) { return $true } }
  }
  return $false
}

function New-ProspectSchema {
  $stringArray = [ordered]@{type='array';items=[ordered]@{type='string'}}
  $leadProperties = [ordered]@{
    id=[ordered]@{type='string'}
    company=[ordered]@{type='string'}
    category=[ordered]@{type='string'}
    city=[ordered]@{type='string'}
    serviceAreas=$stringArray
    website=[ordered]@{type='string'}
    publicEmail=[ordered]@{type='string'}
    contactPage=[ordered]@{type='string'}
    contactEvidenceUrl=[ordered]@{type='string'}
    recipientRole=[ordered]@{type='string'}
    websiteSummary=[ordered]@{type='string'}
    projectEvidence=$stringArray
    fitReasons=$stringArray
    matchedServices=$stringArray
    fitScore=[ordered]@{type='integer';minimum=0;maximum=100}
    competitionRisk=[ordered]@{type='string';enum=@('low','medium','high')}
    priority=[ordered]@{type='string';enum=@('A','B','C')}
    caslStatus=[ordered]@{type='string'}
    sourceUrls=$stringArray
    subject=[ordered]@{type='string'}
    emailBody=[ordered]@{type='string'}
  }
  return [ordered]@{
    type='object';additionalProperties=$false
    properties=[ordered]@{
      batch=[ordered]@{
        type='object';additionalProperties=$false
        properties=[ordered]@{
          query=[ordered]@{type='string'};region=[ordered]@{type='string'};searchedAt=[ordered]@{type='string'}
        }
        required=@('query','region','searchedAt')
      }
      leads=[ordered]@{
        type='array';items=[ordered]@{
          type='object';additionalProperties=$false;properties=$leadProperties;required=@($leadProperties.Keys)
        }
      }
    }
    required=@('batch','leads')
  }
}

function Get-ProspectResponseText {
  param($Response)
  $parts = @()
  foreach ($item in @($Response.output)) {
    if ($item.type -ne 'message') { continue }
    foreach ($content in @($item.content)) {
      if ($content.type -eq 'output_text' -and $content.text) { $parts += [string]$content.text }
    }
  }
  return ($parts -join "`n")
}

function New-NormalizedProspect {
  param($Lead,[string]$BatchId)
  $website = ([string](Get-ProspectProperty $Lead 'website' '')).Trim()
  $sources = @(ConvertTo-StringArray (Get-ProspectProperty $Lead 'sourceUrls' @()) 12 | Where-Object { Test-ProspectUrl $_ } | Select-Object -Unique)
  if (-not (Test-ProspectUrl $website) -or $sources.Count -lt 2) { return $null }
  $domain = Get-ProspectHost $website
  if (-not $domain) { return $null }
  $officialSources = @($sources | Where-Object { (Get-ProspectHost $_) -eq $domain })
  if ($officialSources.Count -lt 2) { return $null }

  $email = ([string](Get-ProspectProperty $Lead 'publicEmail' '')).Trim().ToLowerInvariant()
  if ($email -and -not (Test-ProspectEmail $email)) { $email = '' }
  $score = [math]::Max(0,[math]::Min(100,[int](Get-ProspectProperty $Lead 'fitScore' 0)))
  $id = ([string](Get-ProspectProperty $Lead 'id' '')).Trim()
  if (-not $id) { $id = [guid]::NewGuid().ToString('n') }
  return [ordered]@{
    id=$id;batchId=$BatchId
    company=([string](Get-ProspectProperty $Lead 'company' '')).Trim()
    category=([string](Get-ProspectProperty $Lead 'category' '')).Trim()
    city=([string](Get-ProspectProperty $Lead 'city' '')).Trim()
    serviceAreas=ConvertTo-StringArray (Get-ProspectProperty $Lead 'serviceAreas' @()) 30
    website=$website;publicEmail=$email
    contactPage=([string](Get-ProspectProperty $Lead 'contactPage' '')).Trim()
    contactEvidenceUrl=([string](Get-ProspectProperty $Lead 'contactEvidenceUrl' '')).Trim()
    recipientRole=([string](Get-ProspectProperty $Lead 'recipientRole' '')).Trim()
    websiteSummary=([string](Get-ProspectProperty $Lead 'websiteSummary' '')).Trim()
    projectEvidence=ConvertTo-StringArray (Get-ProspectProperty $Lead 'projectEvidence' @()) 12
    fitReasons=ConvertTo-StringArray (Get-ProspectProperty $Lead 'fitReasons' @()) 12
    matchedServices=ConvertTo-StringArray (Get-ProspectProperty $Lead 'matchedServices' @()) 6
    fitScore=$score
    competitionRisk=([string](Get-ProspectProperty $Lead 'competitionRisk' 'medium')).ToLowerInvariant()
    priority=([string](Get-ProspectProperty $Lead 'priority' 'C')).ToUpperInvariant()
    caslStatus='verify lawful basis before sending'
    sourceUrls=$sources
    subject=([string](Get-ProspectProperty $Lead 'subject' '')).Trim()
    emailBody=([string](Get-ProspectProperty $Lead 'emailBody' '')).Trim()
    status='new';reviewed=$false
    compliance=[ordered]@{recipientVerified=$false;lawfulBasisConfirmed=$false;identityIncluded=$false;unsubscribeIncluded=$false}
    outlookDraftId='';outlookWebLink='';outlookDraftedAt=$null
    createdAt=(Get-Date -Format o);updatedAt=(Get-Date -Format o)
  }
}

function Invoke-ProspectResearch {
  param($Request)
  $allowedTargets = @('Architects','BCIN designers','Permit consultants','Renovators','Design-build firms','Property managers','Realtors')
  $targets = @(ConvertTo-StringArray (Get-ProspectProperty $Request 'targets' @()) 7 | Where-Object { $_ -in $allowedTargets })
  if ($targets.Count -eq 0) { throw 'Select at least one supported prospect type.' }
  $region = ([string](Get-ProspectProperty $Request 'region' 'Toronto and GTA')).Trim()
  if ($region.Length -gt 120) { $region = $region.Substring(0,120) }
  $focus = ([string](Get-ProspectProperty $Request 'focus' '')).Trim()
  if ($focus.Length -gt 500) { $focus = $focus.Substring(0,500) }
  $requestedExcludedLocations = @(ConvertTo-StringArray (Get-ProspectProperty $Request 'excludedLocations' @()) 19)
  $excludedLocations = @((@('Brampton') + $requestedExcludedLocations) | Select-Object -Unique)
  $limit = [math]::Max(1,[math]::Min(20,[int](Get-ProspectProperty $Request 'limit' 10)))
  $minimum = [math]::Max(50,[math]::Min(95,[int](Get-ProspectProperty $Request 'minimumScore' 65)))
  $modelConfig = Resolve-ProspectResearchModel $Request
  $store = Read-ProspectStore
  $existingHosts = @($store.leads | ForEach-Object { Get-ProspectHost ([string]$_.website) } | Where-Object { $_ } | Select-Object -Unique)
  $exclude = $existingHosts -join ', '
  if ($exclude.Length -gt 3000) { $exclude = $exclude.Substring(0,3000) }

  $prompt = @"
Find up to $limit qualified AFZ Engineering referral or project-partner prospects in $region.
Target business types: $($targets -join ', ').
Extra focus: $focus
Hard-excluded locations: $($excludedLocations -join ', '). Reject any firm based in, maintaining an office in, showing projects in, or explicitly advertising service to any excluded location. Populate serviceAreas only from explicit official-website evidence. Never return an excluded firm.

AFZ services to match: residential HVAC design and inspection; building-permit drawings; renovation and addition design. Strong evidence includes additions, major renovations, legal basements, secondary suites, multiplex conversions, garden or laneway suites, custom homes, permit coordination, and mechanical or HVAC coordination.

Search the live web and inspect each candidate's official website, including home/about, services/projects, and contact pages. Keep only public business information. Never collect private homeowner data. Never guess a person's name, role, email, credential, project, or URL. Use an empty string when a contact field is not verified. Address a verified role or the company team.

Score each lead from 0 to 100: service relevance 30, current project evidence 25, repeat/referral potential 20, Ontario geography 15, verified public business contact 10, minus up to 20 for direct competition. Keep only scores of at least $minimum. Exclude direct engineering competitors unless AFZ has a clearly complementary HVAC or engineering role. Exclude already researched domains: $exclude.

Each retained lead must have an official website and at least two distinct source URLs on that same official domain. The email must cite one specific verified website detail, propose only matching AFZ services, be concise, and end with placeholders for AFZ sender name, phone, website, physical mailing address, plus: "If you prefer not to receive further messages from AFZ Engineering, please reply unsubscribe."
"@
  $response = Invoke-OpenAIResponse ([ordered]@{
    model=$modelConfig.model
    instructions='You are the AFZ Engineering Prospect Researcher. Perform read-only public-business web research. Return only schema-valid results with verified official-site evidence. Do not send or submit anything.'
    input=$prompt
    tools=@([ordered]@{type='web_search';search_context_size=$modelConfig.searchContextSize})
    text=[ordered]@{format=[ordered]@{type='json_schema';name='afz_prospect_batch';strict=$true;schema=(New-ProspectSchema)}}
  })
  $raw = Get-ProspectResponseText $response
  if ([string]::IsNullOrWhiteSpace($raw)) { throw 'The research model returned no structured prospect data.' }
  $parsed = $raw | ConvertFrom-Json
  $batchId = [guid]::NewGuid().ToString('n')
  $accepted = @()
  $seen = @{}
  foreach ($candidate in @($parsed.leads)) {
    $lead = New-NormalizedProspect $candidate $batchId
    if ($null -eq $lead -or $lead.fitScore -lt $minimum) { continue }
    if (Test-ProspectExcludedLocation $lead $excludedLocations) { continue }
    $domain = Get-ProspectHost $lead.website
    if ($existingHosts -contains $domain -or $seen.ContainsKey($domain)) { continue }
    $seen[$domain] = $true
    $accepted += $lead
    if ($accepted.Count -ge $limit) { break }
  }
  if ($accepted.Count -eq 0) { throw 'No prospects passed the official-site evidence, duplicate, and fit-score gates.' }
  $batch = [ordered]@{
    id=$batchId;query=([string]$parsed.batch.query);region=$region;targets=$targets;excludedLocations=$excludedLocations
    searchedAt=(Get-Date -Format o);minimumScore=$minimum;accepted=$accepted.Count
    modelChoice=$modelConfig.key;model=$modelConfig.model
  }
  $store.batches = @($batch) + @($store.batches | Select-Object -First 49)
  $store.leads = @($accepted) + @($store.leads | Select-Object -First 499)
  Write-ProspectStore $store
  Write-ProspectAudit 'research' '' $true "batch=$batchId accepted=$($accepted.Count) model=$($modelConfig.key)"
  return [ordered]@{ok=$true;batch=$batch;leads=$accepted;total=@($store.leads).Count}
}

function Get-LeadById {
  param($Store,[string]$Id)
  foreach ($lead in @($Store.leads)) { if ([string]$lead.id -eq $Id) { return $lead } }
  return $null
}

function Test-LeadReadyForOutlook {
  param($Lead)
  if (-not $Lead) { return $false }
  if (Test-ProspectExcludedLocation $Lead @('Brampton')) { return $false }
  $c = Get-ProspectProperty $Lead 'compliance' $null
  return (Test-ProspectEmail ([string]$Lead.publicEmail)) -and
    (Test-ProspectUrl ([string]$Lead.contactEvidenceUrl)) -and
    -not [string]::IsNullOrWhiteSpace([string]$Lead.subject) -and
    -not [string]::IsNullOrWhiteSpace([string]$Lead.emailBody) -and
    [bool](Get-ProspectProperty $c 'recipientVerified' $false) -and
    [bool](Get-ProspectProperty $c 'lawfulBasisConfirmed' $false) -and
    [bool](Get-ProspectProperty $c 'identityIncluded' $false) -and
    [bool](Get-ProspectProperty $c 'unsubscribeIncluded' $false)
}

function Update-ProspectLead {
  param($Request)
  $id = ([string](Get-ProspectProperty $Request 'id' '')).Trim()
  if (-not $id) { throw 'Lead id is required.' }
  $store = Read-ProspectStore
  $lead = Get-LeadById $store $id
  if (-not $lead) { throw 'Lead not found.' }
  $editable = @('company','category','city','publicEmail','contactPage','contactEvidenceUrl','recipientRole','websiteSummary','subject','emailBody','status','caslStatus')
  foreach ($name in $editable) {
    $value = Get-ProspectProperty $Request $name $null
    if ($null -ne $value) { $lead.$name = ([string]$value).Trim() }
  }
  if ($lead.publicEmail) { $lead.publicEmail = ([string]$lead.publicEmail).ToLowerInvariant() }
  $requestedCompliance = Get-ProspectProperty $Request 'compliance' $null
  if ($requestedCompliance) {
    $lead.compliance = [ordered]@{
      recipientVerified=[bool](Get-ProspectProperty $requestedCompliance 'recipientVerified' $false)
      lawfulBasisConfirmed=[bool](Get-ProspectProperty $requestedCompliance 'lawfulBasisConfirmed' $false)
      identityIncluded=[bool](Get-ProspectProperty $requestedCompliance 'identityIncluded' $false)
      unsubscribeIncluded=[bool](Get-ProspectProperty $requestedCompliance 'unsubscribeIncluded' $false)
    }
  }
  $lead.reviewed = [bool](Get-ProspectProperty $Request 'reviewed' $false) -and (Test-LeadReadyForOutlook $lead)
  $lead.updatedAt = Get-Date -Format o
  Write-ProspectStore $store
  Write-ProspectAudit 'lead-update' $id $true "reviewed=$($lead.reviewed)"
  return [ordered]@{ok=$true;lead=$lead}
}

function Remove-ProspectLead {
  param($Request)
  $id = ([string](Get-ProspectProperty $Request 'id' '')).Trim()
  $store = Read-ProspectStore
  $lead = Get-LeadById $store $id
  if ($lead -and $lead.outlookDraftId) { throw 'A lead with an existing Outlook draft cannot be deleted from the audit trail.' }
  $before = @($store.leads).Count
  $store.leads = @($store.leads | Where-Object { [string]$_.id -ne $id })
  if (@($store.leads).Count -eq $before) { throw 'Lead not found.' }
  Write-ProspectStore $store
  Write-ProspectAudit 'lead-delete' $id $true 'deleted'
  return [ordered]@{ok=$true;id=$id}
}

function Read-OutlookConfig {
  if (-not (Test-Path -LiteralPath $script:ProspectOutlookConfigFile -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $script:ProspectOutlookConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Save-OutlookConfig {
  param($Request)
  $clientId = ([string](Get-ProspectProperty $Request 'clientId' '')).Trim()
  $tenant = ([string](Get-ProspectProperty $Request 'tenant' 'organizations')).Trim().ToLowerInvariant()
  if ($clientId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Microsoft Entra application client ID must be a GUID.' }
  if ($tenant -notmatch '^(organizations|common|consumers|[0-9a-fA-F-]{36}|[a-z0-9.-]+)$') { throw 'Invalid Microsoft tenant value.' }
  [ordered]@{clientId=$clientId;tenant=$tenant;updatedAt=(Get-Date -Format o)} |
    ConvertTo-Json | Set-Content -LiteralPath $script:ProspectOutlookConfigFile -Encoding UTF8
  Remove-Item -LiteralPath $script:ProspectOutlookTokenFile -Force -ErrorAction SilentlyContinue
  $script:ProspectOutlookAccess = $null
  $script:ProspectOutlookFlow = $null
  Write-ProspectAudit 'outlook-config' '' $true "tenant=$tenant"
  return [ordered]@{ok=$true;configured=$true;tenant=$tenant;connected=$false}
}

function Protect-OutlookRefreshToken {
  param([string]$Token)
  $bytes = [Text.Encoding]::UTF8.GetBytes($Token)
  $protected = [System.Security.Cryptography.ProtectedData]::Protect($bytes,$null,[System.Security.Cryptography.DataProtectionScope]::LocalMachine)
  [IO.File]::WriteAllBytes($script:ProspectOutlookTokenFile,$protected)
}

function Unprotect-OutlookRefreshToken {
  if (-not (Test-Path -LiteralPath $script:ProspectOutlookTokenFile -PathType Leaf)) { return '' }
  $protected = [IO.File]::ReadAllBytes($script:ProspectOutlookTokenFile)
  $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($protected,$null,[System.Security.Cryptography.DataProtectionScope]::LocalMachine)
  return [Text.Encoding]::UTF8.GetString($bytes)
}

function Get-WebExceptionJson {
  param($ErrorRecord)
  $candidates = @()
  try {
    if ($ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ErrorDetails.Message)) {
      $candidates += [string]$ErrorRecord.ErrorDetails.Message
    }
  } catch {}
  try {
    $response = $ErrorRecord.Exception.Response
    if ($response) {
      if ($response.PSObject.Properties['Content'] -and $response.Content) {
        try { $candidates += [string]$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch {}
      }
      if ($response.PSObject.Methods['GetResponseStream']) {
        $stream = $response.GetResponseStream()
        if ($stream) {
          $reader = New-Object IO.StreamReader($stream)
          try { $candidates += $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
      }
    }
  } catch {}
  foreach ($candidate in $candidates) {
    $raw = ([string]$candidate).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    try { return $raw | ConvertFrom-Json -ErrorAction Stop } catch {}
    $first = $raw.IndexOf('{'); $last = $raw.LastIndexOf('}')
    if ($first -ge 0 -and $last -gt $first) {
      try { return $raw.Substring($first,$last-$first+1) | ConvertFrom-Json -ErrorAction Stop } catch {}
    }
  }
  return $null
}

function Get-WebExceptionStatusCode {
  param($ErrorRecord)
  try {
    if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
      return [int]$ErrorRecord.Exception.Response.StatusCode
    }
  } catch {}
  return 0
}

function Test-OutlookDevicePollWaiting {
  param($ErrorRecord,$Body)
  $code = [string](Get-ProspectProperty $Body 'error' '')
  if ($code -in @('authorization_pending','slow_down')) { return $true }
  if (-not [string]::IsNullOrWhiteSpace($code)) { return $false }
  # Windows PowerShell 5.1 can consume an OAuth error response body before the
  # catch block reads it. The device-code request has already validated the
  # client and tenant, so an otherwise-unclassified 400 during this bounded
  # pre-expiry poll is treated as Microsoft's normal authorization_pending state.
  return (Get-WebExceptionStatusCode $ErrorRecord) -eq 400
}

function Start-OutlookDeviceFlow {
  $config = Read-OutlookConfig
  if (-not $config) { throw 'Outlook is not configured. Enter the Entra application client ID first.' }
  $uri = "https://login.microsoftonline.com/$($config.tenant)/oauth2/v2.0/devicecode"
  $result = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/x-www-form-urlencoded' -Body @{
    client_id=[string]$config.clientId;scope='offline_access User.Read Mail.ReadWrite'
  } -TimeoutSec 30
  $script:ProspectOutlookFlow = [ordered]@{
    deviceCode=[string]$result.device_code;interval=[int]$result.interval
    expiresAt=(Get-Date).AddSeconds([int]$result.expires_in);tenant=[string]$config.tenant;clientId=[string]$config.clientId
  }
  Write-ProspectAudit 'outlook-connect-start' '' $true 'device-code-issued'
  return [ordered]@{
    ok=$true;state='waiting';userCode=[string]$result.user_code
    verificationUri=[string]$result.verification_uri;message=[string]$result.message
    expiresIn=[int]$result.expires_in;interval=[int]$result.interval
  }
}

function Complete-OutlookDeviceFlow {
  if (-not $script:ProspectOutlookFlow) { return [ordered]@{ok=$false;state='not_started';error='Start Outlook connection first.'} }
  if ((Get-Date) -ge $script:ProspectOutlookFlow.expiresAt) {
    $script:ProspectOutlookFlow = $null
    return [ordered]@{ok=$false;state='expired';error='The Microsoft device code expired. Start again.'}
  }
  $uri = "https://login.microsoftonline.com/$($script:ProspectOutlookFlow.tenant)/oauth2/v2.0/token"
  try {
    $token = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/x-www-form-urlencoded' -Body @{
      grant_type='urn:ietf:params:oauth:grant-type:device_code'
      client_id=[string]$script:ProspectOutlookFlow.clientId
      device_code=[string]$script:ProspectOutlookFlow.deviceCode
    } -TimeoutSec 30
  } catch {
    $body = Get-WebExceptionJson $_
    $code = [string](Get-ProspectProperty $body 'error' '')
    if (Test-OutlookDevicePollWaiting $_ $body) { return [ordered]@{ok=$true;state='waiting'} }
    $description = [string](Get-ProspectProperty $body 'error_description' $_.Exception.Message)
    Write-ProspectAudit 'outlook-connect-failed' '' $false $code
    return [ordered]@{ok=$false;state='failed';error=$description}
  }
  if (-not $token.refresh_token) { throw 'Microsoft did not return a refresh token.' }
  Protect-OutlookRefreshToken ([string]$token.refresh_token)
  $script:ProspectOutlookAccess = [ordered]@{token=[string]$token.access_token;expiresAt=(Get-Date).AddSeconds([math]::Max(60,[int]$token.expires_in-120))}
  $script:ProspectOutlookFlow = $null
  Write-ProspectAudit 'outlook-connected' '' $true 'delegated-mail-readwrite'
  return [ordered]@{ok=$true;state='connected'}
}

function Get-OutlookAccessToken {
  if ($script:ProspectOutlookAccess -and (Get-Date) -lt $script:ProspectOutlookAccess.expiresAt) { return [string]$script:ProspectOutlookAccess.token }
  $config = Read-OutlookConfig
  if (-not $config) { throw 'Outlook is not configured.' }
  $refresh = Unprotect-OutlookRefreshToken
  if (-not $refresh) { throw 'Outlook is not connected.' }
  $uri = "https://login.microsoftonline.com/$($config.tenant)/oauth2/v2.0/token"
  $token = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/x-www-form-urlencoded' -Body @{
    grant_type='refresh_token';client_id=[string]$config.clientId;refresh_token=$refresh
    scope='offline_access User.Read Mail.ReadWrite'
  } -TimeoutSec 30
  if ($token.refresh_token) { Protect-OutlookRefreshToken ([string]$token.refresh_token) }
  $script:ProspectOutlookAccess = [ordered]@{token=[string]$token.access_token;expiresAt=(Get-Date).AddSeconds([math]::Max(60,[int]$token.expires_in-120))}
  return [string]$token.access_token
}

function Get-OutlookStatus {
  $config = Read-OutlookConfig
  if (-not $config) { return [ordered]@{ok=$true;configured=$false;connected=$false;tenant='organizations'} }
  if (-not (Test-Path -LiteralPath $script:ProspectOutlookTokenFile -PathType Leaf)) {
    return [ordered]@{ok=$true;configured=$true;connected=$false;tenant=[string]$config.tenant}
  }
  try {
    $token = Get-OutlookAccessToken
    $me = Invoke-RestMethod -Method Get -Uri 'https://graph.microsoft.com/v1.0/me?$select=displayName,mail,userPrincipalName' -Headers @{Authorization="Bearer $token"} -TimeoutSec 30
    $mail = [string]$me.mail; if (-not $mail) { $mail=[string]$me.userPrincipalName }
    return [ordered]@{ok=$true;configured=$true;connected=$true;tenant=[string]$config.tenant;displayName=[string]$me.displayName;mail=$mail}
  } catch {
    return [ordered]@{ok=$false;configured=$true;connected=$false;tenant=[string]$config.tenant;error=$_.Exception.Message}
  }
}

function New-OutlookProspectDraft {
  param($Request)
  $id = ([string](Get-ProspectProperty $Request 'id' '')).Trim()
  $store = Read-ProspectStore
  $lead = Get-LeadById $store $id
  if (-not $lead) { throw 'Lead not found.' }
  if (-not [bool]$lead.reviewed -or -not (Test-LeadReadyForOutlook $lead)) { throw 'Complete every review and CASL preflight item before creating an Outlook draft.' }
  if ($lead.outlookDraftId) { throw 'An Outlook draft already exists for this lead. Open the existing draft instead of creating a duplicate.' }
  $token = Get-OutlookAccessToken
  $payload = [ordered]@{
    subject=[string]$lead.subject
    body=[ordered]@{contentType='Text';content=[string]$lead.emailBody}
    toRecipients=@([ordered]@{emailAddress=[ordered]@{address=[string]$lead.publicEmail;name=[string]$lead.company}})
  }
  $draft = Invoke-RestMethod -Method Post -Uri 'https://graph.microsoft.com/v1.0/me/messages' -Headers @{Authorization="Bearer $token"} -ContentType 'application/json' -Body ($payload | ConvertTo-Json -Depth 12 -Compress) -TimeoutSec 30
  $lead.outlookDraftId = [string]$draft.id
  $lead.outlookWebLink = [string]$draft.webLink
  $lead.outlookDraftedAt = Get-Date -Format o
  $lead.status = 'drafted'
  $lead.updatedAt = Get-Date -Format o
  Write-ProspectStore $store
  Write-ProspectAudit 'outlook-draft-created' $id $true "recipient=$($lead.publicEmail)"
  return [ordered]@{ok=$true;lead=$lead;draft=[ordered]@{id=[string]$draft.id;webLink=[string]$draft.webLink;isDraft=[bool]$draft.isDraft}}
}

function Test-ProspectRequestOrigin {
  param($Context)
  $origin = [string]$Context.Request.Headers['Origin']
  if ([string]::IsNullOrWhiteSpace($origin)) { return $true }
  $expected = $Context.Request.Url.GetLeftPart([UriPartial]::Authority)
  return $origin.TrimEnd('/') -eq $expected.TrimEnd('/')
}

function Invoke-ProspectEngineRoute {
  param($Context,[string]$Path)
  $method = $Context.Request.HttpMethod
  if ($Path.StartsWith('/api/') -and $method -eq 'POST' -and -not (Test-ProspectRequestOrigin $Context)) {
    Send-Json $Context 403 @{ok=$false;error='Cross-origin Prospect Engine writes are blocked.'}
    return $true
  }
  if ($Path -eq '/prospects' -and $method -eq 'GET') {
    $file = Join-Path $AgentRoot 'prospect-engine\index.html'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Send-Json $Context 500 @{ok=$false;error='Prospect Engine UI missing'}; return $true }
    Send-Text $Context 200 'text/html; charset=utf-8' (Get-Content -LiteralPath $file -Raw -Encoding UTF8)
    return $true
  }
  if ($Path -eq '/api/prospects' -and $method -eq 'GET') {
    $store = Read-ProspectStore
    Send-Json $Context 200 @{ok=$true;store=$store}
    return $true
  }
  if ($Path -eq '/api/prospects/search' -and $method -eq 'POST') {
    if ($script:ProspectSearchActive) {
      Send-Json $Context 409 @{ok=$false;code='research_in_progress';error='A prospect research batch is already running. Wait for it to finish before starting another.';retryable=$true}
      return $true
    }
    $script:ProspectSearchActive = $true
    try {
      try {
        Send-Json $Context 200 (Invoke-ProspectResearch (Read-JsonBody $Context))
      } catch {
        $code = [string]$_.Exception.Data['AfzErrorCode']
        $retryAfter = 0
        try { $retryAfter = [int]$_.Exception.Data['RetryAfterSeconds'] } catch {}
        Write-ProspectAudit 'research' '' $false $_.Exception.Message
        if ($code -in @('openai_rate_limit','openai_quota')) {
          Send-Json $Context 429 ([ordered]@{
            ok=$false;code=$code;error=$_.Exception.Message
            retryable=($code -eq 'openai_rate_limit');retryAfterSeconds=$retryAfter
          })
        } else {
          Send-Json $Context 502 @{ok=$false;code='research_failed';error=$_.Exception.Message;retryable=$false}
        }
      }
    } finally {
      $script:ProspectSearchActive = $false
    }
    return $true
  }
  if ($Path -eq '/api/prospects/update' -and $method -eq 'POST') {
    Send-Json $Context 200 (Update-ProspectLead (Read-JsonBody $Context))
    return $true
  }
  if ($Path -eq '/api/prospects/delete' -and $method -eq 'POST') {
    Send-Json $Context 200 (Remove-ProspectLead (Read-JsonBody $Context))
    return $true
  }
  if ($Path -eq '/api/outlook/status' -and $method -eq 'GET') {
    Send-Json $Context 200 (Get-OutlookStatus)
    return $true
  }
  if ($Path -eq '/api/outlook/config' -and $method -eq 'POST') {
    Send-Json $Context 200 (Save-OutlookConfig (Read-JsonBody $Context))
    return $true
  }
  if ($Path -eq '/api/outlook/connect' -and $method -eq 'POST') {
    Send-Json $Context 200 (Start-OutlookDeviceFlow)
    return $true
  }
  if ($Path -eq '/api/outlook/connect-status' -and $method -eq 'POST') {
    Send-Json $Context 200 (Complete-OutlookDeviceFlow)
    return $true
  }
  if ($Path -eq '/api/prospects/outlook-draft' -and $method -eq 'POST') {
    Send-Json $Context 200 (New-OutlookProspectDraft (Read-JsonBody $Context))
    return $true
  }
  return $false
}
