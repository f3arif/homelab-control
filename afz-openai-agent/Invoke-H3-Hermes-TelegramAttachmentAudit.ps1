#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0

if([string]::IsNullOrWhiteSpace($RequestPath)){
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-telegram-attachment-audit.json'
}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){
  throw "H3 Hermes Telegram attachment request missing: $RequestPath"
}

$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$req.id).Trim()
$action=([string]$req.action).Trim().ToLowerInvariant()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){
  throw 'Invalid Telegram attachment request identity.'
}
if($action -notin @('audit-telegram-attachments','audit-and-reload-telegram-gateway','audit-and-repair-telegram-tool-dispatch') -or [string]$req.status -ne 'ACTIVE'){
  throw 'Telegram attachment request is not active.'
}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){
  throw 'Telegram attachment target mismatch.'
}

$gatewayReloadMode=($action -eq 'audit-and-reload-telegram-gateway')
$toolDispatchMode=($action -eq 'audit-and-repair-telegram-tool-dispatch')
$repairMode=($gatewayReloadMode -or $toolDispatchMode)
if([bool]$req.change_network){
  throw 'Telegram attachment request forbidden network mutation flag.'
}
if($toolDispatchMode){
  if(-not [bool]$req.restart_gateway -or [bool]$req.read_only -or -not [bool]$req.repair_tool_dispatch -or -not [bool]$req.change_config){
    throw 'Telegram tool-dispatch repair mode guard mismatch.'
  }
}elseif($gatewayReloadMode){
  if(-not [bool]$req.restart_gateway -or [bool]$req.read_only -or [bool]$req.change_config){
    throw 'Telegram gateway reload mode guard mismatch.'
  }
}else{
  if(-not [bool]$req.read_only -or [bool]$req.restart_gateway -or [bool]$req.change_config){
    throw 'Telegram attachment audit safety flags mismatch.'
  }
}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-telegram-attachment-audit'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-TELEGRAM-ATTACHMENT-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
foreach($required in @($key,$known,$ssh)){
  if(-not(Test-Path -LiteralPath $required -PathType Leaf)){
    throw "Required H3 Telegram path missing: $required"
  }
}

# Static-only inspection. Never returns Telegram token values, message bodies,
# attachment contents, or attachment filenames.
$remote=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
function Emit($o,[int]$code){
  $o | ConvertTo-Json -Depth 12 -Compress
  exit $code
}
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){
  Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_AUDIT_WRONG_HOST';host=$env:COMPUTERNAME}) 30
}
$root=Join-Path $env:LOCALAPPDATA 'hermes'
$source=Join-Path $root 'hermes-agent'
$candidates=@(
  (Join-Path $source 'plugins\platforms\telegram\adapter.py'),
  (Join-Path $source 'gateway\platforms\telegram.py'),
  (Join-Path $source 'venv\Lib\site-packages\plugins\platforms\telegram\adapter.py')
)
$adapter=$candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if(-not $adapter){
  Emit ([ordered]@{
    ok=$true
    classification='HERMES_TELEGRAM_ADAPTER_NOT_FOUND'
    host=$env:COMPUTERNAME
    readOnly=$true
    sourceRoot=$source
  }) 0
}
$text=[IO.File]::ReadAllText($adapter)
$item=Get-Item -LiteralPath $adapter
$features=[ordered]@{
  hasMediaHandler=($text -match '_handle_media_message')
  handlesDocument=(($text -match 'MessageType[.]DOCUMENT') -and ($text -match '[.]document'))
  registersDocumentOrAttachmentFilter=($text -match 'filters[.](Document|DOCUMENT|ATTACHMENT)')
  downloadsTelegramFile=($text -match 'download_as_bytearray|download_to_drive|get_file')
  injectsTextDocumentContent=($text -match [regex]::Escape('[Content of '))
  hasDownloadFailureNotice=($text -match "Couldn't download|could not be downloaded|download failed")
  referencesDocumentCache=($text -match 'DOCUMENT_CACHE_DIR|cache_document')
}
$runPath=Join-Path $source 'gateway\run.py'
$runSignals=$null
if(Test-Path -LiteralPath $runPath -PathType Leaf){
  $rt=[IO.File]::ReadAllText($runPath)
  $runSignals=[ordered]@{
    handlesDocument=($rt -match 'MessageType[.]DOCUMENT')
    referencesMediaUrls=($rt -match 'media_urls')
    referencesLocalPath=($rt -match 'local.*path|file.*path|path.*document')
    sha256=(Get-FileHash -LiteralPath $runPath -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}
$classification='HERMES_TELEGRAM_ATTACHMENT_HANDLER_PRESENT'
if(-not $features.handlesDocument){
  $classification='HERMES_TELEGRAM_INSTALLED_HANDLER_LACKS_DOCUMENT_SUPPORT'
}elseif(-not $features.downloadsTelegramFile){
  $classification='HERMES_TELEGRAM_INSTALLED_HANDLER_LACKS_FILE_DOWNLOAD'
}elseif(-not $features.hasDownloadFailureNotice){
  $classification='HERMES_TELEGRAM_HANDLER_PRE_FAILURE_NOTICE_GENERATION'
}elseif($runSignals -and -not $runSignals.handlesDocument){
  $classification='HERMES_GATEWAY_RUN_LACKS_DOCUMENT_CONTEXT_ROUTE'
}
Emit ([ordered]@{
  ok=$true
  classification=$classification
  host=$env:COMPUTERNAME
  readOnly=$true
  sourceRoot=$source
  adapterPath=$adapter
  adapterSha256=(Get-FileHash -LiteralPath $adapter -Algorithm SHA256).Hash.ToLowerInvariant()
  adapterSizeBytes=[int64]$item.Length
  features=$features
  gatewayRun=$runSignals
  gatewayRestarted=$false
  configChanged=$false
  networkChanged=$false
}) 0
'@

$bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 Telegram audit stdin empty.''};Invoke-Expression $script'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))

function Invoke-H3 {
  param(
    [string]$Target,
    [string]$Transport,
    [string[]]$Extra
  )
  $inFile=Join-Path $env:TEMP ('h3-tg-audit-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('h3-tg-audit-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('h3-tg-audit-'+[guid]::NewGuid().ToString('n')+'.err')
  $args=@(
    '-i',$key,
    '-o','IdentitiesOnly=yes',
    '-o','BatchMode=yes',
    '-o','ConnectTimeout=6',
    '-o','StrictHostKeyChecking=yes',
    '-o',('UserKnownHostsFile='+$known)
  )
  if($Extra){$args+=@($Extra)}
  $args+=@($Target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  try{
    [IO.File]::WriteAllText($inFile,$remote,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(25000)){
      try{$p.Kill()}catch{}
      return [pscustomobject]@{ok=$false;classification='HERMES_TELEGRAM_AUDIT_REMOTE_TIMEOUT';transport=$Transport}
    }
    $stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
    $stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
    $parsed=$null
    foreach($line in @($stdout -split "`r?`n" | Where-Object { $_ })){
      try{$parsed=$line | ConvertFrom-Json}catch{}
    }
    if($parsed){
      $parsed | Add-Member transport $Transport -Force
      return $parsed
    }
    return [pscustomobject]@{
      ok=$false
      classification='HERMES_TELEGRAM_AUDIT_INVALID_REMOTE_RESULT'
      transport=$Transport
      errorType=$(if($stderr){'SSH_OR_REMOTE_ERROR'}else{'INVALID_JSON'})
    }
  }finally{
    Remove-Item $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue
  }
}

$result=Invoke-H3 -Target 'Faiz@100.106.186.118' -Transport 'tailscale' -Extra @()
if(-not [bool]$result.ok -and [string]$result.classification -in @('HERMES_TELEGRAM_AUDIT_REMOTE_TIMEOUT','HERMES_TELEGRAM_AUDIT_INVALID_REMOTE_RESULT')){
  $result=Invoke-H3 -Target 'Faiz@192.168.50.185' -Transport 'lan-hostkey-alias' -Extra @('-o','HostKeyAlias=100.106.186.118')
}

$repairResult=$null
$gatewayReloadResult=$null
$toolDispatchResult=$null
if($repairMode -and [bool]$result.ok -and [string]$result.classification -eq 'HERMES_TELEGRAM_ATTACHMENT_HANDLER_PRESENT'){
  if($toolDispatchMode){
    $repairHelper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Hermes-ToolDispatchRepair.ps1'
    $repairRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-tool-dispatch-repair.json'
    if((Test-Path -LiteralPath $repairHelper -PathType Leaf) -and (Test-Path -LiteralPath $repairRequest -PathType Leaf)){
      $rawRepair=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $repairHelper -InstallRoot $InstallRoot -RequestPath $repairRequest 2>&1 | Out-String).Trim()
      $repairCode=$LASTEXITCODE
      foreach($line in @($rawRepair -split "`r?`n" | Where-Object { $_ })){
        try{$toolDispatchResult=$line | ConvertFrom-Json}catch{}
      }
      if($null -eq $toolDispatchResult){
        $toolDispatchResult=[pscustomobject]@{ok=$false;classification='HERMES_TOOL_DISPATCH_REPAIR_RESULT_UNPARSEABLE';exit=$repairCode}
      }
      $repairResult=$toolDispatchResult
    }else{
      $toolDispatchResult=[pscustomobject]@{ok=$false;classification='HERMES_TOOL_DISPATCH_REPAIR_HELPER_OR_REQUEST_MISSING'}
      $repairResult=$toolDispatchResult
    }
  }else{
    $reloadHelper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Hermes-GatewayReload.ps1'
    $reloadRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-gateway-reload.json'
    if((Test-Path -LiteralPath $reloadHelper -PathType Leaf) -and (Test-Path -LiteralPath $reloadRequest -PathType Leaf)){
      $rawReload=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $reloadHelper -InstallRoot $InstallRoot -RequestPath $reloadRequest 2>&1 | Out-String).Trim()
      $reloadCode=$LASTEXITCODE
      foreach($line in @($rawReload -split "`r?`n" | Where-Object { $_ })){
        try{$gatewayReloadResult=$line | ConvertFrom-Json}catch{}
      }
      if($null -eq $gatewayReloadResult){
        $gatewayReloadResult=[pscustomobject]@{ok=$false;classification='HERMES_GATEWAY_RELOAD_RESULT_UNPARSEABLE';exit=$reloadCode}
      }
      $repairResult=$gatewayReloadResult
    }else{
      $gatewayReloadResult=[pscustomobject]@{ok=$false;classification='HERMES_GATEWAY_RELOAD_HELPER_OR_REQUEST_MISSING'}
      $repairResult=$gatewayReloadResult
    }
  }
}

$combined=[ordered]@{
  ok=([bool]$result.ok -and (-not $repairMode -or ($repairResult -and [bool]$repairResult.ok)))
  classification=$(if($repairMode -and $repairResult){[string]$repairResult.classification}else{[string]$result.classification})
  audit=$result
  toolDispatchRepair=$toolDispatchResult
  gatewayReload=$gatewayReloadResult
  repairMode=$repairMode
  toolDispatchMode=$toolDispatchMode
  observedAt=(Get-Date -Format o)
}
$json=$combined | ConvertTo-Json -Depth 30
[IO.File]::WriteAllText($statePath,$json,$utf8)
try{
  if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$json,$utf8)}
}catch{}
Write-Output ($combined | ConvertTo-Json -Depth 30 -Compress)
exit $(if([bool]$combined.ok){0}else{1})
