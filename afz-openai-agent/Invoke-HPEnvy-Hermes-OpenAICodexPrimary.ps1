#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'

$current=''
try{$current=[Security.Principal.WindowsIdentity]::GetCurrent().Name}catch{$current="$env:USERDOMAIN\$env:USERNAME"}
$isSystem=($current -match '(?i)(^|\\)SYSTEM$' -or [string]$env:USERNAME -ieq 'SYSTEM')

if($isSystem -and (Test-Path -LiteralPath $RequestPath -PathType Leaf)){
  $req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $id=([string]$req.id).Trim()
  $safe=(
    [int]$req.schema -eq 1 -and
    $id -match '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$' -and
    ([string]$req.target).Trim() -eq 'coolyo@100.71.26.69' -and
    ([string]$req.provider).Trim().ToLowerInvariant() -eq 'openai-codex' -and
    ([string]$req.model).Trim() -eq 'gpt-5.6-luna' -and
    -not [bool]$req.allow_generation -and
    -not [bool]$req.allow_gateway_start -and
    -not [bool]$req.allow_firewall_change -and
    -not [bool]$req.allow_tailscale_change
  )
  if($safe){
    $queue='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Queue\hpenvy'
    $results='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
    $taskId=('000-hpenvy-codex-authlist-local-'+$id)
    $taskPath=Join-Path $queue ($taskId+'.sh')
    $resultPath=Join-Path $results ($taskId+'.txt')
    New-Item -ItemType Directory -Force -Path $queue | Out-Null
    if(-not(Test-Path -LiteralPath $taskPath -PathType Leaf) -and -not(Test-Path -LiteralPath $resultPath -PathType Leaf)){
      $script=@'
#!/usr/bin/env bash
set -u
H="$HOME/.local/bin/hermes"
printf '%s\n' '===== HP ENVY CODEX AUTHLIST LOCAL READONLY START ====='
printf 'HOST=%s\n' "$(hostname 2>/dev/null || true)"
printf 'USER=%s\n' "$(id -un 2>/dev/null || true)"
if [ ! -x "$H" ]; then
  printf '%s\n' 'HERMES_LAUNCHER=false' 'AUTH_LIST_PRESENT=false' 'AUTH_LIST_COUNT=0' 'AUTH_STRUCTURAL_PRESENT=false' 'GENERATION_STARTED=false' 'GATEWAY_STARTED=false' 'SECRET_VALUES_EMITTED=false' 'FINAL_CLASSIFICATION=HP_CODEX_AUTHLIST_HERMES_MISSING'
  exit 0
fi
printf '%s\n' 'HERMES_LAUNCHER=true'
out="$($H auth list openai-codex 2>&1 || true)"
count="$(printf '%s\n' "$out" | python3 -c 'import sys,re; s=sys.stdin.read(); m=re.search(r"openai-codex\s*\((\d+)\s+credential",s,re.I); print(m.group(1) if m else "0")')"
present=false
if [ "${count:-0}" -gt 0 ] 2>/dev/null; then present=true; fi
if [ "$present" = false ] && printf '%s\n' "$out" | grep -qi 'openai-codex' && printf '%s\n' "$out" | grep -Eqi 'oauth|device_code'; then present=true; fi
printf 'AUTH_LIST_PRESENT=%s\n' "$present"
printf 'AUTH_LIST_COUNT=%s\n' "${count:-0}"
struct=false
if [ -r "$HOME/.hermes/auth.json" ]; then
  struct="$(python3 - "$HOME/.hermes/auth.json" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:
    print('false'); raise SystemExit
found_provider=False; found_access=False; found_refresh=False
def walk(x):
    global found_provider,found_access,found_refresh
    if isinstance(x,dict):
        for k,v in x.items():
            ks=str(k).lower()
            if ks=='openai-codex': found_provider=True
            if ks=='access_token' and bool(v): found_access=True
            if ks=='refresh_token' and bool(v): found_refresh=True
            if isinstance(v,str) and v.lower()=='openai-codex': found_provider=True
            walk(v)
    elif isinstance(x,list):
        for v in x: walk(v)
walk(d)
print('true' if (found_provider and found_access and found_refresh) else 'false')
PY
)"
fi
printf 'AUTH_STRUCTURAL_PRESENT=%s\n' "$struct"
"$H" config get model --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d.get("model",d) if isinstance(d,dict) else {}; print("PROVIDER="+str(m.get("provider","")+"")); print("MODEL="+str(m.get("default",m.get("model","")))); print("CONTEXT_LENGTH="+str(m.get("context_length",""))); print("BASE_URL_PRESENT="+("true" if bool(m.get("base_url")) else "false"))' || true
printf '%s\n' 'GENERATION_STARTED=false' 'GATEWAY_STARTED=false' 'SECRET_VALUES_EMITTED=false' 'FINAL_CLASSIFICATION=HP_CODEX_AUTHLIST_LOCAL_READONLY'
printf '%s\n' '===== HP ENVY CODEX AUTHLIST LOCAL READONLY END ====='
'@
      $script=$script -replace "`r`n","`n"
      [IO.File]::WriteAllText($taskPath,$script,(New-Object Text.UTF8Encoding($false)))
    }
    $o=[ordered]@{schema=1;requestId=$id;classification='HP_HERMES_CODEX_AUTHLIST_QUEUED_HPREMOTEWORKER';authVerified=$false;configuredProvider=$null;configuredModel=$null;contextLength=$null;baseUrlPresent=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;worker='hpenvy';queueTask=$taskId;executionIdentity='SYSTEM';time=(Get-Date -Format o)}
    Write-Output ($o|ConvertTo-Json -Depth 8 -Compress)
    exit 0
  }
}

$impl=Join-Path $InstallRoot 'afz-openai-agent\Invoke-HPEnvy-Hermes-OpenAICodexPrimary.V3.ps1'
if(-not(Test-Path -LiteralPath $impl -PathType Leaf)){throw "Codex V3 implementation missing: $impl"}
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $impl -InstallRoot $InstallRoot -RequestPath $RequestPath
exit $LASTEXITCODE
