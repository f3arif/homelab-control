#Requires -Version 7.0
$ErrorActionPreference='Stop'
$StateRoot=Join-Path ([IO.Path]::GetTempPath()) ('afz-prospect-test-'+[guid]::NewGuid().ToString('n'))
$AgentRoot=Split-Path -Parent $PSScriptRoot
$ModelSol='test-sol'

function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERTION FAILED: $Message"}}

try{
  . (Join-Path $PSScriptRoot 'ProspectEngine.ps1')
  $candidate=[pscustomobject]@{
    id='lead-1';company='Example Design';category='BCIN designers';city='Toronto'
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
  $store=New-ProspectStore;$store.leads=@($lead);Write-ProspectStore $store
  $loaded=Read-ProspectStore
  Assert-True (@($loaded.leads).Count -eq 1) 'lead should persist server-side'
  $loaded.leads[0].compliance.recipientVerified=$true
  $loaded.leads[0].compliance.lawfulBasisConfirmed=$true
  $loaded.leads[0].compliance.identityIncluded=$true
  $loaded.leads[0].compliance.unsubscribeIncluded=$true
  Assert-True (Test-LeadReadyForOutlook $loaded.leads[0]) 'complete preflight should open draft gate'
  $candidate.sourceUrls=@('https://example.com/services','https://different.example/projects')
  Assert-True ($null -eq (New-NormalizedProspect $candidate 'batch-2')) 'cross-domain evidence must be rejected'
  $request=[pscustomobject]@{Headers=@{Origin='https://attacker.example'};Url=[Uri]'http://127.0.0.1:8796/api/prospects/update'}
  $context=[pscustomobject]@{Request=$request}
  Assert-True (-not (Test-ProspectRequestOrigin $context)) 'cross-origin writes must be rejected'
  $request.Headers.Origin='http://127.0.0.1:8796'
  Assert-True (Test-ProspectRequestOrigin $context) 'same-origin writes should be accepted'
  Write-Host 'AFZ Prospect Engine tests: PASS'
}finally{
  Remove-Item -LiteralPath $StateRoot -Recurse -Force -ErrorAction SilentlyContinue
}
