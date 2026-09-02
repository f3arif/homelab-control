#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('audit','apply')][string]$Action='audit',
  [string]$RequestId='afz-blog-git-migration-r1'
)
$ErrorActionPreference='Stop'

$SourceRoot='C:\docker\afz-blog-manager'
$DesiredRepo='f3arif/AFZ-Blog'
$ExportRoot='C:\AFZ\GitMigration\AFZ-Blog\source'
$BackupRoot='C:\AFZ\Backups\AFZ-Blog-GitMigration'
$StateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-blog-git-migration'
$OneDriveResult='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results\AFZ-BLOG-GIT-MIGRATION-LATEST.txt'
$ExpectedComputer='DESKTOP-10SKF0M'

function Invoke-Captured {
  param([string]$File,[string[]]$Arguments,[switch]$AllowFailure)
  $oldEap=$ErrorActionPreference
  try{
    # Windows PowerShell 5.1 can promote harmless native STDERR (for example Git's
    # LF/CRLF warning) to a terminating NativeCommandError while EAP=Stop. Capture
    # native output under Continue and decide success only from the process exit code.
    $ErrorActionPreference='Continue'
    $output=@(& $File @Arguments 2>&1 | ForEach-Object {[string]$_})
    $code=$LASTEXITCODE
  }finally{$ErrorActionPreference=$oldEap}
  if(-not $AllowFailure -and $code -ne 0){throw "$File failed exit=$code"}
  return [pscustomobject]@{ExitCode=$code;Lines=$output;Text=($output -join "`n")}
}
function Write-Text([string]$Path,[string]$Text){
  $parent=Split-Path $Path -Parent;if($parent){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
  [IO.File]::WriteAllText($Path,[string]$Text,(New-Object Text.UTF8Encoding($false)))
}
function Get-GitHubCredential {
  $oldEap=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    $inputText="protocol=https`nhost=github.com`n`n"
    $lines=@($inputText | & git credential fill 2>$null | ForEach-Object {[string]$_})
    $code=$LASTEXITCODE
  }finally{$ErrorActionPreference=$oldEap}
  if($code -ne 0){return $null}
  $u='';$p=''
  foreach($line in $lines){
    if($line -match '^username=(.*)$'){$u=$Matches[1]}
    elseif($line -match '^password=(.*)$'){$p=$Matches[1]}
  }
  if([string]::IsNullOrWhiteSpace($u) -or [string]::IsNullOrWhiteSpace($p)){return $null}
  return [pscustomobject]@{Username=$u;Password=$p}
}
function Invoke-GitHubApi {
  param([string]$Method,[string]$Uri,$Body,$Credential)
  if(-not $Credential){throw 'GitHub credential is unavailable from Git Credential Manager'}
  $headers=@{
    Authorization=('Bearer '+[string]$Credential.Password)
    Accept='application/vnd.github+json'
    'X-GitHub-Api-Version'='2022-11-28'
    'User-Agent'='AFZ-Blog-GitMigration'
  }
  if($null -eq $Body){return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -TimeoutSec 30}
  return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ContentType 'application/json' -Body ($Body|ConvertTo-Json -Depth 8 -Compress) -TimeoutSec 30
}
function Get-SafeGitSummary {
  if(-not(Test-Path -LiteralPath (Join-Path $SourceRoot '.git'))){return [ordered]@{isGitRepo=$false;head=$null;branch=$null;remoteNames=@();dirtyCount=$null}}
  $head=(Invoke-Captured git @('-C',$SourceRoot,'rev-parse','HEAD') -AllowFailure).Text.Trim()
  $branch=(Invoke-Captured git @('-C',$SourceRoot,'branch','--show-current') -AllowFailure).Text.Trim()
  $remotes=(Invoke-Captured git @('-C',$SourceRoot,'remote') -AllowFailure).Lines|Where-Object{$_}
  $status=(Invoke-Captured git @('-C',$SourceRoot,'status','--porcelain=v1','-uall') -AllowFailure).Lines|Where-Object{$_}
  return [ordered]@{isGitRepo=$true;head=$(if($head){$head}else{$null});branch=$(if($branch){$branch}else{$null});remoteNames=@($remotes);dirtyCount=@($status).Count}
}
function Save-LegacyProof([string]$Backup){
  New-Item -ItemType Directory -Force -Path $Backup|Out-Null
  if(-not(Test-Path -LiteralPath (Join-Path $SourceRoot '.git'))){Write-Text (Join-Path $Backup 'not-a-git-repo.txt') 'No .git directory was present.';return}
  $commands=@(
    @{Name='git-status.txt';Args=@('-C',$SourceRoot,'status','--porcelain=v1','-uall')},
    @{Name='git-remotes.txt';Args=@('-C',$SourceRoot,'remote','-v')},
    @{Name='git-history.txt';Args=@('-C',$SourceRoot,'log','--oneline','--decorate','-50')},
    @{Name='working-tree.patch';Args=@('-C',$SourceRoot,'diff','--binary')},
    @{Name='index.patch';Args=@('-C',$SourceRoot,'diff','--cached','--binary')}
  )
  foreach($c in $commands){$r=Invoke-Captured git $c.Args -AllowFailure;Write-Text (Join-Path $Backup $c.Name) $r.Text}
  $bundle=Join-Path $Backup 'legacy-history.bundle'
  $b=Invoke-Captured git @('-C',$SourceRoot,'bundle','create',$bundle,'--all') -AllowFailure
  if($b.ExitCode -ne 0){Write-Text (Join-Path $Backup 'legacy-history-bundle-error.txt') 'Git bundle creation failed; status/diffs were preserved.'}
}
function Export-SanitizedSource([string]$Stamp){
  $parent=Split-Path $ExportRoot -Parent;New-Item -ItemType Directory -Force -Path $parent|Out-Null
  if(Test-Path -LiteralPath $ExportRoot){$old="$ExportRoot.previous-$Stamp";Move-Item -LiteralPath $ExportRoot -Destination $old -Force}
  New-Item -ItemType Directory -Force -Path $ExportRoot|Out-Null
  $args=@($SourceRoot,$ExportRoot,'/E','/COPY:DAT','/DCOPY:T','/R:1','/W:1','/NFL','/NDL','/NJH','/NJS','/NP',
    '/XD','.git','node_modules','.next','logs','runtime-logs','.vercel','.turbo',
    '/XF','.env','.env.*','*.pem','*.pfx','*.p12','id_rsa*','id_ed25519*','credentials*.json','*secret*.json')
  & robocopy.exe @args | Out-Null
  $rc=$LASTEXITCODE
  if($rc -ge 8){throw "sanitized export failed robocopy exit=$rc"}
  $ignore=@'
# Secrets
.env
.env.*
!.env.example
*.pem
*.pfx
*.p12
id_rsa*
id_ed25519*
credentials*.json
*secret*.json

# Dependencies / generated
node_modules/
.next/
out/
.vercel/
.turbo/

# Runtime
logs/
runtime-logs/
*.log

# OS / editor
.DS_Store
Thumbs.db
.vscode/
.idea/
'@
  Write-Text (Join-Path $ExportRoot '.gitignore') $ignore
}
function Assert-NoSecrets {
  $badNames=@()
  $files=@(Get-ChildItem -LiteralPath $ExportRoot -Recurse -Force -File -ErrorAction Stop)
  foreach($f in $files){
    $n=$f.Name
    if($n -match '^\.env($|\.)' -or $n -match '(?i)^(id_rsa|id_ed25519)' -or $n -match '(?i)\.(pem|pfx|p12)$' -or $n -match '(?i)(credential|secret).*[.]json$'){$badNames+=$f.FullName}
  }
  if($badNames.Count -gt 0){throw "secret-like filenames remain in sanitized export count=$($badNames.Count)"}
  $patterns=[ordered]@{
    github_token='(?i)(ghp_|github_pat_)'
    openai_key='(?i)sk-[A-Za-z0-9_-]{20,}'
    private_key='-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'
    bearer_token='(?i)Authorization\s*[:=]\s*["'']?Bearer\s+[A-Za-z0-9._-]{20,}'
  }
  $hits=@()
  foreach($f in $files){
    if($f.Length -gt 2097152){continue}
    try{$text=[IO.File]::ReadAllText($f.FullName)}catch{continue}
    foreach($k in $patterns.Keys){if($text -match $patterns[$k]){$hits+=[ordered]@{file=$f.FullName.Substring($ExportRoot.Length).TrimStart('\');category=$k}}}
  }
  if($hits.Count -gt 0){
    $safe=$hits|ConvertTo-Json -Depth 5
    Write-Text (Join-Path $StateRoot 'secret-scan-blocked.json') $safe
    throw "secret scan blocked publication count=$($hits.Count)"
  }
}
function Initialize-ExportGit {
  Invoke-Captured git @('-C',$ExportRoot,'init','-b','main')|Out-Null
  Invoke-Captured git @('-C',$ExportRoot,'config','user.name','AFZ Automation')|Out-Null
  Invoke-Captured git @('-C',$ExportRoot,'config','user.email','77086535+f3arif@users.noreply.github.com')|Out-Null
  Invoke-Captured git @('-C',$ExportRoot,'add','-A')|Out-Null
  $staged=(Invoke-Captured git @('-C',$ExportRoot,'diff','--cached','--name-only')).Lines|Where-Object{$_}
  foreach($p in $staged){if($p -match '(^|/)\.env($|\.)' -or $p -match '(^|/)node_modules/' -or $p -match '(^|/)\.next/' -or $p -match '(?i)\.(pem|pfx|p12)$'){throw "unsafe staged path blocked: $p"}}
  if(@($staged).Count -eq 0){throw 'sanitized export has no files to commit'}
  Invoke-Captured git @('-C',$ExportRoot,'commit','-m','Initial AFZ Blog production source baseline')|Out-Null
  return (Invoke-Captured git @('-C',$ExportRoot,'rev-parse','HEAD')).Text.Trim()
}
function Publish-Repo($Credential){
  $meta=$null
  try{$meta=Invoke-GitHubApi 'GET' 'https://api.github.com/repos/f3arif/AFZ-Blog' $null $Credential}catch{
    $status=0;try{$status=[int]$_.Exception.Response.StatusCode}catch{}
    if($status -ne 404){throw}
  }
  if($meta){
    if([string]$meta.full_name -ne $DesiredRepo -or -not [bool]$meta.private){throw 'Existing AFZ-Blog repository is not the required private repository'}
  }else{
    $meta=Invoke-GitHubApi 'POST' 'https://api.github.com/user/repos' ([ordered]@{name='AFZ-Blog';private=$true;auto_init=$false;description='AFZ Automation Blog Manager canonical source'}) $Credential
    if([string]$meta.full_name -ne $DesiredRepo -or -not [bool]$meta.private){throw 'Private AFZ-Blog repository creation verification failed'}
  }
  $remote=Invoke-Captured git @('-C',$ExportRoot,'remote') -AllowFailure
  if(-not($remote.Lines -contains 'origin')){Invoke-Captured git @('-C',$ExportRoot,'remote','add','origin','https://github.com/f3arif/AFZ-Blog.git')|Out-Null}
  $push=Invoke-Captured git @('-C',$ExportRoot,'push','-u','origin','main') -AllowFailure
  if($push.ExitCode -ne 0){throw 'Private AFZ-Blog exists, but Git push failed; no production files were modified'}
  Invoke-Captured git @('-C',$ExportRoot,'fetch','origin','main')|Out-Null
  $remoteSha=(Invoke-Captured git @('-C',$ExportRoot,'rev-parse','origin/main')).Text.Trim()
  $verify=Invoke-GitHubApi 'GET' 'https://api.github.com/repos/f3arif/AFZ-Blog' $null $Credential
  if([string]$verify.full_name -ne $DesiredRepo -or -not [bool]$verify.private){throw 'GitHub repository post-push verification failed'}
  return [ordered]@{nameWithOwner=$DesiredRepo;visibility='PRIVATE';url=[string]$verify.html_url;remoteSha=$remoteSha}
}
function Save-Result($Result){
  New-Item -ItemType Directory -Force -Path $StateRoot|Out-Null
  $json=$Result|ConvertTo-Json -Depth 20
  Write-Text (Join-Path $StateRoot 'latest.json') $json
  try{Write-Text $OneDriveResult $json}catch{}
  $json
}

$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$result=[ordered]@{schema='afz.blog.git-migration.v1';ok=$false;action=$Action;requestId=$RequestId;computer=$env:COMPUTERNAME;sourceRoot=$SourceRoot;desiredRepo=$DesiredRepo;productionModified=$false;secretsEmitted=$false;startedAt=(Get-Date -Format o)}
try{
  if($env:COMPUTERNAME -ne $ExpectedComputer){throw "wrong host: $($env:COMPUTERNAME)"}
  if(-not(Test-Path -LiteralPath $SourceRoot -PathType Container)){throw "source root missing: $SourceRoot"}
  $result.productionGitBefore=Get-SafeGitSummary
  $credential=Get-GitHubCredential
  $result.gitCredentialAvailable=[bool]$credential
  $result.repositoryTransport='git-credential-manager+github-rest'
  if($Action -eq 'audit'){$result.ok=$true;$result.state='AUDIT_COMPLETE';$result.finishedAt=(Get-Date -Format o);Save-Result $result;exit 0}

  $backup=Join-Path $BackupRoot $stamp
  Save-LegacyProof $backup
  $result.backupPath=$backup
  Export-SanitizedSource $stamp
  Assert-NoSecrets
  $baseline=Initialize-ExportGit
  $result.localBaselineSha=$baseline
  if(-not $credential){throw 'No GitHub credential is available from Git Credential Manager; sanitized local baseline is preserved and production remains untouched'}
  $repo=Publish-Repo $credential
  $credential=$null
  $result.repo=$repo
  $result.ok=$true
  $result.state='GITHUB_BASELINE_PUBLISHED'
  $result.next='Verify H3 clone, then attach production checkout in a separate guarded phase. Production .git was not replaced.'
  $result.finishedAt=(Get-Date -Format o)
  Save-Result $result
  exit 0
}catch{
  $credential=$null
  $result.ok=$false;$result.state='BLOCKED_SAFE';$result.error=$_.Exception.Message;$result.finishedAt=(Get-Date -Format o)
  Save-Result $result
  exit 1
}
