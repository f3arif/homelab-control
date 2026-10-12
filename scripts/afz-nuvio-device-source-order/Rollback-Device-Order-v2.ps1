param([switch]$Apply)
$ErrorActionPreference='Stop'
$serve='C:\Program Files\Tailscale\tailscale.exe'
$root='desktop-h3r6cqn.tailc9bb62.ts.net:8445'
$path='/stream/movie'
$original='http://127.0.0.1:18774'
$v1='http://127.0.0.1:18789'
$v2='http://127.0.0.1:18792'
$taskV1='AFZ Nuvio Device Sort Guard'
$taskV2='AFZ Nuvio Device Sort V2 Guard'
$stage='C:\AFZ\Nuvio-Setup-20260923\device-source-order-20261012'
$state=(Get-Content -Raw (Join-Path $stage 'v2-staging.json')|ConvertFrom-Json)
if($state.v2_candidate_sha -ne '1c144432e242c42027eb00dc8841aeb9c5f3930863ea434de326829e447ac3be'){
  throw 'Unexpected V2 candidate checkpoint'
}
$serveJson=& $serve serve status --json
if($LASTEXITCODE -ne 0){throw 'Cannot inspect Tailscale Serve safely'}
$serveState=$serveJson|ConvertFrom-Json
$entry=$serveState.Web.PSObject.Properties[$root]
if(-not $entry -or $entry.Value.Handlers.'/'.Proxy -ne $original){
  throw 'Production root mapping changed; refusing rollback'
}
$current=$entry.Value.Handlers.$path.Proxy
if($current -notin @($v1,$v2)){throw 'Source-list route is not owned by V1/V2'}
Write-Output ('V2_ROLLBACK_CHECK=PASS CURRENT='+$current)
if(-not $Apply){Write-Output 'NO_CHANGE_DRY_RUN';return}
if($current -eq $v2){
  $h=Invoke-RestMethod 'http://127.0.0.1:18789/health' -TimeoutSec 4
  if(-not($h.ok -and $h.policy -eq 'phone-first-v1')){
    throw 'Previous V1 sorter unavailable; leave config unchanged for manual repair'
  }
  $output=& $serve serve --bg --https=8445 --set-path=/stream/movie $v1 2>&1
  if($LASTEXITCODE -ne 0){throw ('V1 route restoration failed: '+($output|Out-String))}
}
$after=(& $serve serve status --json|ConvertFrom-Json).Web.PSObject.Properties[$root].Value.Handlers
if($after.'/'.Proxy -ne $original -or $after.$path.Proxy -ne $v1){
  throw 'V1 rollback not verified'
}
Disable-ScheduledTask -TaskName $taskV2 -ErrorAction Stop|Out-Null
Enable-ScheduledTask -TaskName $taskV1 -ErrorAction Stop|Out-Null
$result=[ordered]@{
   verifiedUtc=(Get-Date).ToUniversalTime().ToString('o')
   sourceStreamRoute=$v1
   originalMediaRouteUnchanged=$true
   v1GuardEnabled=$true
   v2GuardDisabled=$true
}
[IO.File]::WriteAllText((Join-Path $stage 'v2-rollback-result.json'),
  ($result|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
Write-Output 'V2_ROLLBACK=VERIFIED_V1_RESTORED'
