#Requires -Version 7.0
$ErrorActionPreference='Stop'
$StateRoot=Join-Path ([IO.Path]::GetTempPath()) ('afz-prospect-test-'+[guid]::NewGuid().ToString('n'))
$AgentRoot=Split-Path -Parent $PSScriptRoot
$ModelSol='test-sol'
$ModelLuna='test-luna'

function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERTION FAILED: $Message"}}

try{
  . (Join-Path $PSScriptRoot 'ProspectEngine.ps1')
  $engineSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ProspectEngine.ps1') -Raw -Encoding UTF8
  $agentSource=Get-Content -LiteralPath (Join-Path $AgentRoot 'AFZ-OpenAI-Agent-v2.ps1') -Raw -Encoding UTF8
  Assert-True ($engineSource.Contains("type='web_search_preview'")) 'Responses API research must use the documented web-search preview declaration'
  Assert-True (-not $engineSource.Contains("type='web_search';")) 'legacy web_search plus search_context_size declaration must not return'
  Assert-True ($agentSource.Contains("New-Object System.Text.UTF8Encoding(`$false)")) 'OpenAI JSON must use explicit no-BOM UTF-8 encoding on Windows PowerShell'
  Assert-True ($agentSource.Contains("-Body `$jsonBytes")) 'OpenAI request transport must send the validated UTF-8 byte array'
  $sol=Resolve-ProspectResearchModel ([pscustomobject]@{model='sol'})
  Assert-True ($sol.model -eq 'test-sol' -and $sol.searchContextSize -eq 'high') 'Sol selection should use the configured Sol model'
  $luna=Resolve-ProspectResearchModel ([pscustomobject]@{model='luna'})
  Assert-True ($luna.model -eq 'test-luna' -and $luna.searchContextSize -eq 'medium') 'Luna selection should use the configured Luna model'
  $invalidRejected=$false;try{Resolve-ProspectResearchModel ([pscustomobject]@{model='arbitrary-model'})|Out-Null}catch{$invalidRejected=$true}
  Assert-True $invalidRejected 'arbitrary client-supplied model ids must be rejected'
  $pendingError=[pscustomobject]@{
    ErrorDetails=[pscustomobject]@{Message='{"error":"authorization_pending","error_description":"Authorization is pending."}'}
    Exception=[pscustomobject]@{Response=$null}
  }
  $pendingBody=Get-WebExceptionJson $pendingError
  Assert-True ([string]$pendingBody.error -eq 'authorization_pending') 'OAuth JSON should be parsed from PowerShell ErrorDetails'
  Assert-True (Test-OutlookDevicePollWaiting $pendingError $pendingBody) 'authorization_pending should remain a waiting state'
  $unparsed400=[pscustomobject]@{
    ErrorDetails=$null
    Exception=[pscustomobject]@{Response=[pscustomobject]@{StatusCode=400}}
  }
  Assert-True (Test-OutlookDevicePollWaiting $unparsed400 $null) 'unparsed pre-expiry OAuth 400 should remain a waiting state'
  $invalidBody=[pscustomobject]@{error='invalid_client'}
  Assert-True (-not (Test-OutlookDevicePollWaiting $unparsed400 $invalidBody)) 'a parsed terminal OAuth error must not be hidden as waiting'
  $candidate=[pscustomobject]@{
    id='lead-1';company='Example Design';category='BCIN designers';city='Toronto'
    serviceAreas=@('Toronto','Markham')
    website='https://example.com';publicEmail='projects@example.com'
    contactPage='https://example.com/contact';contactEvidenceUrl='https://example.com/contact'
    recipientRole='Design team';websiteSummary='Residential addition design and permit coordination.'
    projectEvidence=@('Residential additions');fitReasons=@('Complementary HVAC coordination')
    matchedServices=@('Residential HVAC design/inspection');fitScore=82;competitionRisk='low';priority='A'
    caslStatus='verify';sourceUrls=@('https://example.com/services','https://example.com/projects')
    subject='Coordination support for residential additions';emailBody="Hello Example Design team,`n`nAFZ introduction.`n`nUnsubscribe."
  }
  $lead=New-NormalizedProspect $candidate 'batch-1'
  Assert-True ($null -ne $lead) 'valid official-domain lead should normalize'
  Assert-True ($lead.fitScore -eq 82) 'fit score should be preserved'
  Assert-True (-not (Test-ProspectExcludedLocation $lead @('Brampton'))) 'eligible Toronto prospect should not match the Brampton exclusion'
  $lead.serviceAreas=@('Toronto','Brampton')
  Assert-True (Test-ProspectExcludedLocation $lead @('Brampton')) 'explicit Brampton service must trigger the hard exclusion'
  $lead.serviceAreas=@('Toronto','Markham')
  $store=New-ProspectStore;$store.leads=@($lead);Write-ProspectStore $store
  $loaded=Read-ProspectStore
  Assert-True (@($loaded.leads).Count -eq 1) 'lead should persist server-side'
  $loaded.leads[0].compliance.recipientVerified=$true
  $loaded.leads[0].compliance.lawfulBasisConfirmed=$true
  $loaded.leads[0].compliance.identityIncluded=$true
  $loaded.leads[0].compliance.unsubscribeIncluded=$true
  Assert-True (-not (Test-LeadReadyForOutlook $loaded.leads[0])) 'legacy lead must remain draft-blocked until its territory audit is clear'
  Set-ProspectExclusionAudit $loaded.leads[0] 'clear' 'Official service area excludes Brampton.' @('https://example.com/services') $luna
  Assert-True ((Get-ProspectExclusionAuditStatus $loaded.leads[0]) -eq 'clear') 'clear territory audit should be persisted on the lead'
  Assert-True (Test-LeadReadyForOutlook $loaded.leads[0]) 'complete preflight should open draft gate'
  Set-ProspectExclusionAudit $loaded.leads[0] 'inconclusive' 'No finite official service area was published.' @('https://example.com/services') $sol 'deep'
  Assert-True ([string]$loaded.leads[0].exclusionAudit.resolutionPass -eq 'deep') 'deep territory resolution should be recorded on the lead'
  Assert-True (-not (Test-LeadReadyForOutlook $loaded.leads[0])) 'deep-pass inconclusive lead must remain blocked from Outlook drafts'
  Set-ProspectExclusionAudit $loaded.leads[0] 'clear' 'Official service area excludes Brampton.' @('https://example.com/services') $luna
  $loaded.leads[0].websiteSummary='Residential design serving Toronto and Brampton.'
  Assert-True (-not (Test-LeadReadyForOutlook $loaded.leads[0])) 'Brampton-serving lead must remain blocked from Outlook drafts'
  $loaded.leads[0].websiteSummary='Residential addition design and permit coordination.'
  Set-ProspectExclusionAudit $loaded.leads[0] 'excluded' 'Official service area includes Brampton.' @('https://example.com/services') $luna
  Assert-True (Test-ProspectExcludedLocation $loaded.leads[0] @('Brampton')) 'excluded territory audit must quarantine the lead'
  Assert-True (-not (Test-LeadReadyForOutlook $loaded.leads[0])) 'excluded territory audit must block Outlook drafts'
  Set-ProspectExclusionAudit $loaded.leads[0] 'clear' 'Official service area excludes Brampton.' @('https://example.com/services') $luna
  $candidate.sourceUrls=@('https://example.com/services','https://different.example/projects')
  Assert-True ($null -eq (New-NormalizedProspect $candidate 'batch-2')) 'cross-domain evidence must be rejected'
  $request=[pscustomobject]@{Headers=@{Origin='https://attacker.example'};Url=[Uri]'http://127.0.0.1:8796/api/prospects/update'}
  $context=[pscustomobject]@{Request=$request}
  Assert-True (-not (Test-ProspectRequestOrigin $context)) 'cross-origin writes must be rejected'
  $request.Headers.Origin='http://127.0.0.1:8796'
  Assert-True (Test-ProspectRequestOrigin $context) 'same-origin writes should be accepted'
  $invalidAuditModeRejected=$false;try{Invoke-ProspectExclusionAuditBatch ([pscustomobject]@{model='sol';mode='unsafe-mode'})|Out-Null}catch{$invalidAuditModeRejected=$true}
  Assert-True $invalidAuditModeRejected 'unsupported territory-audit modes must be rejected'
  Write-Host 'AFZ Prospect Engine tests: PASS'
}finally{
  Remove-Item -LiteralPath $StateRoot -Recurse -Force -ErrorAction SilentlyContinue
}
