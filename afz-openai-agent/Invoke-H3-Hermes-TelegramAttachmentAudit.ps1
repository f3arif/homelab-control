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
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Hermes Telegram attachment audit request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid Telegram attachment audit identity.'}
if([string]$req.action -ne 'audit-telegram-attachments' -or [string]$req.status -ne 'ACTIVE'){throw 'Telegram attachment audit request is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'Telegram attachment audit target mismatch.'}
if(-not [bool]$req.read_only -or [bool]$req.restart_gateway -or [bool]$req.change_config -or [bool]$req.change_network){throw 'Telegram attachment audit safety flags mismatch.'}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-telegram-attachment-audit'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-TELEGRAM-ATTACHMENT-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
foreach($required in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "Required H3 audit path missing: $required"}}

$remote=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
function Emit($o,[int]$code){$o|ConvertTo-Json -Depth 20 -Compress;exit $code}
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_AUDIT_WRONG_HOST';host=$env:COMPUTERNAME}) 30}
$root=Join-Path $env:LOCALAPPDATA 'hermes'
$source=Join-Path $root 'hermes-agent'
$python=Join-Path $source 'venv\Scripts\python.exe'
if(-not(Test-Path -LiteralPath $python -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_AUDIT_PYTHON_MISSING'}) 41}
$tmp=Join-Path $env:TEMP ('afz-hermes-telegram-audit-'+[guid]::NewGuid().ToString('n')+'.py')
$py=@"
from __future__ import annotations
import hashlib, importlib.metadata as md, inspect, json, os, subprocess, sys
from pathlib import Path

root=Path(os.environ.get('LOCALAPPDATA',''))/'hermes'
source=root/'hermes-agent'
out={
 'ok':True,'classification':'HERMES_TELEGRAM_ATTACHMENT_AUDIT_OK','host':'DESKTOP-H3R6CQN',
 'readOnly':True,'gatewayRestarted':False,'configChanged':False,'networkChanged':False,
}

# Installed package/source identity, without exposing config or tokens.
versions={}
for name in ('hermes-agent','hermes_agent','hermes','hermes-cli'):
    try: versions[name]=md.version(name)
    except Exception: pass
out['packageVersions']=versions
try:
    if (source/'.git').exists():
        out['gitHead']=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True,stderr=subprocess.DEVNULL,timeout=5).strip()
        dirty=subprocess.check_output(['git','-C',str(source),'status','--porcelain'],text=True,stderr=subprocess.DEVNULL,timeout=5)
        out['gitDirtyFileCount']=len([x for x in dirty.splitlines() if x.strip()])
except Exception as e:
    out['gitProbeError']=type(e).__name__

adapter_path=None
adapter_text=''
import_error=None
try:
    from plugins.platforms.telegram.adapter import TelegramAdapter
    adapter_path=Path(inspect.getsourcefile(TelegramAdapter) or '')
except Exception as e:
    import_error=type(e).__name__+': '+str(e)[:180]

if not adapter_path or not adapter_path.exists():
    candidates=[
      source/'plugins'/'platforms'/'telegram'/'adapter.py',
      source/'gateway'/'platforms'/'telegram.py',
      source/'venv'/'Lib'/'site-packages'/'plugins'/'platforms'/'telegram'/'adapter.py',
    ]
    adapter_path=next((p for p in candidates if p.exists()),None)
if adapter_path and adapter_path.exists():
    adapter_text=adapter_path.read_text(encoding='utf-8',errors='replace')
    b=adapter_text.encode('utf-8')
    out['adapterPath']=str(adapter_path)
    out['adapterSha256']=hashlib.sha256(b).hexdigest()
    out['adapterSizeBytes']=len(b)
    checks={
      'hasMediaHandler':'_handle_media_message' in adapter_text,
      'handlesDocument':('MessageType.DOCUMENT' in adapter_text and '.document' in adapter_text),
      'downloadsTelegramFile':('download_as_bytearray' in adapter_text or 'download_to_drive' in adapter_text),
      'injectsTextDocumentContent':'[Content of ' in adapter_text,
      'hasDownloadFailureNotice':("Couldn't download" in adapter_text or 'could not be downloaded' in adapter_text),
      'usesDocumentCache':('DOCUMENT_CACHE_DIR' in adapter_text or 'cache_document' in adapter_text),
      'handlesPhoto':('.photo' in adapter_text),
      'handlesVideo':('.video' in adapter_text),
      'handlesAudio':('.audio' in adapter_text or '.voice' in adapter_text),
    }
    out['features']=checks
else:
    out['adapterPath']=None
    out['features']={}
if import_error: out['adapterImportError']=import_error

# Resolve Hermes cache directories through its own constants when possible.
cache={}
try:
    from gateway.platforms import base as gb
    for attr in ('DOCUMENT_CACHE_DIR','VIDEO_CACHE_DIR','AUDIO_CACHE_DIR','IMAGE_CACHE_DIR'):
        p=getattr(gb,attr,None)
        if p is None: continue
        pp=Path(p)
        files=[]
        try: files=[x for x in pp.iterdir() if x.is_file()] if pp.exists() else []
        except Exception: files=[]
        cache[attr]={'path':str(pp),'exists':pp.exists(),'fileCount':len(files),'latestMtime':max((x.stat().st_mtime for x in files),default=None)}
except Exception as e:
    cache['probeError']=type(e).__name__
out['cache']=cache

# Gateway process count only; no command arguments beyond boolean identification.
try:
    import subprocess as sp
    ps="Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'python|hermes' -and $_.CommandLine -match 'gateway run' } | Select-Object -ExpandProperty ProcessId"
    raw=sp.check_output(['powershell.exe','-NoProfile','-Command',ps],text=True,stderr=sp.DEVNULL,timeout=5)
    pids=[x.strip() for x in raw.splitlines() if x.strip().isdigit()]
    out['gatewayProcessCount']=len(pids)
    out['gatewayPids']=[int(x) for x in pids]
except Exception as e:
    out['gatewayProcessProbeError']=type(e).__name__

# Sanitized recent-log signal counts only. Never return lines, filenames, chat text, or tokens.
patterns={
 'document':('document','attachment'),
 'downloadFailure':("couldn't download",'could not be downloaded','download failed','cdn'),
 'telegramError':('telegram','error'),
 'media':('media','cache'),
}
counts={k:0 for k in patterns}
log_files=0
cutoff=0
try:
    import time
    cutoff=time.time()-48*3600
    for base in (root/'logs',root/'runtime'):
        if not base.exists(): continue
        for p in base.rglob('*'):
            try:
                if not p.is_file() or p.stat().st_mtime < cutoff or p.stat().st_size > 8_000_000: continue
                if p.suffix.lower() not in ('.log','.txt','.json','.jsonl'): continue
                log_files+=1
                data=p.read_text(encoding='utf-8',errors='ignore')[-500000:].lower()
                for k,terms in patterns.items():
                    if k=='telegramError':
                        counts[k]+=sum(1 for line in data.splitlines() if 'telegram' in line and ('error' in line or 'exception' in line or 'failed' in line))
                    else:
                        counts[k]+=sum(data.count(t) for t in terms)
            except Exception: pass
except Exception: pass
out['recentLogFilesScanned']=log_files
out['recentLogSignalCounts']=counts

# Safe config booleans only; never emit token/value text.
try:
    cfg=(root/'config.yaml').read_text(encoding='utf-8',errors='ignore')
    low=cfg.lower()
    out['configSignals']={
      'telegramMentioned':'telegram' in low,
      'tokenFieldMentioned':('token:' in low or 'bot_token' in low),
      'messagingMentioned':'messaging' in low or 'platforms' in low,
    }
except Exception as e:
    out['configProbeError']=type(e).__name__

# Classify the most actionable condition.
f=out.get('features') or {}
if not out.get('adapterPath'):
    out['classification']='HERMES_TELEGRAM_ADAPTER_NOT_FOUND'
elif not f.get('handlesDocument'):
    out['classification']='HERMES_TELEGRAM_INSTALLED_HANDLER_LACKS_DOCUMENT_SUPPORT'
elif not f.get('downloadsTelegramFile'):
    out['classification']='HERMES_TELEGRAM_INSTALLED_HANDLER_LACKS_FILE_DOWNLOAD'
elif not f.get('hasDownloadFailureNotice'):
    out['classification']='HERMES_TELEGRAM_HANDLER_PRE_FAILURE_NOTICE_GENERATION'
elif (out.get('cache',{}).get('DOCUMENT_CACHE_DIR') or {}).get('fileCount',0)==0:
    out['classification']='HERMES_TELEGRAM_DOCUMENT_HANDLER_PRESENT_CACHE_EMPTY'
print(json.dumps(out,separators=(',',':')))
"@
[IO.File]::WriteAllText($tmp,$py,(New-Object Text.UTF8Encoding($false)))
try{$raw=(& $python $tmp 2>&1|Out-String).Trim();$code=$LASTEXITCODE}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
if([string]::IsNullOrWhiteSpace($raw)){Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_AUDIT_NO_OUTPUT'}) 42}
Write-Output $raw
exit $code
'@

$bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 Telegram audit stdin empty.''};Invoke-Expression $script'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
function Invoke-H3([string]$target,[string]$transport,[string[]]$extra){
  $in=Join-Path $env:TEMP ('h3-tg-audit-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $out=Join-Path $env:TEMP ('h3-tg-audit-'+[guid]::NewGuid().ToString('n')+'.out')
  $err=Join-Path $env:TEMP ('h3-tg-audit-'+[guid]::NewGuid().ToString('n')+'.err')
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known))
  if($extra){$args+=@($extra)}
  $args+=@($target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  try{
    [IO.File]::WriteAllText($in,$remote,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $in -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(60000)){try{$p.Kill()}catch{};return [pscustomobject]@{ok=$false;classification='HERMES_TELEGRAM_AUDIT_REMOTE_TIMEOUT';transport=$transport}}
    $stdout=$(if(Test-Path $out){[IO.File]::ReadAllText($out).Trim()}else{''})
    $stderr=$(if(Test-Path $err){[IO.File]::ReadAllText($err).Trim()}else{''})
    $parsed=$null
    foreach($line in @($stdout -split "`r?`n"|Where-Object{$_})){try{$parsed=$line|ConvertFrom-Json}catch{}}
    if($parsed){$parsed|Add-Member transport $transport -Force;return $parsed}
    return [pscustomobject]@{ok=$false;classification='HERMES_TELEGRAM_AUDIT_INVALID_REMOTE_RESULT';transport=$transport;errorType=$(if($stderr){'SSH_OR_REMOTE_ERROR'}else{'INVALID_JSON'})}
  }finally{Remove-Item $in,$out,$err -Force -ErrorAction SilentlyContinue}
}
$result=Invoke-H3 'Faiz@100.106.186.118' 'tailscale' @()
if(-not [bool]$result.ok -and [string]$result.classification -in @('HERMES_TELEGRAM_AUDIT_REMOTE_TIMEOUT','HERMES_TELEGRAM_AUDIT_INVALID_REMOTE_RESULT')){
  $result=Invoke-H3 'Faiz@192.168.50.185' 'lan-hostkey-alias' @('-o','HostKeyAlias=100.106.186.118')
}
$json=$result|ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($statePath,$json,$utf8)
try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$json,$utf8)}}catch{}
Write-Output ($result|ConvertTo-Json -Depth 20 -Compress)
exit $(if([bool]$result.ok){0}else{1})
