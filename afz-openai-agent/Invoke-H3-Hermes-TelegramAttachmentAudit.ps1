#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0

if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-telegram-attachment-audit.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Hermes Telegram attachment request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim();$action=([string]$req.action).Trim().ToLowerInvariant()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid Telegram attachment request identity.'}
if($action -notin @('audit-telegram-attachments','audit-and-reload-telegram-gateway') -or [string]$req.status -ne 'ACTIVE'){throw 'Telegram attachment request is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'Telegram attachment target mismatch.'}
$repairMode=($action -eq 'audit-and-reload-telegram-gateway')
if([bool]$req.change_config -or [bool]$req.change_network){throw 'Telegram attachment request forbidden mutation flag.'}
if($repairMode){if(-[bool]$req.restart_gateway -or [bool]$req.read_only){throw 'Telegram gateway reload mode guard mismatch.'}}
else{if(-not [bool]$req.read_only -or [bool]$req.restart_gateway){throw 'Telegram attachment audit safety flags mismatch.'}}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-telegram-attachment-audit'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-TELEGRAM-ATTACHMENT-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
foreach($required in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "Required H3 Telegram path missing: $required"}}

# Bounded static inspection: no Telegram token/message/file contents are returned.
$remote=@'
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';Set-StrictMode -Version 2.0
function Emit($o,[int]$code){$o|ConvertTo-Json -Depth 12 -Compress;exit $code}
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_AUDIT_WRONG_HOST';host=$env:COMPUTERNAME}) 30}
$root=Join-Path $env:LOCALAPPDATA 'hermes';$source=Join-Path $root 'hermes-agent'
$candidates=@((Join-Path $source 'plugins\platforms\telegram\adapter.py'),(Join-Path $source 'gateway\platforms\telegram.py'),(Join-Path $source 'venv\Lib\site-packages\plugins\platforms\telegram\adapter.py'))
$adapter=$candidates|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1
if(-not $adapter){Emit ([ordered]@{ok=$true;classification='HERMES_TELEGRAM_ADAPTER_NOT_FOUND';host=$env:COMPUTERNAME;readOnly=$true;sourceRoot=$source}) 0}
$text=[IO.File]::ReadAllText($adapter);$item=Get-Item -LiteralPath $adapter
$features=[ordered]@{
 hasMediaHandler=($text -match '_handle_media_message');handlesDocument=(($text -match 'MessageType[.]DOCUMENT') -and ($text -match '[.]document'))
 registersDocumentOrAttachmentFilter=($text -match 'filters[.](Document|DOCUMENT|ATTACHMENT)');downloadsTelegramFile=($text -match 'download_as_bytearray|download_to_drive|get_file')
 injectsTextDocumentContent=($text -match [regex]::Escape('[Content of '));hasDownloadFailureNotice=($text -match "Couldn't download|could not be downloaded|download failed")
 referencesDocumentCache=($text -match 'DOCUMENT_CACHE_DIR|cache_document')
}
$runPath=Join-Path $source 'gateway\run.py';$runSignals=$null
if(Test-Path -LiteralPath $runPath -PathType Leaf){$rt=[IO.File]::ReadAllText($runPath);$runSignals=[ordered]@{handlesDocument=($rt -match 'MessageType[.]DOCUMENT');referencesMediaUrls=($rt -match 'media_urls');referencesLocalPath=($rt -match 'local.*path|file.*path|path.*document');sha256=(Get-FileHash -LiteralPath $runPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
$classification='HERMES_TELEGRAM_ATTACHMENT_HANDLER_PRESENT'
if(-not $features.handlesDocument){$classification='HERMES_TELEGRAM_INSTALLED_HANDLER_LACKS_DOCUMENT_SUPPORT'}elseif(-not $features.downloadsTelegramFile){$classification='HERMES_TELEGRAM_INSTALLED_HANDLER_LACKS_FILE_DOWNLOAD'}elseif(-not $features.hasDownloadFailureNotice){$classification='HERMES_TELEGRAM_HANDLER_PRE_FAILURE_NOTICE_GENERATION'}elseif($runSignals -and -not $runSignals.handlesDocument){$classification='HERMES_GATEWAY_RUN_LACKS_DOCUMENT_CONTEXT_ROUTE'}
Emit ([ordered]@{ok=$true;classification=$classification;host=$env:COMPUTERNAME;readOnly=$true;sourceRoot=$source;adapterPath=$adapter;adapterSha256=(Get-FileHash -LiteralPath $adapter -Algorithm SHA256).Hash.ToLowerInvariant();adapterSizeBytes=[int64]$item.Length;features=$features;gatewayRun=$runSignals;gatewayRestarted=$false;configChanged=$false;networkChanged=$false}) 0
'@
$bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 Telegram audit stdin empty.''};Invoke-Expression $script'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
function Invoke-H3([string]$target,[string]$transport,[string[]]$extra){
  $in=Join-Path $env:TEMP ('h3-tg-audit-'+[guid]::NewGuid().ToString('n')+'.ps1');$out=Join-Path $env:TEMP ('h3-tg-audit-'+[guid]::NewGuid().ToString('n')+'.out');$err=Join-Path $env:TEMP ('h3-tg-audit-'+[guid]::NewGuid().ToString('n')+'.err')
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=6','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known));if($extra){$args+=@($extra)};$args+=@($target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  try{[IO.File]::WriteAllText($in,$remote,$utf8);$p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $in -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden;if(-not $p.WaitForExit(25000)){try{$p.Kill()}catch{};return [pscustomobject]@{ok=$false;classification='HERMES_TELEGRAM_AUDIT_REMOTE_TIMEOUT';transport=$transport}};$stdout=$(if(Test-Path $out){[IO.File]::ReadAllText($out).Trim()}else{''});$stderr=$(if(Test-Path $err){[IO.File]::ReadAllText($err).Trim()}else{''});$parsed=$null;foreach($line in @($stdout -split "`r?`n"|Where-Object{$_})){try{$parsed=$line|ConvertFrom-Json}catch{}};if($parsed){$parsed|Add-Member transport $transport -Force;return $parsed};return [pscustomobject]@{ok=$false;classification='HERMES_TELEGRAM_AUDIT_INVALID_REMOTE_RESULT';transport=$transport;errorType=$(if($stderr){'SSH_OR_REMOTE_ERROR'}else{'INVALID_JSON'})}}finally{Remove-Item $in,$out,$err -Force -ErrorAction SilentlyContinue}}
}
$result=Invoke-H3 'Faiz@100.106.186.118' 'tailscale' @()
if(-not [bool]$result.ok -and [string]$result.classification -in @('HERMES_TELEGRAM_AUDIT_REMOTE_TIMEOUT','HERMES_TELEGRAM_AUDIT_INVALID_REMOTE_RESULT')){$result=Invoke-H3 'Faiz@192.168.50.185' 'lan-hostkey-alias' @('-o','HostKeyAlias=100.106.186.118')}

$reloadResult=$null
if($repairMode -and [bool]$result.ok -and [string]$result.classification -eq 'HERMES_TELEGRAM_ATTACHMENT_HANDLER_PRESENT'){
  $reloadHelper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Hermes-GatewayReload.ps1';$reloadRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-gateway-reload.json'
  if((Test-Path -LiteralPath $reloadHelper -PathType Leaf) -and (Test-Path -LiteralPath $reloadRequest -PathType Leaf)){
    $rawReload=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $reloadHelper -InstallRoot $InstallRoot -RequestPath $reloadRequest 2>&1|Out-String).Trim();$reloadCode=$LASTEXITCODE
    foreach($line in @($rawReload -split "`r?`n"|Where-Object{$_})){try{$reloadResult=$line|ConvertFrom-Json}catch{}}
    if($null -eq $reloadResult){$reloadResult=[pscustomobject]@{ok=$false;classification='HERMES_GATEWAY_RELOAD_RESULT_UNPARSEABLE';exit=$reloadCode}}
  }else{$reloadResult=[pscustomobject]@{ok=$false;classification='HERMES_GATEWAY_RELOAD_HELPER_OR_REQUEST_MISSING'}}
}
$combined=[ordered]@{ok=([bool]$result.ok -and (-not $repairMode -or ($reloadResult -and [bool]$reloadResult.ok)));classification=$(if($repairMode -and $reloadResult){[string]$reloadResult.classification}else{[string]$result.classification});audit=$result;gatewayReload=$reloadResult;repairMode=$repairMode;observedAt=(Get-Date -Format o)}
$json=$combined|ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($statePath,$json,$utf8);try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$json,$utf8)}}catch{}
Write-Output ($combined|ConvertTo-Json -Depth 20 -Compress);exit $(if([bool]$combined.ok){0}else{1})
