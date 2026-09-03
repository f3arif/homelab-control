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
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-telegram-followup-repair.json'
}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Telegram follow-up repair request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid H3 Telegram follow-up repair identity.'}
if([string]$req.action -ne 'repair-telegram-document-followup' -or [string]$req.status -ne 'ACTIVE'){throw 'H3 Telegram follow-up repair is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'H3 Telegram follow-up target mismatch.'}
$expectedSha=([string]$req.expected_adapter_sha256).Trim().ToLowerInvariant()
if($expectedSha -notmatch '^[0-9a-f]{64}$'){throw 'H3 Telegram follow-up expected adapter hash invalid.'}
$delay=[double]$req.followup_delay_seconds
if($delay -lt 2.0 -or $delay -gt 15.0){throw 'H3 Telegram follow-up delay outside guarded range.'}
if(-not [bool]$req.restart_gateway -or [bool]$req.change_config -or [bool]$req.change_provider -or [bool]$req.mutate_ollama -or [bool]$req.change_network -or [bool]$req.run_model_generation){throw 'H3 Telegram follow-up safety guard mismatch.'}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-telegram-followup'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-TELEGRAM-FOLLOWUP-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required H3 Telegram follow-up path missing: $p"}}

function Save-Result($o){
  $j=$o | ConvertTo-Json -Depth 30
  [IO.File]::WriteAllText($statePath,$j,$utf8)
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$j,$utf8)}}catch{}
  Write-Output ($o | ConvertTo-Json -Depth 30 -Compress)
}

function Invoke-RemoteScript([string]$Script,[int]$TimeoutMs){
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''stdin empty''};Invoke-Expression $script'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $inFile=Join-Path $env:TEMP ('h3-tg-followup-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('h3-tg-followup-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('h3-tg-followup-'+[guid]::NewGuid().ToString('n')+'.err')
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=7','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),'Faiz@100.106.186.118','powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  try{
    [IO.File]::WriteAllText($inFile,$Script,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    $timedOut=(-not $p.WaitForExit($TimeoutMs))
    if($timedOut){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{}}
    $stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
    $stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
    $parsed=$null
    foreach($line in @($stdout -split "`r?`n" | Where-Object{$_})){try{$parsed=$line | ConvertFrom-Json}catch{}}
    if($parsed){$parsed | Add-Member transport 'tailscale' -Force;return $parsed}
    return [pscustomobject]@{ok=$false;classification=$(if($timedOut){'HERMES_TELEGRAM_FOLLOWUP_REMOTE_TIMEOUT'}else{'HERMES_TELEGRAM_FOLLOWUP_INVALID_REMOTE_RESULT'});transport='tailscale';timedOut=$timedOut;exit=$(if($timedOut){$null}else{[int]$p.ExitCode});stderrPresent=(-not [string]::IsNullOrWhiteSpace($stderr))}
  }finally{Remove-Item $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}

$delayLiteral=$delay.ToString('0.0############',[Globalization.CultureInfo]::InvariantCulture)
$patchPy=@'
from pathlib import Path
import os, sys
p=Path(sys.argv[1])
expected=sys.argv[2].lower()
delay=sys.argv[3]
text=p.read_text(encoding='utf-8')
markers=(
    'HERMES_TELEGRAM_DOCUMENT_FOLLOWUP_DELAY_SECONDS',
    '_document_followup_pending',
    "not (getattr(msg, \"caption\", None) or \"\").strip()",
)
if all(m in text for m in markers):
    compile(text, str(p), 'exec')
    print('ALREADY_PATCHED')
    raise SystemExit(0)
import hashlib
actual=hashlib.sha256(p.read_bytes()).hexdigest().lower()
if actual != expected:
    print('ADAPTER_HASH_MISMATCH:'+actual)
    raise SystemExit(21)
old1='''        self._text_batch_split_delay_seconds = self._env_float_clamped(\n            "HERMES_TELEGRAM_TEXT_BATCH_SPLIT_DELAY_SECONDS",\n            1.0,\n            min_value=self._text_batch_delay_seconds,\n            max_value=4.0,\n        )\n        self._pending_text_batches: Dict[str, MessageEvent] = {}'''
new1='''        self._text_batch_split_delay_seconds = self._env_float_clamped(\n            "HERMES_TELEGRAM_TEXT_BATCH_SPLIT_DELAY_SECONDS",\n            1.0,\n            min_value=self._text_batch_delay_seconds,\n            max_value=4.0,\n        )\n        # Hold an attachment-only document briefly so a human's immediately\n        # following instruction becomes the same DOCUMENT turn instead of\n        # interrupting a file-only agent run.\n        self._document_followup_delay_seconds = self._env_float_clamped(\n            "HERMES_TELEGRAM_DOCUMENT_FOLLOWUP_DELAY_SECONDS",\n            DELAY,\n            min_value=self._text_batch_delay_seconds,\n            max_value=15.0,\n        )\n        self._pending_text_batches: Dict[str, MessageEvent] = {}'''.replace('DELAY', delay)
old2='''            existing._last_chunk_len = chunk_len  # type: ignore[attr-defined]\n            # Merge any media that might be attached'''
new2='''            existing._last_chunk_len = chunk_len  # type: ignore[attr-defined]\n            if event.text and getattr(existing, "_document_followup_pending", False):\n                existing._document_followup_pending = False  # type: ignore[attr-defined]\n            # Merge any media that might be attached'''
old3='''            total_len = len(getattr(pending, "text", "") or "") if pending else 0\n            if last_len >= self._SPLIT_THRESHOLD:\n                delay = self._text_batch_split_delay_seconds'''
new3='''            total_len = len(getattr(pending, "text", "") or "") if pending else 0\n            if getattr(pending, "_document_followup_pending", False):\n                delay = self._document_followup_delay_seconds\n            elif last_len >= self._SPLIT_THRESHOLD:\n                delay = self._text_batch_split_delay_seconds'''
old4='''        media_group_id = getattr(msg, "media_group_id", None)\n        if media_group_id:\n            await self._queue_media_group_event(str(media_group_id), event)\n            return\n\n        await self.handle_message(event)'''
new4='''        media_group_id = getattr(msg, "media_group_id", None)\n        if media_group_id:\n            await self._queue_media_group_event(str(media_group_id), event)\n            return\n\n        # A PDF/document sent without a caption is commonly followed by a text\n        # instruction as the next Telegram message. Reuse the existing text\n        # batch so the media path and that instruction stay in one DOCUMENT\n        # event; flush normally after the bounded follow-up window if no text\n        # arrives. Captioned documents keep the immediate path.\n        if (\n            event.message_type == MessageType.DOCUMENT\n            and event.media_urls\n            and not (getattr(msg, "caption", None) or "").strip()\n        ):\n            event._document_followup_pending = True  # type: ignore[attr-defined]\n            self._enqueue_text_event(event)\n            return\n\n        await self.handle_message(event)'''
for old,new,name in ((old1,new1,'init'),(old2,new2,'merge'),(old3,new3,'delay'),(old4,new4,'dispatch')):
    if text.count(old)!=1:
        print('PATCH_MARKER_MISMATCH:'+name+':'+str(text.count(old)))
        raise SystemExit(22)
    text=text.replace(old,new,1)
compile(text, str(p), 'exec')
tmp=p.with_suffix(p.suffix+'.afz-new')
tmp.write_text(text,encoding='utf-8',newline='')
os.replace(tmp,p)
print('PATCHED')
'@
$canaryPy=@'
import asyncio
from unittest.mock import AsyncMock
from gateway.config import Platform, PlatformConfig
from gateway.platforms.base import MessageEvent, MessageType, SessionSource
from plugins.platforms.telegram.adapter import TelegramAdapter

def event(text, typ):
    return MessageEvent(text=text, message_type=typ, source=SessionSource(platform=Platform.TELEGRAM, chat_id='12345', chat_type='dm'))

def adapter():
    a=object.__new__(TelegramAdapter)
    a._platform=Platform.TELEGRAM; a.platform=Platform.TELEGRAM
    a.config=PlatformConfig(enabled=True, token='test-token')
    a._running=True; a._fatal_error_code=None; a._fatal_error_message=None; a._fatal_error_retryable=True
    a._drop_delayed_deliveries=False
    a._pending_text_batches={}; a._pending_text_batch_tasks={}
    a._pending_photo_batches={}; a._pending_photo_batch_tasks={}
    a._media_group_events={}; a._media_group_tasks={}
    a._polling_error_task=None; a._polling_heartbeat_task=None; a._app=None; a._bot=None
    a._held_inbound_events=[]; a._held_inbound_redispatch_task=None; a.HELD_INBOUND_MAX=64
    a._text_batch_delay_seconds=0.10; a._text_batch_split_delay_seconds=0.30
    a._document_followup_delay_seconds=0.40
    a._TEXT_BATCH_FAST_DELAY_S=0.05; a._TEXT_BATCH_SHORT_DELAY_S=0.05
    a._TEXT_BATCH_FAST_LEN=320; a._TEXT_BATCH_SHORT_LEN=1024; a._SPLIT_THRESHOLD=4000
    a.handle_message=AsyncMock()
    return a

async def main():
    a=adapter()
    d=event('', MessageType.DOCUMENT)
    d.media_urls=[r'C:\\tmp\\sample.pdf']; d.media_types=['application/pdf']
    d._document_followup_pending=True
    a._enqueue_text_event(d)
    await asyncio.sleep(0.12)
    assert a.handle_message.call_count==0, 'document flushed before follow-up window'
    t=event('Read this PDF and summarize it in 3 bullets.', MessageType.TEXT)
    a._enqueue_text_event(t)
    await asyncio.sleep(0.18)
    assert a.handle_message.call_count==1, 'combined turn did not flush exactly once'
    got=a.handle_message.call_args[0][0]
    assert got.message_type==MessageType.DOCUMENT, 'document type lost'
    assert 'summarize it in 3 bullets' in (got.text or ''), 'instruction not merged'
    assert got.media_urls==[r'C:\\tmp\\sample.pdf'], 'document path lost'
    assert not getattr(got,'_document_followup_pending',False), 'follow-up flag not consumed'
    print('FOLLOWUP_CANARY_PASS')

asyncio.run(main())
'@
$patchB64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patchPy))
$canaryB64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($canaryPy))

$remote=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
function Emit($o,[int]$code){$o|ConvertTo-Json -Depth 20 -Compress;exit $code}
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_FOLLOWUP_WRONG_HOST';mutation='NONE'}) 30}
$root=Join-Path $env:LOCALAPPDATA 'hermes'
$source=Join-Path $root 'hermes-agent'
$adapter=Join-Path $source 'plugins\platforms\telegram\adapter.py'
$python=Join-Path $source 'venv\Scripts\python.exe'
if(-not(Test-Path -LiteralPath $adapter -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_FOLLOWUP_ADAPTER_MISSING';mutation='NONE'}) 41}
if(-not(Test-Path -LiteralPath $python -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_FOLLOWUP_PYTHON_MISSING';mutation='NONE'}) 42}
$before=(Get-FileHash -LiteralPath $adapter -Algorithm SHA256).Hash.ToLowerInvariant()
$text=[IO.File]::ReadAllText($adapter)
$already=($text.Contains('HERMES_TELEGRAM_DOCUMENT_FOLLOWUP_DELAY_SECONDS') -and $text.Contains('_document_followup_pending') -and $text.Contains('not (getattr(msg, "caption", None) or "").strip()'))
$backup=$null
$mutation='NONE'
if(-not $already){
  if($before -ne '__EXPECTED_SHA__'){
    $gitHead=$null
    $adapterTracked=$false
    $adapterDirty=$null
    $adapterDiff=$null
    try{
      $git=Get-Command git.exe -ErrorAction SilentlyContinue
      if(-not $git){$git=Get-Command git -ErrorAction SilentlyContinue}
      if($git){
        Push-Location $source
        try{
          $gitHead=((& $git.Source rev-parse HEAD 2>$null | Select-Object -First 1) | Out-String).Trim()
          & $git.Source ls-files --error-unmatch -- 'plugins/platforms/telegram/adapter.py' *> $null
          $adapterTracked=($LASTEXITCODE -eq 0)
          $status=((& $git.Source status --porcelain -- 'plugins/platforms/telegram/adapter.py' 2>$null) | Out-String).Trim()
          $adapterDirty=(-not [string]::IsNullOrWhiteSpace($status))
          if($adapterDirty){
            $rawDiff=((& $git.Source diff --no-ext-diff --unified=2 -- 'plugins/platforms/telegram/adapter.py' 2>$null) | Out-String).Trim()
            $safeDiff=[regex]::Replace($rawDiff,'\b\d{5,}:[A-Za-z0-9_-]{20,}\b','<redacted-telegram-token>')
            if($safeDiff.Length -gt 12000){$safeDiff=$safeDiff.Substring(0,12000)+"`n<diff-truncated>"}
            $adapterDiff=$safeDiff
          }
        }finally{Pop-Location}
      }
    }catch{}
    Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_FOLLOWUP_ADAPTER_HASH_MISMATCH';mutation='NONE';beforeSha256=$before;gitHead=$gitHead;adapterTracked=$adapterTracked;adapterDirty=$adapterDirty;adapterDiff=$adapterDiff}) 43
  }
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup="$adapter.afz-pre-document-followup-$stamp.bak"
  Copy-Item -LiteralPath $adapter -Destination $backup -Force
  $patchFile=Join-Path $env:TEMP ('hermes-followup-patch-'+[guid]::NewGuid().ToString('n')+'.py')
  try{
    [IO.File]::WriteAllBytes($patchFile,[Convert]::FromBase64String('__PATCH_B64__'))
    Push-Location $source
    try{$patchOut=(& $python $patchFile $adapter '__EXPECTED_SHA__' '__DELAY__' 2>&1 | Out-String).Trim();$patchExit=$LASTEXITCODE}finally{Pop-Location}
    if($patchExit -ne 0){throw "patcher exit $patchExit"}
    $mutation='TELEGRAM_ADAPTER_DOCUMENT_FOLLOWUP_PATCH'
  }catch{
    try{if($backup){Copy-Item -LiteralPath $backup -Destination $adapter -Force}}catch{}
    Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_FOLLOWUP_PATCH_FAILED';mutation='ROLLED_BACK';beforeSha256=$before;errorType=$_.Exception.GetType().Name}) 44
  }finally{Remove-Item $patchFile -Force -ErrorAction SilentlyContinue}
}
$compileOut=(& $python -m py_compile $adapter 2>&1 | Out-String).Trim();$compileExit=$LASTEXITCODE
if($compileExit -ne 0){
  try{if($backup){Copy-Item -LiteralPath $backup -Destination $adapter -Force}}catch{}
  Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_FOLLOWUP_COMPILE_FAILED';mutation=$(if($backup){'ROLLED_BACK'}else{'NONE'});beforeSha256=$before}) 45
}
$canaryFile=Join-Path $env:TEMP ('hermes-followup-canary-'+[guid]::NewGuid().ToString('n')+'.py')
try{
  [IO.File]::WriteAllBytes($canaryFile,[Convert]::FromBase64String('__CANARY_B64__'))
  Push-Location $source
  try{$canaryOut=(& $python $canaryFile 2>&1 | Out-String).Trim();$canaryExit=$LASTEXITCODE}finally{Pop-Location}
  if($canaryExit -ne 0 -or $canaryOut -notmatch 'FOLLOWUP_CANARY_PASS'){
    try{if($backup){Copy-Item -LiteralPath $backup -Destination $adapter -Force}}catch{}
    Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_FOLLOWUP_CANARY_FAILED';mutation=$(if($backup){'ROLLED_BACK'}else{'NONE'});beforeSha256=$before;canaryExit=$canaryExit}) 46
  }
}finally{Remove-Item $canaryFile -Force -ErrorAction SilentlyContinue}
$after=(Get-FileHash -LiteralPath $adapter -Algorithm SHA256).Hash.ToLowerInvariant()
Emit ([ordered]@{
  ok=$true
  classification='HERMES_TELEGRAM_DOCUMENT_FOLLOWUP_PATCH_VERIFIED'
  mutation=$mutation
  alreadyPatched=$already
  beforeSha256=$before
  afterSha256=$after
  followupDelaySeconds=__DELAY__
  compilePass=$true
  canaryPass=$true
  configChanged=$false
  providerTouched=$false
  ollamaMutationStarted=$false
  networkChanged=$false
  modelGenerationStarted=$false
  observedAt=(Get-Date -Format o)
}) 0
'@
$remote=$remote.Replace('__EXPECTED_SHA__',$expectedSha).Replace('__DELAY__',$delayLiteral).Replace('__PATCH_B64__',$patchB64).Replace('__CANARY_B64__',$canaryB64)
$patchResult=Invoke-RemoteScript -Script $remote -TimeoutMs 90000
if(-not $patchResult -or -not [bool]$patchResult.ok){
  $o=[ordered]@{ok=$false;classification=$(if($patchResult){[string]$patchResult.classification}else{'HERMES_TELEGRAM_FOLLOWUP_REMOTE_UNREACHABLE'});patch=$patchResult;gatewayReload=$null;providerTouched=$false;ollamaMutationStarted=$false;networkChanged=$false;modelGenerationStarted=$false;observedAt=(Get-Date -Format o)}
  Save-Result $o
  exit 1
}

$reloadHelper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Hermes-GatewayReload.ps1'
$reloadRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-gateway-reload.json'
$reloadResult=$null
if((Test-Path -LiteralPath $reloadHelper -PathType Leaf) -and (Test-Path -LiteralPath $reloadRequest -PathType Leaf)){
  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $reloadHelper -InstallRoot $InstallRoot -RequestPath $reloadRequest 2>&1 | Out-String).Trim()
  foreach($line in @($raw -split "`r?`n" | Where-Object{$_})){try{$reloadResult=$line | ConvertFrom-Json}catch{}}
}
if($null -eq $reloadResult){$reloadResult=[pscustomobject]@{ok=$false;classification='HERMES_TELEGRAM_FOLLOWUP_GATEWAY_RELOAD_UNPARSEABLE'}}
$ok=([bool]$patchResult.ok -and [bool]$reloadResult.ok)
$o=[ordered]@{
  ok=$ok
  classification=$(if($ok){'HERMES_TELEGRAM_DOCUMENT_FOLLOWUP_REPAIR_VERIFIED'}else{[string]$reloadResult.classification})
  patch=$patchResult
  gatewayReload=$reloadResult
  providerTouched=$false
  ollamaMutationStarted=$false
  networkChanged=$false
  modelGenerationStarted=$false
  observedAt=(Get-Date -Format o)
}
Save-Result $o
exit $(if($ok){0}else{1})
