#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\hermes-always-on-fabric.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "Hermes fabric request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid Hermes fabric request identity.'}
if([string]$req.action -ne 'hermes-fabric-rollout' -or [string]$req.phase -ne 'preflight' -or [string]$req.status -ne 'active'){throw 'Hermes fabric request must be active preflight.'}
if([string]$req.primary.target -ne 'coolyo@100.71.26.69' -or [string]$req.primary.role -ne 'persistent-controller'){throw 'HP Envy primary target mismatch.'}
if([string]$req.secondary.host -ne 'DESKTOP-10SKF0M' -or [string]$req.secondary.role -ne 'windows-execution-and-fallback'){throw 'windows-main secondary target mismatch.'}
if([string]$req.secondary.base_url -ne 'http://127.0.0.1:11434/v1'){throw 'windows-main Ollama endpoint must remain loopback-only.'}
if([string]$req.accelerator.host -ne 'DESKTOP-H3R6CQN' -or [bool]$req.accelerator.change_in_this_phase){throw 'H3 must remain unchanged during always-on preflight.'}
if([int]$req.context_length -ne 65536){throw 'Hermes context length must remain 65536.'}
if([string]$req.hermes_commit -ne 'f50b5bb0fa5b48caef753c790bf0b09a3570918a'){throw 'Hermes commit pin mismatch.'}
if([bool]$req.start_gateway -or [bool]$req.run_generation_test -or [bool]$req.expose_ollama){throw 'Hermes preflight safety flags mismatch.'}
if([string]$req.control_plane -ne 'github' -or [string]$req.oneDriveRole -ne 'emergency-observability-only'){throw 'Hermes control-plane policy mismatch.'}

$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\hermes-always-on-fabric'
$statePath=Join-Path $stateRoot ($id+'.json')
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$mirrorPath=Join-Path $mirrorRoot 'HERMES-ALWAYS-ON-FABRIC-LATEST.json'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  Write-Output ($o|ConvertTo-Json -Depth 20 -Compress)
}
function Find-Ollama{
  $c=Get-Command ollama.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Path){return [string]$c.Path};if($c.Source){return [string]$c.Source}}
  foreach($p in @('C:\Program Files\Ollama\ollama.exe',(Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'))){if(Test-Path -LiteralPath $p -PathType Leaf){return $p}}
  return $null
}
function Get-OllamaContext([string]$Ollama,[string]$Model){
  if([string]::IsNullOrWhiteSpace($Ollama)){return 0}
  try{
    $txt=(& $Ollama show --modelfile $Model 2>&1|Out-String)
    if($LASTEXITCODE -ne 0){return 0}
    $m=[regex]::Matches($txt,'(?im)^\s*PARAMETER\s+num_ctx\s+(\d+)\s*$')
    if($m.Count -gt 0){return [int]$m[$m.Count-1].Groups[1].Value}
  }catch{}
  return 0
}

$local=[ordered]@{
  host=$env:COMPUTERNAME
  identityOk=($env:COMPUTERNAME -eq 'DESKTOP-10SKF0M')
  hermesHome='C:\ProgramData\AFZ\Hermes'
  hermesProgramDataPresent=$false
  hermesUserPresent=$false
  hermesVersion=$null
  ollamaReachable=$false
  ollamaModels=@()
  hermesCandidates=@()
  protectedWorkDetected=@()
  memoryTotalGiB=$null
  memoryFreeGiB=$null
  systemDriveFreeGiB=$null
}
try{
  $pdLauncher='C:\ProgramData\AFZ\Hermes\bin\hermes.exe'
  $userLauncher='C:\Users\Faiz\AppData\Local\hermes\bin\hermes.exe'
  $local.hermesProgramDataPresent=Test-Path -LiteralPath $pdLauncher -PathType Leaf
  $local.hermesUserPresent=Test-Path -LiteralPath $userLauncher -PathType Leaf
  $launcher=$(if($local.hermesProgramDataPresent){$pdLauncher}elseif($local.hermesUserPresent){$userLauncher}else{$null})
  if($launcher){try{$v=(& $launcher --version 2>&1|Out-String).Trim();if($LASTEXITCODE -eq 0){$local.hermesVersion=$v}}catch{}}
  $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
  $local.memoryTotalGiB=[math]::Round(([double]$os.TotalVisibleMemorySize/1MB),2)
  $local.memoryFreeGiB=[math]::Round(([double]$os.FreePhysicalMemory/1MB),2)
  $d=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
  $local.systemDriveFreeGiB=[math]::Round(([double]$d.FreeSpace/1GB),2)
  $busy=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {$c=[string]$_.CommandLine;$c -and ($c -match '(?i)WebsiteBenchmark|Qwen35B|Qwen38-27B-Website-Benchmark|RadioHilal.*35B')}|ForEach-Object {[string]$_.Name+'#'+[string]$_.ProcessId})
  $local.protectedWorkDetected=$busy
  $ollama=Find-Ollama
  if($ollama){
    try{
      $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 10
      $local.ollamaReachable=$true
      $models=@()
      foreach($m in @($tags.models)){
        $name=[string]$m.name
        if([string]::IsNullOrWhiteSpace($name)){continue}
        $ctx=Get-OllamaContext $ollama $name
        $entry=[ordered]@{name=$name;context=$ctx}
        $models+=$entry
        if($ctx -ge 64000){$local.hermesCandidates+=$entry}
      }
      $local.ollamaModels=$models
    }catch{}
  }
}catch{}

$remoteScript=@'
set -u
host="$(hostname 2>/dev/null || true)"
user="$(id -un 2>/dev/null || true)"
home_dir="${HOME:-}"
tailscale_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
os_id=""
os_version=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  os_id="${ID:-}"
  os_version="${VERSION_ID:-}"
fi
has_git=false; command -v git >/dev/null 2>&1 && has_git=true
has_curl=false; command -v curl >/dev/null 2>&1 && has_curl=true
has_python=false; command -v python3 >/dev/null 2>&1 && has_python=true
has_systemd=false; command -v systemctl >/dev/null 2>&1 && has_systemd=true
has_tailscale=false; command -v tailscale >/dev/null 2>&1 && has_tailscale=true
sudo_nopass=false; sudo -n true >/dev/null 2>&1 && sudo_nopass=true
hermes_present=false
hermes_launcher=""
hermes_version=""
for p in "$home_dir/.local/bin/hermes" "$home_dir/.hermes/hermes-agent/venv/bin/hermes"; do
  if [ -x "$p" ]; then hermes_present=true; hermes_launcher="$p"; break; fi
done
if [ "$hermes_present" = true ]; then hermes_version="$("$hermes_launcher" --version 2>/dev/null | head -n1 || true)"; fi
config="$home_dir/.hermes/config.yaml"
config_present=false
config_provider=""
config_model=""
if [ -r "$config" ]; then
  config_present=true
  config_provider="$(sed -n 's/^[[:space:]]*provider:[[:space:]]*["'"']*\([^#"'"']*\).*/\1/p' "$config" | head -n1 | xargs 2>/dev/null || true)"
  config_model="$(sed -n 's/^[[:space:]]*default:[[:space:]]*["'"']*\([^#"'"']*\).*/\1/p' "$config" | head -n1 | xargs 2>/dev/null || true)"
fi
mem_total_mb="$(awk '/MemTotal:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || true)"
mem_avail_mb="$(awk '/MemAvailable:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || true)"
disk_free_mb="$(df -Pm "$home_dir" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
listen_9119=false; ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)9119$' && listen_9119=true
listen_8642=false; ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)8642$' && listen_8642=true
pid=""
if [ "$sudo_nopass" = true ]; then
  pid="$(sudo -n ss -ltnp 'sport = :8500' 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n1 || true)"
fi
if [ -z "$pid" ]; then pid="$(ss -ltnp 'sport = :8500' 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n1 || true)"; fi
if [ -z "$pid" ]; then pid="$(pgrep -f 'uvicorn.*8500|8500.*uvicorn' 2>/dev/null | head -n1 || true)"; fi
envdump=""
if [ -n "$pid" ]; then
  if [ "$sudo_nopass" = true ]; then envdump="$(sudo -n sh -c "tr '\\000' '\\n' < /proc/$pid/environ" 2>/dev/null || true)";
  elif [ -r "/proc/$pid/environ" ]; then envdump="$(tr '\000' '\n' < "/proc/$pid/environ" 2>/dev/null || true)"; fi
fi
openai_key_present=false
printf '%s\n' "$envdump" | grep -q '^OPENAI_API_KEY=.' && openai_key_present=true
openai_model=""
for k in OPENAI_MODEL OPENAI_DEFAULT_MODEL OPENAI_MODEL_NAME; do
  v="$(printf '%s\n' "$envdump" | sed -n "s/^${k}=//p" | head -n1)"
  if [ -n "$v" ]; then openai_model="$v"; break; fi
done
export AFZ_HOST="$host" AFZ_USER="$user" AFZ_HOME="$home_dir" AFZ_TSIP="$tailscale_ip" AFZ_OSID="$os_id" AFZ_OSVER="$os_version"
export AFZ_GIT="$has_git" AFZ_CURL="$has_curl" AFZ_PY="$has_python" AFZ_SYSTEMD="$has_systemd" AFZ_TAILSCALE="$has_tailscale" AFZ_SUDO="$sudo_nopass"
export AFZ_HERMES="$hermes_present" AFZ_HERMES_LAUNCHER="$hermes_launcher" AFZ_HERMES_VERSION="$hermes_version" AFZ_CONFIG="$config_present" AFZ_CONFIG_PROVIDER="$config_provider" AFZ_CONFIG_MODEL="$config_model"
export AFZ_MEM_TOTAL="$mem_total_mb" AFZ_MEM_AVAIL="$mem_avail_mb" AFZ_DISK_FREE="$disk_free_mb" AFZ_LISTEN9119="$listen_9119" AFZ_LISTEN8642="$listen_8642"
export AFZ_AI8500_PID="$pid" AFZ_OPENAI_KEY="$openai_key_present" AFZ_OPENAI_MODEL="$openai_model"
python3 - <<'PY'
import json, os
b=lambda k: os.environ.get(k,'').lower()=='true'
i=lambda k: int(os.environ.get(k,'0') or 0)
print(json.dumps({
  'host':os.environ.get('AFZ_HOST',''),'user':os.environ.get('AFZ_USER',''),'home':os.environ.get('AFZ_HOME',''),'tailscaleIp':os.environ.get('AFZ_TSIP',''),
  'osId':os.environ.get('AFZ_OSID',''),'osVersion':os.environ.get('AFZ_OSVER',''),'git':b('AFZ_GIT'),'curl':b('AFZ_CURL'),'python3':b('AFZ_PY'),'systemd':b('AFZ_SYSTEMD'),'tailscale':b('AFZ_TAILSCALE'),'sudoNonInteractive':b('AFZ_SUDO'),
  'hermesPresent':b('AFZ_HERMES'),'hermesLauncher':os.environ.get('AFZ_HERMES_LAUNCHER',''),'hermesVersion':os.environ.get('AFZ_HERMES_VERSION',''),'configPresent':b('AFZ_CONFIG'),'configProvider':os.environ.get('AFZ_CONFIG_PROVIDER',''),'configModel':os.environ.get('AFZ_CONFIG_MODEL',''),
  'memoryTotalMiB':i('AFZ_MEM_TOTAL'),'memoryAvailableMiB':i('AFZ_MEM_AVAIL'),'homeDiskFreeMiB':i('AFZ_DISK_FREE'),'listen9119':b('AFZ_LISTEN9119'),'listen8642':b('AFZ_LISTEN8642'),
  'afzAi8500PidPresent':bool(os.environ.get('AFZ_AI8500_PID','')),'openAiApiKeyPresent':b('AFZ_OPENAI_KEY'),'openAiModel':os.environ.get('AFZ_OPENAI_MODEL','')
}, separators=(',',':')))
PY
'@

$hp=[ordered]@{sshOk=$false;error=$null}
try{
  if(-not(Test-Path -LiteralPath $ssh -PathType Leaf)){throw 'Windows OpenSSH client missing.'}
  $inFile=Join-Path $env:TEMP ('afz-hermes-fabric-preflight-'+[guid]::NewGuid().ToString('n')+'.sh')
  $outFile=Join-Path $env:TEMP ('afz-hermes-fabric-preflight-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('afz-hermes-fabric-preflight-'+[guid]::NewGuid().ToString('n')+'.err')
  try{
    [IO.File]::WriteAllText($inFile,$remoteScript,$utf8)
    $args=@('-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes',[string]$req.primary.target,'bash','-s','--')
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(60000)){try{$p.Kill()}catch{};throw 'HP Envy Hermes preflight SSH exceeded 60 seconds.'}
    $stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
    $stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
    if($p.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($stdout)){throw "HP Envy Hermes preflight SSH failed exit=$($p.ExitCode) stderr=$stderr"}
    $line=@($stdout -split "`r?`n"|Where-Object{$_ -match '^\{.*\}$'}|Select-Object -Last 1)
    if($line.Count -eq 0){throw 'HP Envy Hermes preflight returned no JSON result.'}
    $remote=$line[0]|ConvertFrom-Json
    $hp=[ordered]@{sshOk=$true;data=$remote;error=$null}
  }finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}catch{$hp=[ordered]@{sshOk=$false;error=$_.Exception.Message}}

$hpIdentityOk=$false
$hpPrereqs=$false
$hpProviderReady=$false
if([bool]$hp.sshOk){
  $hpIdentityOk=([string]$hp.data.user -eq 'coolyo' -and [string]$hp.data.tailscaleIp -eq '100.71.26.69')
  $hpPrereqs=([bool]$hp.data.git -and [bool]$hp.data.curl -and [bool]$hp.data.python3 -and [bool]$hp.data.systemd)
  $hpProviderReady=[bool]$hp.data.openAiApiKeyPresent
}
$asusModelReady=([bool]$local.identityOk -and [bool]$local.ollamaReachable -and @($local.hermesCandidates).Count -gt 0)
$ready=($hpIdentityOk -and $hpPrereqs -and $hpProviderReady -and $asusModelReady)
$classification=$(if($ready){'HERMES_FABRIC_PREFLIGHT_READY'}elseif($hpIdentityOk -and $hpPrereqs){'HERMES_FABRIC_PREFLIGHT_PARTIAL'}else{'HERMES_FABRIC_PREFLIGHT_BLOCKED'})
$result=[ordered]@{
  schema=1
  ok=$ready
  retryable=$false
  readOnly=$true
  classification=$classification
  jobId=$id
  phase='preflight'
  controlPlane='github'
  oneDriveRole='emergency-observability-only'
  hermesCommit=[string]$req.hermes_commit
  contextLength=[int]$req.context_length
  hpEnvy=$hp
  windowsMain=$local
  h3=[ordered]@{role='gpu-model-worker';changed=$false}
  safety=[ordered]@{gatewayStarted=$false;generationTestStarted=$false;ollamaExposureChanged=$false;configWritten=$false;softwareInstalled=$false}
  capturedAt=(Get-Date -Format o)
}
Save-State $result
exit 0
