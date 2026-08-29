#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$JobId,
  [string]$ResultFile='C:\Users\Faiz\AppData\Local\AFZ\FamilyPTTEdgePreflight\latest.json'
)
$ErrorActionPreference='Stop'
$piTarget='coolyo@192.168.50.68'
$piKey='C:\Users\Faiz\.ssh\afz_pi_sync'
$hpTarget='coolyo@100.71.26.69'
$sshExe=(Get-Command ssh.exe -ErrorAction Stop).Source
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ResultFile) | Out-Null

function Save-Result($obj){$obj|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $ResultFile -Encoding UTF8}
function Run-Ssh([string]$Target,[string[]]$SshArgs,[string]$Command,[int]$TimeoutSeconds=45){
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
function Parse-Rtc([string]$text){
  $map=@{}
  foreach($part in @($text -split ';')){if($part -match '^\s*([A-Za-z0-9_]+)\s*:\s*(.*?)\s*$'){$map[$matches[1].ToLowerInvariant()]=$matches[2]}}
  return $map
}

$result=[ordered]@{
  schema=1;project='familyptt';action='edge-preflight';jobId=$JobId
  startedAt=(Get-Date -Format o);classification='EDGE_PREFLIGHT_FAILED'
  safety=[ordered]@{readOnly=$true;secretValuesRead=$false;secretValuesLogged=$false;dnsMutation=$false;proxyMutation=$false;certificateMutation=$false;backendMutation=$false;firewallMutation=$false}
}
try{
  if(-not(Test-Path -LiteralPath $piKey -PathType Leaf)){throw 'Dedicated Pi SSH key missing'}
  $piArgs=@('-i',$piKey,'-o','BatchMode=yes','-o','ConnectTimeout=8','-o','ConnectionAttempts=1','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2','-o','StrictHostKeyChecking=accept-new')
  $piCmd=@'
set -eu
printf 'PI_HOST='; hostname
printf 'NPM_CONTAINER='; docker ps --filter name=^/npm-pi$ --format '{{.Names}}'
printf 'NPM_PORTS='; docker port npm-pi 2>/dev/null | tr '\n' ';' || true; echo
printf 'PI_TO_API='; if curl -fsS --max-time 6 http://100.71.26.69:7883/health >/dev/null; then echo true; else echo false; fi
printf 'PI_TO_LIVEKIT='; if timeout 6 bash -lc '</dev/tcp/100.71.26.69/7880' 2>/dev/null; then echo true; else echo false; fi
printf 'NPM_HTTP_CUSTOM_INCLUDE='; if docker exec npm-pi sh -lc "grep -RqsE '/data/nginx/custom/http(\\[\\.\\]|\\.)conf' /etc/nginx/nginx.conf /etc/nginx/conf.d 2>/dev/null"; then echo true; else echo false; fi
printf 'NPM_HTTP_CUSTOM_EXISTS='; if [ -f /opt/edge/npm/data/nginx/custom/http.conf ]; then echo true; else echo false; fi
printf 'CERTBOT='; docker exec npm-pi sh -lc 'command -v certbot >/dev/null 2>&1 && echo true || echo false'
printf 'CERTBOT_ACCOUNT='; docker exec npm-pi sh -lc 'test -d /etc/letsencrypt/accounts && find /etc/letsencrypt/accounts -mindepth 3 -maxdepth 3 -type d 2>/dev/null | head -n 1 | grep -q . && echo true || echo false'
printf 'ACME_WEBROOT='; docker exec npm-pi sh -lc 'test -d /data/letsencrypt-acme-challenge && echo true || echo false'
'@
  $pi=Run-Ssh $piTarget $piArgs $piCmd 45
  if($pi.exit -ne 0){throw ('Pi preflight SSH failed: '+(($pi.output|Select-Object -Last 3)-join ' | '))}
  $piMap=@{};foreach($line in $pi.output){if($line -match '^([A-Z0-9_]+)=(.*)$'){$piMap[$matches[1]]=$matches[2].Trim()}}
  $result.pi=[ordered]@{
    host=$piMap.PI_HOST;npmContainer=$piMap.NPM_CONTAINER;npmPorts=$piMap.NPM_PORTS
    reachesApi=($piMap.PI_TO_API -eq 'true');reachesLiveKit=($piMap.PI_TO_LIVEKIT -eq 'true')
    customHttpIncluded=($piMap.NPM_HTTP_CUSTOM_INCLUDE -eq 'true');customHttpExists=($piMap.NPM_HTTP_CUSTOM_EXISTS -eq 'true')
    certbotAvailable=($piMap.CERTBOT -eq 'true');certbotAccountPresent=($piMap.CERTBOT_ACCOUNT -eq 'true');acmeWebrootPresent=($piMap.ACME_WEBROOT -eq 'true')
  }

  $hpArgs=@('-o','BatchMode=yes','-o','ConnectTimeout=8','-o','ConnectionAttempts=1','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2','-o','StrictHostKeyChecking=accept-new')
  $hpCmd=@'
set -eu
printf 'HP_HOST='; hostname
printf 'LK_RUNNING='; docker inspect -f '{{.State.Running}}' familyptt-livekit 2>/dev/null || echo false
printf 'TOKEN_RUNNING='; docker inspect -f '{{.State.Running}}' familyptt-livekit-token 2>/dev/null || echo false
printf 'LK_NETWORK='; docker inspect -f '{{.HostConfig.NetworkMode}}' familyptt-livekit 2>/dev/null || true
printf 'LK_PORTS='; docker inspect -f '{{json .HostConfig.PortBindings}}' familyptt-livekit 2>/dev/null || true
printf 'LK_RTC='; docker exec familyptt-livekit sh -lc "grep -E '^[[:space:]]*(port|tcp_port|udp_port|port_range_start|port_range_end|use_external_ip|node_ip|external_ip):' /etc/livekit.yaml 2>/dev/null | tr '\n' ';'" || true; echo
printf 'TOKEN_URL_SCHEME='; docker exec familyptt-livekit-token sh -lc 'case "${LIVEKIT_URL:-}" in wss://*) echo wss;; ws://*) echo ws;; "") echo unset;; *) echo other;; esac'
'@
  $hp=Run-Ssh $hpTarget $hpArgs $hpCmd 45
  if($hp.exit -ne 0){throw ('HP preflight SSH failed: '+(($hp.output|Select-Object -Last 3)-join ' | '))}
  $hpMap=@{};foreach($line in $hp.output){if($line -match '^([A-Z0-9_]+)=(.*)$'){$hpMap[$matches[1]]=$matches[2].Trim()}}
  $rtc=Parse-Rtc $hpMap.LK_RTC
  $useExternal=([string]$rtc.use_external_ip).Trim().ToLowerInvariant() -eq 'true'
  $hasConfiguredExternal=-not [string]::IsNullOrWhiteSpace([string]$rtc.external_ip)
  $nodeIp=[string]$rtc.node_ip
  $nodeLooksPrivate=($nodeIp -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)')
  $rtcPublicCandidateReady=($useExternal -or $hasConfiguredExternal -or (-not $nodeLooksPrivate -and -not [string]::IsNullOrWhiteSpace($nodeIp)))
  $result.hp=[ordered]@{
    host=$hpMap.HP_HOST;liveKitRunning=($hpMap.LK_RUNNING -eq 'true');tokenRunning=($hpMap.TOKEN_RUNNING -eq 'true')
    liveKitNetworkMode=$hpMap.LK_NETWORK;liveKitPortBindings=$hpMap.LK_PORTS;rtcSettings=$hpMap.LK_RTC;tokenUrlScheme=$hpMap.TOKEN_URL_SCHEME
    rtcPublicCandidateReady=$rtcPublicCandidateReady
  }

  if(-not $result.pi.reachesApi -or -not $result.pi.reachesLiveKit){$result.classification='EDGE_PREFLIGHT_PI_CANNOT_REACH_BACKEND'}
  elseif(-not $result.hp.liveKitRunning -or -not $result.hp.tokenRunning){$result.classification='EDGE_PREFLIGHT_BACKEND_CONTAINER_NOT_READY'}
  elseif(-not $result.pi.certbotAvailable -or -not $result.pi.certbotAccountPresent -or -not $result.pi.acmeWebrootPresent){$result.classification='EDGE_PREFLIGHT_CERT_PATH_REVIEW_REQUIRED'}
  elseif(-not $result.pi.customHttpIncluded){$result.classification='EDGE_PREFLIGHT_NPM_CUSTOM_ROUTE_NOT_READY'}
  elseif(-not $result.hp.rtcPublicCandidateReady){$result.classification='EDGE_PREFLIGHT_RTC_PUBLIC_MEDIA_ROUTE_REQUIRED'}
  else{$result.classification='EDGE_PREFLIGHT_READY_FOR_NARROW_PROVISIONING'}
  $result.ok=($result.classification -eq 'EDGE_PREFLIGHT_READY_FOR_NARROW_PROVISIONING')
  $result.finishedAt=(Get-Date -Format o);Save-Result $result
  exit $(if($result.ok){0}else{2})
}catch{
  $result.ok=$false;$result.error=$_.Exception.Message;$result.finishedAt=(Get-Date -Format o);Save-Result $result;exit 1
}
