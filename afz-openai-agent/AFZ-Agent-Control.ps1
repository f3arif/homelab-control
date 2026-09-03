#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$Port=8797,
  [string]$BindHost='100.70.25.8'
)
$ErrorActionPreference='Stop'
$core=Join-Path $InstallRoot 'afz-openai-agent\AFZ-Agent-Control-Core.ps1'
$helper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-AFZ-Blog-GitMigration.ps1'
$request=Join-Path $InstallRoot 'afz-openai-agent\requests\afz-blog-git-migration.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-blog-git-migration'
$marker=Join-Path $stateRoot 'wrapper-request.json'
$h3RegistryHelper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Hermes-SessionRegistryRepair.ps1'
$h3RegistryRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-session-registry-repair.json'
$h3RegistryStateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-session-registry'
$h3RegistryMarker=Join-Path $h3RegistryStateRoot 'wrapper-request.json'
$h3RegistryAttempt=Join-Path $h3RegistryStateRoot 'wrapper-attempt.json'
$h3TelegramAuditHelper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Hermes-TelegramAttachmentAudit.ps1'
$h3TelegramAuditRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-telegram-attachment-audit.json'
$h3TelegramAuditStateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-telegram-attachment-audit'
$h3TelegramAuditMarker=Join-Path $h3TelegramAuditStateRoot 'wrapper-request.json'
$h3TelegramAuditAttempt=Join-Path $h3TelegramAuditStateRoot 'wrapper-attempt.json'
$h3GatewayReloadHelper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Hermes-GatewayReload.ps1'
$h3GatewayReloadRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-gateway-reload.json'
$h3GatewayReloadStateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-gateway-reload'
$h3GatewayReloadMarker=Join-Path $h3GatewayReloadStateRoot 'wrapper-request.json'
$h3GatewayReloadAttempt=Join-Path $h3GatewayReloadStateRoot 'wrapper-attempt.json'
$hpenvyWakeHelper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-HPEnvy-Wake.ps1'
$hpenvyWakeRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\hpenvy-wake.json'
$hpenvyWakeStateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\hpenvy-wake'
$hpenvyWakeAttempt=Join-Path $hpenvyWakeStateRoot 'wrapper-attempt.json'
$log='C:\ProgramData\AFZ\OpenAIAgent\logs\control-wrapper.log'
New-Item -ItemType Directory -Force -Path $stateRoot,$h3RegistryStateRoot,$h3TelegramAuditStateRoot,$h3GatewayReloadStateRoot,$hpenvyWakeStateRoot,(Split-Path $log -Parent)|Out-Null
function WLog([string]$m){try{Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) $m" -Encoding UTF8}catch{}}

# Fixed-target, idempotent HP Envy WOL hook. The helper accepts only the known HP Envy
# MAC/LAN target and records success by request id, so control restarts cannot loop WOL.
try{
  if((Test-Path -LiteralPath $hpenvyWakeRequest -PathType Leaf) -and (Test-Path -LiteralPath $hpenvyWakeHelper -PathType Leaf)){
    $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $hpenvyWakeHelper -InstallRoot $InstallRoot -RequestPath $hpenvyWakeRequest 2>&1|Out-String).Trim()
    $code=$LASTEXITCODE
    [ordered]@{attemptedAt=(Get-Date -Format o);exitCode=$code;output=$raw}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $hpenvyWakeAttempt -Encoding UTF8
    WLog "hpenvy wake hook exit=$code"
  }
}catch{WLog "hpenvy wake wrapper error=$($_.Exception.Message)"}

# Existing AFZ Blog migration one-shot binding.
try{
  if((Test-Path -LiteralPath $request -PathType Leaf) -and (Test-Path -LiteralPath $helper -PathType Leaf)){
    $r=Get-Content -LiteralPath $request -Raw -Encoding UTF8|ConvertFrom-Json
    $id=[string]$r.id;$enabled=[bool]$r.enabled;$action=([string]$r.action).Trim().ToLowerInvariant()
    $already=$false
    if(Test-Path -LiteralPath $marker -PathType Leaf){try{$m=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json;$already=([string]$m.id -eq $id)}catch{}}
    if($enabled -and $action -eq 'apply' -and $id -match '^afz-blog-git-migration-[A-Za-z0-9._-]+$' -and -not $already){
      WLog "blog migration request start id=$id"
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -Action apply -RequestId $id | Out-Null
      $code=$LASTEXITCODE
      [ordered]@{id=$id;attemptedAt=(Get-Date -Format o);exitCode=$code}|ConvertTo-Json|Set-Content -LiteralPath $marker -Encoding UTF8
      WLog "blog migration request finish id=$id exit=$code"
    }
  }
}catch{WLog "blog migration wrapper error=$($_.Exception.Message)"}

# Guarded one-shot H3 Hermes session-registry repair.
try{
  if((Test-Path -LiteralPath $h3RegistryRequest -PathType Leaf) -and (Test-Path -LiteralPath $h3RegistryHelper -PathType Leaf)){
    $r=Get-Content -LiteralPath $h3RegistryRequest -Raw -Encoding UTF8|ConvertFrom-Json
    $id=[string]$r.id;$enabled=[bool]$r.enabled;$action=([string]$r.action).Trim().ToLowerInvariant()
    $already=$false
    if(Test-Path -LiteralPath $h3RegistryMarker -PathType Leaf){try{$m=Get-Content -LiteralPath $h3RegistryMarker -Raw|ConvertFrom-Json;$already=([string]$m.id -eq $id -and [int]$m.exitCode -eq 0)}catch{}}
    if($enabled -and $action -eq 'repair-exact-empty-legacy-registry' -and $id -match '^h3-hermes-session-registry-repair-[A-Za-z0-9._-]+$' -and -not $already){
      WLog "h3 hermes registry request start id=$id"
      $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $h3RegistryHelper -InstallRoot $InstallRoot -RequestPath $h3RegistryRequest 2>&1|Out-String).Trim()
      $code=$LASTEXITCODE
      $attempt=[ordered]@{id=$id;attemptedAt=(Get-Date -Format o);exitCode=$code;output=$raw}
      $attempt|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $h3RegistryAttempt -Encoding UTF8
      if($code -eq 0){$attempt|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $h3RegistryMarker -Encoding UTF8}
      WLog "h3 hermes registry request finish id=$id exit=$code"
    }
  }
}catch{WLog "h3 hermes registry wrapper error=$($_.Exception.Message)"}

# Read-only one-shot Telegram attachment audit.
try{
  if((Test-Path -LiteralPath $h3TelegramAuditRequest -PathType Leaf) -and (Test-Path -LiteralPath $h3TelegramAuditHelper -PathType Leaf)){
    $r=Get-Content -LiteralPath $h3TelegramAuditRequest -Raw -Encoding UTF8|ConvertFrom-Json
    $id=[string]$r.id;$status=([string]$r.status).Trim().ToUpperInvariant();$action=([string]$r.action).Trim().ToLowerInvariant()
    $already=$false
    if(Test-Path -LiteralPath $h3TelegramAuditMarker -PathType Leaf){try{$m=Get-Content -LiteralPath $h3TelegramAuditMarker -Raw|ConvertFrom-Json;$already=([string]$m.id -eq $id -and [int]$m.exitCode -eq 0)}catch{}}
    if($status -eq 'ACTIVE' -and $action -eq 'audit-telegram-attachments' -and $id -match '^h3-hermes-telegram-attachment-audit-[A-Za-z0-9._-]+$' -and -not $already){
      WLog "h3 hermes telegram attachment audit start id=$id"
      $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $h3TelegramAuditHelper -InstallRoot $InstallRoot -RequestPath $h3TelegramAuditRequest 2>&1|Out-String).Trim()
      $code=$LASTEXITCODE
      $attempt=[ordered]@{id=$id;attemptedAt=(Get-Date -Format o);exitCode=$code;output=$raw}
      $attempt|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $h3TelegramAuditAttempt -Encoding UTF8
      if($code -eq 0){$attempt|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $h3TelegramAuditMarker -Encoding UTF8}
      WLog "h3 hermes telegram attachment audit finish id=$id exit=$code"
    }
  }
}catch{WLog "h3 hermes telegram attachment audit wrapper error=$($_.Exception.Message)"}

# Guarded one-shot native Hermes gateway reload. The helper itself refuses to
# restart unless Hermes strict-validates an empty active-session registry, and it
# uses only the upstream/native `hermes gateway restart` lifecycle command.
try{
  if((Test-Path -LiteralPath $h3GatewayReloadRequest -PathType Leaf) -and (Test-Path -LiteralPath $h3GatewayReloadHelper -PathType Leaf)){
    $r=Get-Content -LiteralPath $h3GatewayReloadRequest -Raw -Encoding UTF8|ConvertFrom-Json
    $id=[string]$r.id;$status=([string]$r.status).Trim().ToUpperInvariant();$action=([string]$r.action).Trim().ToLowerInvariant()
    $already=$false
    if(Test-Path -LiteralPath $h3GatewayReloadMarker -PathType Leaf){try{$m=Get-Content -LiteralPath $h3GatewayReloadMarker -Raw|ConvertFrom-Json;$already=([string]$m.id -eq $id -and [int]$m.exitCode -eq 0)}catch{}}
    if($status -eq 'ACTIVE' -and $action -eq 'reload-gateway-native' -and $id -match '^h3-hermes-gateway-reload-[A-Za-z0-9._-]+$' -and -not $already){
      WLog "h3 hermes native gateway reload start id=$id"
      $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $h3GatewayReloadHelper -InstallRoot $InstallRoot -RequestPath $h3GatewayReloadRequest 2>&1|Out-String).Trim()
      $code=$LASTEXITCODE
      $attempt=[ordered]@{id=$id;attemptedAt=(Get-Date -Format o);exitCode=$code;output=$raw}
      $attempt|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $h3GatewayReloadAttempt -Encoding UTF8
      if($code -eq 0){$attempt|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $h3GatewayReloadMarker -Encoding UTF8}
      WLog "h3 hermes native gateway reload finish id=$id exit=$code"
    }
  }
}catch{WLog "h3 hermes native gateway reload wrapper error=$($_.Exception.Message)"}

if(-not(Test-Path -LiteralPath $core -PathType Leaf)){throw "Preserved AFZ control core missing: $core"}
WLog 'launching preserved AFZ control core'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $core -InstallRoot $InstallRoot -Port $Port -BindHost $BindHost
exit $LASTEXITCODE
