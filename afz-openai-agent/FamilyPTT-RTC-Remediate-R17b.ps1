#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$JobId,
  [string]$ResultFile='C:\Users\Faiz\AppData\Local\AFZ\FamilyPTTRtcRemediation\latest.json'
)
$ErrorActionPreference='Stop'
$hpTarget='coolyo@100.71.26.69'
$sshExe=(Get-Command ssh.exe -ErrorAction Stop).Source
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ResultFile) | Out-Null

function Save-Result($obj){$obj|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $ResultFile -Encoding UTF8}
function Run-Ssh([string]$Target,[string[]]$SshArgs,[string]$Command,[int]$TimeoutSeconds=120){
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
function Find-UpnpMapping($collection,[int]$port,[string]$protocol){
  foreach($m in $collection){
    try{if([int]$m.ExternalPort -eq $port -and ([string]$m.Protocol).ToUpperInvariant() -eq $protocol.ToUpperInvariant()){return $m}}catch{}
  }
  return $null
}
function Ensure-UpnpMapping($collection,[int]$port,[string]$protocol,[string]$internalClient,[string]$description){
  $existing=Find-UpnpMapping $collection $port $protocol
  if($existing){
    if(([string]$existing.InternalClient) -ne $internalClient -or [int]$existing.InternalPort -ne $port){
      throw "UPnP mapping conflict on $protocol/$port existing=$($existing.InternalClient):$($existing.InternalPort)"
    }
    return [ordered]@{created=$false;externalIp=[string]$existing.ExternalIPAddress}
  }
  $added=$collection.Add($port,$protocol,$port,$internalClient,$true,$description)
  if(-not $added){$added=Find-UpnpMapping $collection $port $protocol}
  if(-not $added){throw "UPnP mapping add returned no mapping for $protocol/$port"}
  return [ordered]@{created=$true;externalIp=[string]$added.ExternalIPAddress}
}

$result=[ordered]@{
  schema=1;project='familyptt';action='rtc-remediate';jobId=$JobId;startedAt=(Get-Date -Format o)
  classification='RTC_REMEDIATION_FAILED';ok=$false
  safety=[ordered]@{liveKitConfigMutation=$false;liveKitRestart=$false;firewallMutation=$false;routerNatMutation=$false;secretValuesRead=$false;secretValuesLogged=$false}
}
$createdTcp=$false;$createdUdp=$false;$upnp=$null;$hpMap=$null
try{
  if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid job identifier'}
  $hpArgs=@('-o','BatchMode=yes','-o','ConnectTimeout=8','-o','ConnectionAttempts=1','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2','-o','StrictHostKeyChecking=accept-new')
  $hpCmd=@'
set -eu
job='__JOB__'
container='familyptt-livekit'
config="$(docker inspect "$container" | python3 -c 'import json,sys,os; x=json.load(sys.stdin)[0]; mounts=x.get("Mounts",[]); p=next((m.get("Source","") for m in mounts if m.get("Destination","")=="/etc/livekit.yaml"),""); print(p)')"
if [ -z "$config" ]; then
  for p in /home/coolyo/familyptt-livekit/livekit.yaml /home/coolyo/familyptt-livekit/livekit.yml /home/coolyo/familyptt-livekit/config.yaml; do
    if [ -s "$p" ]; then config="$p"; break; fi
  done
fi
[ -n "$config" ] && [ -s "$config" ]
backup="${config}.${job}.rtc.bak"
if [ ! -e "$backup" ]; then
  if [ -w "$config" ]; then cp -a "$config" "$backup"; else sudo -n cp -a "$config" "$backup"; fi
fi
ufw_tcp_added=false
ufw_udp_added=false
rollback(){
  set +e
  if [ -s "$backup" ]; then
    if [ -w "$config" ]; then cp -a "$backup" "$config"; else sudo -n cp -a "$backup" "$config"; fi
  fi
  if [ "$ufw_tcp_added" = true ]; then sudo -n ufw --force delete allow 7881/tcp >/dev/null 2>&1 || true; fi
  if [ "$ufw_udp_added" = true ]; then sudo -n ufw --force delete allow 7882/udp >/dev/null 2>&1 || true; fi
  docker restart "$container" >/dev/null 2>&1 || true
}
trap rollback ERR
work="$(mktemp)"
trap 'rm -f "$work"' EXIT
if [ -r "$config" ]; then cat "$config" > "$work"; else sudo -n cat "$config" > "$work"; fi
python3 - "$work" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
for key,port in [('tcp_port','7881'),('udp_port','7882')]:
    if not re.search(r'(?m)^\s*'+re.escape(key)+r'\s*:\s*'+port+r'\s*$',s):
        raise SystemExit(f'expected {key}: {port} not found')
if not re.search(r'(?m)^\s*use_external_ip\s*:',s):
    raise SystemExit('use_external_ip setting not found')
s=re.sub(r'(?m)^(\s*)use_external_ip\s*:\s*\S+\s*$',r'\1use_external_ip: true',s,count=1)
s=re.sub(r'(?m)^(\s*)node_ip\s*:\s*.*$',r'\1# node_ip disabled by AFZ FamilyPTT R17b; public IP discovered via STUN',s,count=1)
p.write_text(s)
PY
if [ -w "$config" ]; then cat "$work" > "$config"; else sudo -n cp "$work" "$config"; fi
docker restart "$container" >/dev/null
for i in $(seq 1 30); do
  running="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)"
  tcp=false; udp=false
  ss -lntH 2>/dev/null | grep -Eq ':7881[[:space:]]' && tcp=true || true
  ss -lnuH 2>/dev/null | grep -Eq ':7882[[:space:]]' && udp=true || true
  if [ "$running" = true ] && [ "$tcp" = true ] && [ "$udp" = true ]; then break; fi
  sleep 1
done
[ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ]
ss -lntH 2>/dev/null | grep -Eq ':7881[[:space:]]'
ss -lnuH 2>/dev/null | grep -Eq ':7882[[:space:]]'
lan_ip="$(ip -4 route get 192.168.50.68 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p' | head -n 1)"
case "$lan_ip" in 192.168.50.*) ;; *) echo "BAD_LAN_IP=$lan_ip"; exit 42;; esac
ufw_active=false
if command -v ufw >/dev/null 2>&1 && sudo -n ufw status >/tmp/familyptt-ufw-$job.txt 2>/dev/null; then
  if grep -q '^Status: active' /tmp/familyptt-ufw-$job.txt; then
    ufw_active=true
    if ! grep -Eq '^7881/tcp[[:space:]]+ALLOW' /tmp/familyptt-ufw-$job.txt; then sudo -n ufw allow 7881/tcp comment 'FamilyPTT LiveKit RTC' >/dev/null; ufw_tcp_added=true; fi
    if ! grep -Eq '^7882/udp[[:space:]]+ALLOW' /tmp/familyptt-ufw-$job.txt; then sudo -n ufw allow 7882/udp comment 'FamilyPTT LiveKit RTC' >/dev/null; ufw_udp_added=true; fi
  fi
fi
printf 'HP_LAN_IP=%s\n' "$lan_ip"
printf 'HP_CONFIG=%s\n' "$config"
printf 'HP_BACKUP=%s\n' "$backup"
printf 'LK_RUNNING=true\n'
printf 'LK_TCP_7881=true\n'
printf 'LK_UDP_7882=true\n'
printf 'UFW_ACTIVE=%s\n' "$ufw_active"
printf 'UFW_TCP_ADDED=%s\n' "$ufw_tcp_added"
printf 'UFW_UDP_ADDED=%s\n' "$ufw_udp_added"
printf 'RTC_EXTERNAL_SETTING='; docker exec "$container" sh -lc "grep -E '^[[:space:]]*use_external_ip:' /etc/livekit.yaml | head -n 1 | tr -d '\r\n'"; echo
trap - ERR
'@.Replace('__JOB__',$JobId)
  $hp=Run-Ssh $hpTarget $hpArgs $hpCmd 120
  if($hp.exit -ne 0){throw "HP RTC configuration failed exit=$($hp.exit): $((@($hp.output)|Select-Object -Last 4)-join ' | ')"}
  $hpMap=Marker-Map $hp.output
  if($hpMap.LK_RUNNING -ne 'true' -or $hpMap.LK_TCP_7881 -ne 'true' -or $hpMap.LK_UDP_7882 -ne 'true'){throw 'LiveKit RTC listeners did not become ready'}
  $hpLan=[string]$hpMap.HP_LAN_IP
  if($hpLan -notmatch '^192[.]168[.]50[.]\d{1,3}$'){throw "Unexpected HP LAN address: $hpLan"}
  $result.safety.liveKitConfigMutation=$true;$result.safety.liveKitRestart=$true
  $result.safety.firewallMutation=($hpMap.UFW_TCP_ADDED -eq 'true' -or $hpMap.UFW_UDP_ADDED -eq 'true')

  $nat=New-Object -ComObject HNetCfg.NATUPnP
  $upnp=$nat.StaticPortMappingCollection
  if(-not $upnp){throw 'Router UPnP static port mapping collection is unavailable'}
  $tcp=Ensure-UpnpMapping $upnp 7881 'TCP' $hpLan 'FamilyPTT LiveKit ICE TCP'
  $createdTcp=[bool]$tcp.created
  $udp=Ensure-UpnpMapping $upnp 7882 'UDP' $hpLan 'FamilyPTT LiveKit ICE UDP'
  $createdUdp=[bool]$udp.created
  $result.safety.routerNatMutation=($createdTcp -or $createdUdp)

  $tcpCheck=Find-UpnpMapping $upnp 7881 'TCP';$udpCheck=Find-UpnpMapping $upnp 7882 'UDP'
  if(-not $tcpCheck -or -not $udpCheck){throw 'Router mappings were not observable after creation'}
  if(([string]$tcpCheck.InternalClient) -ne $hpLan -or ([string]$udpCheck.InternalClient) -ne $hpLan){throw 'Router mapping verification target mismatch'}
  $externalIp=[string]$tcpCheck.ExternalIPAddress
  if(-not $externalIp){$externalIp=[string]$udpCheck.ExternalIPAddress}
  $dnsV4=@([Net.Dns]::GetHostAddresses('ptt-livekit.afzeng.ca')|Where-Object {$_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork}|ForEach-Object {$_.IPAddressToString})
  if($externalIp -and $dnsV4.Count -gt 0 -and $dnsV4 -notcontains $externalIp){throw "Router external IP $externalIp does not match ptt-livekit DNS $($dnsV4 -join ',')"}

  $result.hp=[ordered]@{lanIp=$hpLan;config=[string]$hpMap.HP_CONFIG;backup=[string]$hpMap.HP_BACKUP;tcp7881=$true;udp7882=$true;useExternalIp=$true;ufwActive=($hpMap.UFW_ACTIVE -eq 'true')}
  $result.router=[ordered]@{tcp7881=$true;udp7882=$true;tcpCreated=$createdTcp;udpCreated=$createdUdp;externalIp=$externalIp}
  $result.classification='RTC_PUBLIC_MEDIA_ROUTE_READY'
  $result.ok=$true;$result.finishedAt=(Get-Date -Format o);Save-Result $result;exit 0
}catch{
  $err=$_.Exception.Message
  if($upnp){
    try{if($createdTcp){$upnp.Remove(7881,'TCP')}}catch{}
    try{if($createdUdp){$upnp.Remove(7882,'UDP')}}catch{}
  }
  if($hpMap -and $hpMap.HP_BACKUP -and $hpMap.HP_CONFIG){
    try{
      $restore=@'
set -eu
container='familyptt-livekit'
backup='__BACKUP__'
config='__CONFIG__'
[ -s "$backup" ] && [ -n "$config" ]
if [ -w "$config" ]; then cp -a "$backup" "$config"; else sudo -n cp -a "$backup" "$config"; fi
if [ '__UFW_TCP__' = true ]; then sudo -n ufw --force delete allow 7881/tcp >/dev/null 2>&1 || true; fi
if [ '__UFW_UDP__' = true ]; then sudo -n ufw --force delete allow 7882/udp >/dev/null 2>&1 || true; fi
docker restart "$container" >/dev/null
'@.Replace('__BACKUP__',[string]$hpMap.HP_BACKUP).Replace('__CONFIG__',[string]$hpMap.HP_CONFIG).Replace('__UFW_TCP__',[string]$hpMap.UFW_TCP_ADDED).Replace('__UFW_UDP__',[string]$hpMap.UFW_UDP_ADDED)
      $null=Run-Ssh $hpTarget @('-o','BatchMode=yes','-o','ConnectTimeout=8','-o','ConnectionAttempts=1','-o','StrictHostKeyChecking=accept-new') $restore 60
    }catch{}
  }
  $result.ok=$false;$result.error=$err;$result.finishedAt=(Get-Date -Format o);Save-Result $result;exit 1
}
