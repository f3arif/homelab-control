#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSiteSha,
  [Parameter(Mandatory=$true)][string]$JobId
)

$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

if($ExpectedSiteSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSiteSha must be a 40-character Git SHA'}
$ExpectedSiteSha=$ExpectedSiteSha.ToLowerInvariant()
if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid JobId'}

$RepoUrl='https://github.com/f3arif/afz-engineering.git'
$Pi='coolyo@192.168.50.68'
$Target='/opt/edge/afz-site/html'
$RemoteRoot='/opt/edge/afz-site/git-deploy'
$KeyPath=Join-Path $env:USERPROFILE '.ssh\afz_pi_sync'
$ResultRoot=Join-Path $env:LOCALAPPDATA 'AFZ\WebsiteGitDeploy'
$ResultFile=Join-Path $ResultRoot 'latest.json'
$TempRoot=Join-Path $env:TEMP ('afz-site-git-deploy-'+$JobId+'-'+[guid]::NewGuid().ToString('n'))
$RepoDir=Join-Path $TempRoot 'repo'
$Archive=Join-Path $TempRoot 'production-site.tar.gz'
$RemoteArchive="/tmp/afz-site-$JobId.tar.gz"
$RemoteScript="/tmp/afz-site-$JobId.sh"
$RemoteBackup="$RemoteRoot/backups/$JobId"
$remotePromoted=$false
$started=Get-Date

New-Item -ItemType Directory -Force -Path $ResultRoot,$TempRoot | Out-Null

function Save-Result([bool]$Ok,[string]$Status,[string]$Message,[hashtable]$Extra=@{}){
  $o=[ordered]@{
    ok=$Ok
    status=$Status
    jobId=$JobId
    expectedSiteSha=$ExpectedSiteSha
    sourceRepository='f3arif/afz-engineering'
    target=$Target
    startedAt=$started.ToString('o')
    finishedAt=(Get-Date -Format o)
    message=$Message
  }
  foreach($k in $Extra.Keys){$o[$k]=$Extra[$k]}
  $o|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ResultFile -Encoding UTF8
}

function Invoke-External([string]$Exe,[string[]]$Args,[string]$Failure){
  & $Exe @Args
  if($LASTEXITCODE -ne 0){throw "$Failure Exit code: $LASTEXITCODE"}
}

function Invoke-Ssh([string]$Command,[string]$Failure){
  $args=@('-i',$KeyPath,'-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=accept-new',$Pi,$Command)
  Invoke-External 'ssh.exe' $args $Failure
}

function Rollback-Remote {
  if(-not $remotePromoted){return}
  try{
    Invoke-Ssh "bash '$RemoteBackup/rollback.sh'" 'Remote rollback failed.'
    $script:remotePromoted=$false
  }catch{
    throw "Post-deploy validation failed and rollback also failed: $($_.Exception.Message)"
  }
}

try{
  foreach($cmd in @('git.exe','node.exe','tar.exe','ssh.exe','scp.exe')){
    if(-not(Get-Command $cmd -ErrorAction SilentlyContinue)){throw "Required command missing: $cmd"}
  }
  if(-not(Test-Path -LiteralPath $KeyPath -PathType Leaf)){throw "Dedicated Pi SSH key missing: $KeyPath"}

  New-Item -ItemType Directory -Force -Path $RepoDir | Out-Null
  Invoke-External 'git.exe' @('-C',$RepoDir,'init','--quiet') 'git init failed.'
  Invoke-External 'git.exe' @('-C',$RepoDir,'remote','add','origin',$RepoUrl) 'git remote add failed.'
  Invoke-External 'git.exe' @('-C',$RepoDir,'fetch','--quiet','--depth','1','origin',$ExpectedSiteSha) 'Exact-site commit fetch failed.'
  Invoke-External 'git.exe' @('-C',$RepoDir,'checkout','--quiet','--detach','FETCH_HEAD') 'Exact-site commit checkout failed.'
  $actualSha=(& git.exe -C $RepoDir rev-parse HEAD).Trim().ToLowerInvariant()
  if($LASTEXITCODE -ne 0 -or $actualSha -ne $ExpectedSiteSha){throw "Checked-out SHA mismatch: $actualSha"}

  $guard=Join-Path $RepoDir 'scripts\afz-production-deploy-guard.mjs'
  if(-not(Test-Path -LiteralPath $guard)){throw 'Production deploy guard missing from exact site commit.'}
  & node.exe $guard
  if($LASTEXITCODE -ne 0){throw "Production deploy guard failed with exit $LASTEXITCODE"}

  $siteRoot=Join-Path $RepoDir 'production-site'
  $manifestPath=Join-Path $siteRoot 'manifest.json'
  if(-not(Test-Path -LiteralPath $manifestPath)){throw 'Production manifest missing.'}
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if(-not [bool]$manifest.reconciled){throw 'Production manifest is not reconciled.'}
  if([string]$manifest.deployment.target -ne $Target){throw 'Manifest target does not match fixed Pi target.'}
  if([bool]$manifest.deployment.deleteExtraneousFiles){throw 'Manifest attempts destructive deleteExtraneousFiles mode.'}
  if([string]$manifest.webchat.backendOwner -ne 'hpenvy'){throw 'WebChat backend owner changed unexpectedly.'}
  if([string]$manifest.webchat.endpoint -ne '/api/ai-chat'){throw 'WebChat endpoint changed unexpectedly.'}

  $checksumLines=New-Object System.Collections.Generic.List[string]
  $managed=New-Object System.Collections.Generic.List[string]
  foreach($p in $manifest.files.PSObject.Properties){
    $rel=[string]$p.Name
    if($rel -notmatch '^[A-Za-z0-9._/-]+$' -or $rel.Contains('..')){throw "Unsafe manifest path: $rel"}
    $file=Join-Path $siteRoot ($rel -replace '/','\')
    if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Managed production file missing: $rel"}
    $actual=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    $wanted=([string]$p.Value.sha256).ToLowerInvariant()
    if($actual -ne $wanted){throw "Managed production hash mismatch: $rel"}
    $managed.Add($rel)
    $checksumLines.Add("$actual  $rel")
  }
  if($managed.Count -lt 8){throw "Unexpectedly small managed production set: $($managed.Count)"}
  [IO.File]::WriteAllLines((Join-Path $siteRoot 'managed.sha256'),$checksumLines,(New-Object Text.UTF8Encoding($false)))

  Invoke-External 'tar.exe' @('-czf',$Archive,'-C',$RepoDir,'production-site') 'Production archive creation failed.'

  $bash=@"
#!/usr/bin/env bash
set -euo pipefail
JOB_ID='$JobId'
EXPECTED_SHA='$ExpectedSiteSha'
TARGET='$Target'
ROOT='$RemoteRoot'
STAGE="\$ROOT/stage/\$JOB_ID"
BACKUP="\$ROOT/backups/\$JOB_ID"
ARCHIVE='$RemoteArchive'
PROMOTED=0

mkdir -p "\$ROOT/stage" "\$ROOT/backups"
rm -rf "\$STAGE" "\$BACKUP"
mkdir -p "\$STAGE" "\$BACKUP/files"
tar -xzf "\$ARCHIVE" -C "\$STAGE"
cd "\$STAGE/production-site"
sha256sum -c managed.sha256

cp managed.sha256 "\$BACKUP/managed.sha256"
: > "\$BACKUP/existed.txt"
while read -r hash rel; do
  if [ -e "\$TARGET/\$rel" ]; then
    mkdir -p "\$BACKUP/files/\$(dirname "\$rel")"
    cp -a "\$TARGET/\$rel" "\$BACKUP/files/\$rel"
    printf '%s\n' "\$rel" >> "\$BACKUP/existed.txt"
  fi
done < managed.sha256

if [ -e "\$TARGET/afz-git-deploy.json" ]; then
  cp -a "\$TARGET/afz-git-deploy.json" "\$BACKUP/afz-git-deploy.json"
  touch "\$BACKUP/meta.existed"
fi

cat > "\$BACKUP/rollback.sh" <<'ROLLBACK'
#!/usr/bin/env bash
set -euo pipefail
TARGET='/opt/edge/afz-site/html'
BACKUP_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
while read -r hash rel; do
  rm -f "\$TARGET/\$rel"
done < "\$BACKUP_DIR/managed.sha256"
while read -r rel; do
  [ -n "\$rel" ] || continue
  mkdir -p "\$TARGET/\$(dirname "\$rel")"
  cp -a "\$BACKUP_DIR/files/\$rel" "\$TARGET/\$rel"
done < "\$BACKUP_DIR/existed.txt"
if [ -f "\$BACKUP_DIR/meta.existed" ]; then
  cp -a "\$BACKUP_DIR/afz-git-deploy.json" "\$TARGET/afz-git-deploy.json"
else
  rm -f "\$TARGET/afz-git-deploy.json"
fi
curl -fsS --max-time 10 http://127.0.0.1:8088/ >/dev/null
ROLLBACK
chmod 700 "\$BACKUP/rollback.sh"

rollback_on_error() {
  rc=\$?
  if [ "\$PROMOTED" -eq 1 ]; then
    bash "\$BACKUP/rollback.sh" || true
  fi
  exit "\$rc"
}
trap rollback_on_error ERR INT TERM

PROMOTED=1
while read -r hash rel; do
  mkdir -p "\$TARGET/\$(dirname "\$rel")"
  cp -a "\$STAGE/production-site/\$rel" "\$TARGET/\$rel"
done < "\$STAGE/production-site/managed.sha256"

cd "\$TARGET"
sha256sum -c "\$STAGE/production-site/managed.sha256"
curl -fsS --max-time 10 http://127.0.0.1:8088/ | grep -q 'afz-ai-widget.js'
curl -fsS --max-time 10 http://127.0.0.1:8088/contact.html | grep -q 'AFZ AI PROJECT QUESTION PREFILL'
curl -fsS --max-time 10 http://127.0.0.1:8088/afz-ai-widget.js | grep -q 'AFZ CHAT SESSION PERSISTENCE'

cat > "\$TARGET/afz-git-deploy.json" <<META
{"ok":true,"source":"github","repository":"f3arif/afz-engineering","commit":"$ExpectedSiteSha","job_id":"$JobId","deployed_at":"\$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
META

PROMOTED=0
rm -rf "\$STAGE"
rm -f "\$ARCHIVE" '$RemoteScript'
printf 'AFZ_PI_SITE_DEPLOY=PASS\n'
"@
  $localRemoteScript=Join-Path $TempRoot 'deploy-on-pi.sh'
  [IO.File]::WriteAllText($localRemoteScript,$bash,(New-Object Text.UTF8Encoding($false)))

  Invoke-Ssh "mkdir -p '$RemoteRoot/stage' '$RemoteRoot/backups'" 'Failed to prepare Pi deployment root.'
  $scpArgs=@('-i',$KeyPath,'-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=accept-new',$Archive,"${Pi}:$RemoteArchive")
  Invoke-External 'scp.exe' $scpArgs 'Failed to upload production archive.'
  $scpArgs=@('-i',$KeyPath,'-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=accept-new',$localRemoteScript,"${Pi}:$RemoteScript")
  Invoke-External 'scp.exe' $scpArgs 'Failed to upload Pi deployment script.'

  Invoke-Ssh "chmod 700 '$RemoteScript' && bash '$RemoteScript'" 'Pi deployment failed.'
  $remotePromoted=$true

  $headers=@{'Cache-Control'='no-cache';'Pragma'='no-cache'}
  $nonce=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $home=Invoke-WebRequest -Uri ("https://afzeng.ca/?afz_git_deploy="+$nonce) -Headers $headers -UseBasicParsing -TimeoutSec 20
  if($home.StatusCode -ne 200 -or $home.Content -notmatch 'afz-ai-widget\.js'){throw 'Public home-page verification failed.'}
  $widget=Invoke-WebRequest -Uri ("https://afzeng.ca/afz-ai-widget.js?afz_git_deploy="+$nonce) -Headers $headers -UseBasicParsing -TimeoutSec 20
  if($widget.StatusCode -ne 200 -or $widget.Content -notmatch 'AFZ CHAT SESSION PERSISTENCE' -or $widget.Content -notmatch '/api/ai-chat'){throw 'Public WebChat asset verification failed.'}
  $meta=Invoke-WebRequest -Uri ("https://afzeng.ca/afz-git-deploy.json?afz_git_deploy="+$nonce) -Headers $headers -UseBasicParsing -TimeoutSec 20
  if($meta.StatusCode -ne 200 -or $meta.Content -notmatch [regex]::Escape($ExpectedSiteSha)){throw 'Public Git deployment marker verification failed.'}

  $payload='{"message":"Do you provide HVAC design?"}'
  $chat=Invoke-WebRequest -Uri 'https://afzeng.ca/api/ai-chat' -Method Post -ContentType 'application/json' -Body $payload -Headers $headers -UseBasicParsing -TimeoutSec 30
  if($chat.StatusCode -ne 200){throw "Public AFZ AI chat returned HTTP $($chat.StatusCode)"}
  $chatData=$chat.Content|ConvertFrom-Json
  if(-not $chatData.answer){throw 'Public AFZ AI chat response contained no answer.'}

  $remotePromoted=$false
  Save-Result $true 'completed' 'Git-authoritative AFZ website deployed to Pi and public WebChat verified.' @{
    publicHomeStatus=200
    publicWidgetStatus=200
    publicChatStatus=200
    deploymentMarkerVerified=$true
    managedFileCount=$managed.Count
    backupPath=$RemoteBackup
  }
  exit 0
}catch{
  $err=$_.Exception.Message
  try{Rollback-Remote}catch{$err=$err+' | '+$_.Exception.Message}
  Save-Result $false 'failed' $err
  throw
}finally{
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
