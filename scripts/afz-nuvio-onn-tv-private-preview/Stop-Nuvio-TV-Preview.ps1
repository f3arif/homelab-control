param([switch]$Apply)
$ErrorActionPreference='Stop'
$stage='C:\AFZ\Nuvio-Setup-20260923\onn-tv-private-preview-20261011'
$serveBefore=Join-Path $stage 'tailscale-serve.before.json'
$receipt=Join-Path $stage 'preview-process.json'
$hostname='desktop-h3r6cqn.tailc9bb62.ts.net:18886'
if(-not(Test-Path -LiteralPath $serveBefore)){throw 'Original Tailscale configuration snapshot missing'}
$baseline=Get-Content -Raw $serveBefore|ConvertFrom-Json
$current=tailscale.exe serve status --json|ConvertFrom-Json
$preview=$current.Web.PSObject.Properties[$hostname]
if($preview -and $preview.Value.Handlers.'/'.Proxy -ne 'http://127.0.0.1:18786'){
  throw '18886 is no longer owned by this preview; refuse to remove it'
}
$listener=Get-NetTCPConnection -State Listen -LocalPort 18786 -ErrorAction SilentlyContinue|Where-Object {$_.LocalAddress -eq '127.0.0.1'}|Select-Object -First 1
$pidToStop=$null
if($listener){
  $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)"
  if(-not $proc -or $proc.CommandLine -notmatch 'uvicorn' -or
      $proc.CommandLine -notmatch 'preview_app:app' -or
      $proc.CommandLine -notmatch '18786'){
    throw 'Local preview port is not owned by the expected app; refuse to stop'
  }
  $pidToStop=$listener.OwningProcess
}
foreach($mapping in $baseline.Web.PSObject.Properties){
  $now=$current.Web.PSObject.Properties[$mapping.Name]
  if(-not $now -or ($mapping.Value|ConvertTo-Json -Compress -Depth 7) -ne
      ($now.Value|ConvertTo-Json -Compress -Depth 7)){
    throw ('Preexisting Serve route differs from original: '+$mapping.Name)
  }
}
Write-Output ('PREVIEW_OFF_GATE=PASS PORT_OWNER='+[string]$pidToStop+' PREVIEW_SERVE_CONFIGURED='+[bool]$preview)
if(-not $Apply){return}
if($preview){
  $out=tailscale.exe serve --https=18886 off 2>&1
  if($LASTEXITCODE -ne 0){throw ('Failed to remove ONLY preview Serve endpoint: '+($out|Out-String))}
  $after=tailscale.exe serve status --json|ConvertFrom-Json
  if($after.Web.PSObject.Properties[$hostname]){throw 'Preview Serve route still present'}
}
if($pidToStop){
  Stop-Process -Id $pidToStop -Force -ErrorAction Stop
  Start-Sleep -Seconds 1
}
$result=[ordered]@{
    completedUtc=(Get-Date).ToUniversalTime().ToString('o')
    previewServeRemoved=$true
    previewProcessStopped=($pidToStop -ne $null)
    originalServeRoutesPreserved=$true
    originalAddonUntouched=$true
    h3CatalogUntouched=$true
}
$path=Join-Path $stage 'preview-stopped.json'
[IO.File]::WriteAllText($path,($result|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
Write-Output ('PREVIEW_STOPPED='+$path)
