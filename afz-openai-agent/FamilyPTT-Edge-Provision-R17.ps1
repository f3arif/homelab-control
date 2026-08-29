#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$JobId,
  [Parameter(Mandatory=$true)][string]$PreflightJobId,
  [string]$ResultFile='C:\Users\Faiz\AppData\Local\AFZ\FamilyPTTEdgeProvision\latest.json'
)
$ErrorActionPreference='Stop'
$piTarget='coolyo@192.168.50.68'
$piKey='C:\Users\Faiz\.ssh\afz_pi_sync'
$hpTarget='coolyo@100.71.26.69'
$preflightFile='C:\Users\Faiz\AppData\Local\AFZ\FamilyPTTEdgePreflight\latest.json'
$sshExe=(Get-Command ssh.exe -ErrorAction Stop).Source
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ResultFile) | Out-Null

function Save-Result($obj){$obj|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $ResultFile -Encoding UTF8}
function Run-Ssh([string]$Target,[string[]]$SshArgs,[string]$Command,[int]$TimeoutSeconds=180){
  $payload=[pscustomobject]@{exe=$script:sshExe;target=$Target;sshArgs=@($SshArgs);command=$Command}
  $job=Start-Job -ScriptBlock {
    param($p)
    $out=& $p.exe @($p.sshArgs) $p.target $p.command 2>&1
    [pscustomobject]@{exit=[int]$LASTEXITCODE;output=@($out|ForEach-Object{[string]$_})}
  } -ArgumentList (,$payload)
  try{
    if(-not(Wait-Job -Job $job -Timeout $TimeoutSeconds)){
      Stop-Job -Job $job -ErrorAction SilentlyContinue
      throw "SSH overall timeout after $TimeoutSeconds seconds target=$Target"
    }
    $data=@(Receive-Job -Job $job -ErrorAction Stop)|Where-Object {$_ -and $_.PSObject.Properties['exit']}|Select-Object -Last 1
    if(-not $data){throw "SSH returned no structured result target=$Target"}
    return [ordered]@{exit=[int]$data.exit;output=@($data.output|ForEach-Object{[string]$_})}
  } finally {Remove-Job -Job $job -Force -ErrorAction SilentlyContinue}
}
function Marker-Map($lines){$m=@{};foreach($line in @($lines)){if([string]$line -match '^([A-Z0-9_]+)=(.*)$'){$m[$matches[1]]=$matches[2].Trim()}};return $m}
function Test-PublicTls([string]$HostName){
  $tcp=New-Object Net.Sockets.TcpClient
  try{
    $iar=$tcp.BeginConnect($HostName,443,$null,$null)
    if(-not $iar.AsyncWaitHandle.WaitOne(10000)){throw 'TLS TCP connect timeout'}
    $tcp.EndConnect($iar)
    $ssl=New-Object Net.Security.SslStream($tcp.GetStream(),$false)
    try{$ssl.AuthenticateAsClient($HostName);return ($ssl.IsAuthenticated -and $ssl.RemoteCertificate -ne $null)}finally{$ssl.Dispose()}
  }finally{$tcp.Close()}
}

$result=[ordered]@{
  schema=1;project='familyptt';action='edge-provision';jobId=$JobId;preflightJobId=$PreflightJobId
  startedAt=(Get-Date -Format o);classification='EDGE_PROVISION_FAILED';ok=$false
  safety=[ordered]@{secretValuesRead=$false;secretValuesLogged=$false;dnsMutation=$false;firewallMutation=$false;proxyMutation=$false;certificateMutation=$false;backendSourceMutation=$false;tokenServiceRestart=$false}
}
try{
  if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$' -or $PreflightJobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid job identifier'}
  if(-not(Test-Path -LiteralPath $preflightFile -PathType Leaf)){throw 'Required FamilyPTT edge preflight result is missing'}
  $pre=Get-Content -LiteralPath $preflightFile -Raw -Encoding UTF8|ConvertFrom-Json
  if([string]$pre.jobId -ne $PreflightJobId){throw "Preflight job mismatch expected=$PreflightJobId actual=$($pre.jobId)"}
  if(-not [bool]$pre.ok -or [string]$pre.classification -ne 'EDGE_PREFLIGHT_READY_FOR_NARROW_PROVISIONING'){throw "Preflight not ready: $($pre.classification)"}
  if(-not [bool]$pre.pi.customHttpIncluded -or -not [bool]$pre.pi.certbotAvailable -or -not [bool]$pre.pi.certbotAccountPresent -or -not [bool]$pre.pi.acmeWebrootPresent){throw 'Preflight certificate/custom-Nginx prerequisites are incomplete'}
  if(-not [bool]$pre.hp.liveKitRunning -or -not [bool]$pre.hp.tokenRunning){throw 'Preflight backend containers are not both running'}
  if([string]$pre.hp.tokenUrlScheme -notin @('unset','wss')){throw "Token LIVEKIT_URL environment override requires review before mutation (scheme=$($pre.hp.tokenUrlScheme))"}
  if(-not(Test-Path -LiteralPath $piKey -PathType Leaf)){throw 'Dedicated Pi SSH key missing'}

  $piArgs=@('-i',$piKey,'-o','BatchMode=yes','-o','ConnectTimeout=8','-o','ConnectionAttempts=1','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2','-o','StrictHostKeyChecking=accept-new')
  $piCmd=@'
set -eu
job='__JOB__'
conf='/opt/edge/npm/data/nginx/custom/http.conf'
backup_dir='/opt/edge/npm/data/nginx/custom/familyptt-backups'
backup="$backup_dir/http.conf.$job.bak"
mode="$backup_dir/http.conf.$job.mode"
mkdir -p "$backup_dir" "$(dirname "$conf")"
if [ -f "$conf" ]; then cp -a "$conf" "$backup"; printf 'present\n' > "$mode"; else printf 'absent\n' > "$mode"; fi
rollback() {
  set +e
  if [ "$(cat "$mode" 2>/dev/null)" = present ] && [ -f "$backup" ]; then cp -a "$backup" "$conf"; else rm -f "$conf"; fi
  docker exec npm-pi nginx -t >/dev/null 2>&1 && docker exec npm-pi nginx -s reload >/dev/null 2>&1
}
trap 'rollback' ERR
cat > "$conf.tmp" <<'NGINX'
# AFZ FamilyPTT managed public edge - ACME bootstrap
server {
    listen 80;
    listen [::]:80;
    server_name ptt-api.afzeng.ca ptt-livekit.afzeng.ca;
    location ^~ /.well-known/acme-challenge/ {
        root /data/letsencrypt-acme-challenge;
        default_type text/plain;
    }
    location / { return 404; }
}
NGINX
mv "$conf.tmp" "$conf"
docker exec npm-pi nginx -t >/dev/null 2>&1
docker exec npm-pi nginx -s reload >/dev/null 2>&1
if ! docker exec npm-pi certbot certonly --webroot -w /data/letsencrypt-acme-challenge --cert-name familyptt-edge -d ptt-api.afzeng.ca -d ptt-livekit.afzeng.ca --non-interactive --agree-tos --keep-until-expiring >/tmp/familyptt-certbot-$job.log 2>&1; then
  exit 21
fi
docker exec npm-pi sh -lc 'test -s /etc/letsencrypt/live/familyptt-edge/fullchain.pem && test -s /etc/letsencrypt/live/familyptt-edge/privkey.pem'
cat > "$conf.tmp" <<'NGINX'
# AFZ FamilyPTT managed public edge
server {
    listen 80;
    listen [::]:80;
    server_name ptt-api.afzeng.ca ptt-livekit.afzeng.ca;
    location ^~ /.well-known/acme-challenge/ {
        root /data/letsencrypt-acme-challenge;
        default_type text/plain;
    }
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ptt-api.afzeng.ca;
    ssl_certificate /etc/letsencrypt/live/familyptt-edge/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/familyptt-edge/privkey.pem;
    location / {
        proxy_pass http://100.71.26.69:7883;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ptt-livekit.afzeng.ca;
    ssl_certificate /etc/letsencrypt/live/familyptt-edge/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/familyptt-edge/privkey.pem;
    location / {
        proxy_pass http://100.71.26.69:7880;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINX
mv "$conf.tmp" "$conf"
docker exec npm-pi nginx -t >/dev/null 2>&1
docker exec npm-pi nginx -s reload >/dev/null 2>&1
curl -fsS --max-time 10 --resolve ptt-api.afzeng.ca:443:127.0.0.1 https://ptt-api.afzeng.ca/health >/dev/null
printf 'PI_EDGE_OK=true\n'
printf 'PI_CERT_OK=true\n'
printf 'PI_BACKUP_MODE='; cat "$mode"
trap - ERR
'@.Replace('__JOB__',$JobId)
  $pi=Run-Ssh $piTarget $piArgs $piCmd 180
  if($pi.exit -ne 0){throw "Pi edge provisioning failed exit=$($pi.exit)"}
  $piMap=Marker-Map $pi.output
  if($piMap.PI_EDGE_OK -ne 'true' -or $piMap.PI_CERT_OK -ne 'true'){throw 'Pi edge provisioning did not return success markers'}
  $result.safety.proxyMutation=$true;$result.safety.certificateMutation=$true
  $result.pi=[ordered]@{edgeReady=$true;certificateReady=$true;backupMode=$piMap.PI_BACKUP_MODE}

  $hpArgs=@('-o','BatchMode=yes','-o','ConnectTimeout=8','-o','ConnectionAttempts=1','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2','-o','StrictHostKeyChecking=accept-new')
  $hpCmd=@'
set -eu
job='__JOB__'
container='familyptt-livekit-token'
source='/home/coolyo/familyptt-livekit/token/server.mjs'
backup="/home/coolyo/familyptt-livekit/token/server.mjs.$job.bak"
newurl='wss://ptt-livekit.afzeng.ca'
oldurl='ws://100.71.26.69:7880'
env_url="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | awk -F= '$1=="LIVEKIT_URL"{sub(/^[^=]*=/,"");print;exit}')"
case "$env_url" in
  '') ;;
  wss://ptt-livekit.afzeng.ca) printf 'HP_TOKEN_ALREADY_WSS=true\n';;
  *) printf 'HP_TOKEN_ENV_CONFLICT=true\n'; exit 31;;
esac
if [ "$env_url" != "$newurl" ]; then
  test -s "$source"
  cp -a "$source" "$backup"
  rollback() {
    set +e
    if [ -f "$backup" ]; then cp -a "$backup" "$source"; fi
    if [ -n "${dest:-}" ] && [ -f "$backup" ]; then docker cp "$backup" "$container:$dest" >/dev/null 2>&1 || true; fi
    docker restart "$container" >/dev/null 2>&1 || true
  }
  trap 'rollback' ERR
  python3 - "$source" "$oldurl" "$newurl" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); old=sys.argv[2]; new=sys.argv[3]
s=p.read_text()
if new not in s:
    if old not in s: raise SystemExit('expected LiveKit fallback not found')
    s=s.replace(old,new,1)
p.write_text(s)
PY
  mount_dest="$(docker inspect "$container" | python3 -c 'import json,sys; x=json.load(sys.stdin)[0]; src="/home/coolyo/familyptt-livekit/token"; print(next((m.get("Destination","") for m in x.get("Mounts",[]) if m.get("Source","").startswith(src)),""))')"
  if [ -z "$mount_dest" ]; then
    workdir="$(docker inspect -f '{{.Config.WorkingDir}}' "$container")"
    dest="${workdir%/}/server.mjs"
    if ! docker exec "$container" sh -lc "test -f '$dest'"; then
      dest="$(docker exec "$container" sh -lc 'for p in /app/server.mjs /app/token/server.mjs /server.mjs; do if [ -f "$p" ]; then echo "$p"; exit 0; fi; done; exit 1')"
    fi
    docker cp "$source" "$container:$dest" >/dev/null
  fi
  docker restart "$container" >/dev/null
  for i in $(seq 1 20); do
    [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" = true ] && break
    sleep 1
  done
  [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ]
  curl -fsS --max-time 8 http://127.0.0.1:7883/health >/dev/null
  curl -fsS --max-time 10 'http://127.0.0.1:7883/token?identity=r17-verify&name=R17Verify&room=family-main' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("serverUrl")=="wss://ptt-livekit.afzeng.ca"; assert bool(d.get("participantToken"))'
  trap - ERR
fi
printf 'HP_TOKEN_OK=true\n'
printf 'HP_TOKEN_SERVICE_RUNNING='; docker inspect -f '{{.State.Running}}' "$container"
'@.Replace('__JOB__',$JobId)
  $hp=Run-Ssh $hpTarget $hpArgs $hpCmd 120
  if($hp.exit -ne 0){throw "HP token-service production switch failed exit=$($hp.exit)"}
  $hpMap=Marker-Map $hp.output
  if($hpMap.HP_TOKEN_OK -ne 'true' -or $hpMap.HP_TOKEN_SERVICE_RUNNING -ne 'true'){throw 'HP token-service switch did not return success markers'}
  $result.safety.backendSourceMutation=([string]$pre.hp.tokenUrlScheme -eq 'unset')
  $result.safety.tokenServiceRestart=([string]$pre.hp.tokenUrlScheme -eq 'unset')
  $result.hp=[ordered]@{tokenServerUrl='wss://ptt-livekit.afzeng.ca';tokenServiceRunning=$true}

  $health=Invoke-WebRequest -Uri 'https://ptt-api.afzeng.ca/health' -UseBasicParsing -TimeoutSec 15
  if([int]$health.StatusCode -ne 200){throw "Public API health returned $($health.StatusCode)"}
  $tokenUri='https://ptt-api.afzeng.ca/token?identity=r17-public-verify&name=R17PublicVerify&room=family-main'
  $tokenResp=Invoke-RestMethod -Uri $tokenUri -Method Get -TimeoutSec 15
  if([string]$tokenResp.serverUrl -ne 'wss://ptt-livekit.afzeng.ca' -or -not $tokenResp.participantToken){throw 'Public token endpoint did not return the required WSS URL/token'}
  $liveKitTls=Test-PublicTls 'ptt-livekit.afzeng.ca'
  if(-not $liveKitTls){throw 'Public LiveKit TLS handshake failed'}
  $result.public=[ordered]@{apiHealth200=$true;tokenIssued=$true;serverUrl='wss://ptt-livekit.afzeng.ca';liveKitTlsValid=$true}
  $result.classification='EDGE_PROVISIONED_PUBLIC_SIGNALING_READY'
  $result.ok=$true
  $result.finishedAt=(Get-Date -Format o)
  Save-Result $result
  exit 0
}catch{
  $result.ok=$false;$result.error=$_.Exception.Message;$result.finishedAt=(Get-Date -Format o);Save-Result $result;exit 1
}
