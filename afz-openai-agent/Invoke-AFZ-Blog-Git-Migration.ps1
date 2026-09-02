#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('audit','bootstrap-private-repo')][string]$Action='bootstrap-private-repo',
  [string]$JobId='afz-blog-git-bootstrap',
  [string]$TargetRepository='f3arif/AFZ-Blog',
  [string]$ResultPath='C:\Users\Faiz\AppData\Local\AFZ\BlogGitMigration\latest.json'
)

$ErrorActionPreference='Stop'
$sourceRoot='C:\docker\afz-blog-manager'
$exportRoot='C:\AFZ\GitMigration\AFZ-Blog'
$backupRoot='C:\AFZ\Backups'
$expectedComputer='DESKTOP-10SKF0M'
$started=Get-Date

function Save-Result($Object){
  $dir=Split-Path -Parent $ResultPath
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $Object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
  $diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
  if(Test-Path -LiteralPath $diagRoot -PathType Container){
    try{$Object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $diagRoot 'AFZ-BLOG-GIT-MIGRATION-LATEST.json') -Encoding UTF8}catch{}
  }
}
function Run([string]$Exe,[string[]]$Args,[string]$WorkingDirectory=''){
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName=$Exe;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
  if($WorkingDirectory){$psi.WorkingDirectory=$WorkingDirectory}
  foreach($a in $Args){[void]$psi.ArgumentList.Add($a)}
  $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start();$stdout=$p.StandardOutput.ReadToEnd();$stderr=$p.StandardError.ReadToEnd();$p.WaitForExit()
  return [pscustomobject]@{exitCode=$p.ExitCode;stdout=$stdout.Trim();stderr=$stderr.Trim()}
}
function Git([string[]]$Args,[string]$WorkingDirectory){return Run 'git.exe' $Args $WorkingDirectory}
function Get-Gh {
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if($c){return $(if($c.Path){$c.Path}else{$c.Source})}
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path -LiteralPath $p){return $p}}
  return $null
}
function Is-ForbiddenRelative([string]$Relative){
  $r=$Relative.Replace('/','\')
  if($r -match '(^|\\)(\.git|node_modules|\.next|logs|runtime-logs)(\\|$)'){return $true}
  $name=[IO.Path]::GetFileName($r)
  if($name -match '^\.env($|\.)' -and $name -ne '.env.example'){return $true}
  if($name -match '^(id_rsa|id_ed25519)$'){return $true}
  if($name -match '\.(pfx|p12|pem|key)$'){return $true}
  return $false
}
function Get-Relative([string]$Base,[string]$Full){
  $baseUri=New-Object Uri(($Base.TrimEnd('\\')+'\\'))
  $fullUri=New-Object Uri($Full)
  return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fullUri).ToString()).Replace('/','\\')
}

try{
  if($env:COMPUTERNAME -ne $expectedComputer){throw "Wrong host: $($env:COMPUTERNAME); expected $expectedComputer"}
  if($TargetRepository -ne 'f3arif/AFZ-Blog'){throw 'Target repository is not allowlisted'}
  if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid JobId'}
  if(-not(Test-Path -LiteralPath $sourceRoot -PathType Container)){throw "Production Blog root missing: $sourceRoot"}
  $gitCmd=Get-Command git.exe -ErrorAction Stop

  $gitStatus='';$gitRemotes='';$head='';$isGitRepo=$false
  $probe=Git @('rev-parse','--is-inside-work-tree') $sourceRoot
  if($probe.exitCode -eq 0 -and $probe.stdout -eq 'true'){
    $isGitRepo=$true
    $gitStatus=(Git @('status','--porcelain=v1','-uall') $sourceRoot).stdout
    $gitRemotes=(Git @('remote','-v') $sourceRoot).stdout
    $head=(Git @('rev-parse','HEAD') $sourceRoot).stdout
  }

  $audit=[ordered]@{
    ok=$true;schema='afz.blog.git-migration.v1';action=$Action;jobId=$JobId;computer=$env:COMPUTERNAME
    sourceRoot=$sourceRoot;sourceExists=$true;productionGitRepo=$isGitRepo;productionHead=$(if($head){$head}else{$null})
    productionDirty=([bool]$gitStatus);productionStatusLineCount=$(if($gitStatus){@($gitStatus -split "`n").Count}else{0})
    productionRemoteConfigured=([bool]$gitRemotes);productionRemoteLines=$(if($gitRemotes){@($gitRemotes -split "`n").Count}else{0})
    envFilePresent=(Test-Path -LiteralPath (Join-Path $sourceRoot '.env') -PathType Leaf)
    envLocalPresent=(Test-Path -LiteralPath (Join-Path $sourceRoot '.env.local') -PathType Leaf)
    exportRoot=$exportRoot;targetRepository=$TargetRepository;startedAt=$started.ToString('o')
  }
  if($Action -eq 'audit'){$audit['finishedAt']=(Get-Date -Format o);Save-Result $audit;exit 0}

  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup=Join-Path $backupRoot ("AFZ-Blog-pre-github-$stamp")
  New-Item -ItemType Directory -Force -Path $backup | Out-Null
  if($isGitRepo){
    $gitStatus | Set-Content -LiteralPath (Join-Path $backup 'git-status.txt') -Encoding UTF8
    $gitRemotes | Set-Content -LiteralPath (Join-Path $backup 'git-remotes.txt') -Encoding UTF8
    (Git @('log','--oneline','--decorate','-50') $sourceRoot).stdout | Set-Content -LiteralPath (Join-Path $backup 'git-history.txt') -Encoding UTF8
    $bundle=Git @('bundle','create',(Join-Path $backup 'legacy-history.bundle'),'--all') $sourceRoot
    if($bundle.exitCode -ne 0){throw "git bundle failed: $($bundle.stderr)"}
    (Git @('diff','--binary') $sourceRoot).stdout | Set-Content -LiteralPath (Join-Path $backup 'working-tree.patch') -Encoding UTF8
    (Git @('diff','--cached','--binary') $sourceRoot).stdout | Set-Content -LiteralPath (Join-Path $backup 'index.patch') -Encoding UTF8
  }

  if(Test-Path -LiteralPath $exportRoot){Remove-Item -LiteralPath $exportRoot -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $exportRoot | Out-Null
  $copied=0;$skipped=0
  foreach($f in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force -ErrorAction Stop){
    $rel=Get-Relative $sourceRoot $f.FullName
    if(Is-ForbiddenRelative $rel){$skipped++;continue}
    $dest=Join-Path $exportRoot $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
    $copied++
  }

  $gitignore=@'
# Secrets
.env
.env.local
.env.*
!.env.example

# Dependencies / build output
node_modules/
.next/
out/

# Runtime output
logs/
runtime-logs/
*.log

# Local/editor
.DS_Store
Thumbs.db
.vscode/
.idea/
'@
  Set-Content -LiteralPath (Join-Path $exportRoot '.gitignore') -Value $gitignore -Encoding UTF8

  $forbidden=@()
  foreach($f in Get-ChildItem -LiteralPath $exportRoot -Recurse -File -Force){
    $rel=Get-Relative $exportRoot $f.FullName
    if(Is-ForbiddenRelative $rel){$forbidden+=$rel;continue}
    if($f.Length -le 2MB){
      try{
        $txt=[IO.File]::ReadAllText($f.FullName)
        if($txt -match '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----' -or $txt -match 'github_pat_[A-Za-z0-9_]+' -or $txt -match '\bghp_[A-Za-z0-9]{20,}' -or $txt -match '\bsk-[A-Za-z0-9_-]{20,}'){$forbidden+=$rel}
      }catch{}
    }
  }
  $forbidden=@($forbidden|Sort-Object -Unique)
  if($forbidden.Count -gt 0){throw ('Sanitized export failed secret/forbidden-file scan: '+($forbidden -join ', '))}

  $init=Git @('init','-b','main') $exportRoot;if($init.exitCode -ne 0){throw "git init failed: $($init.stderr)"}
  $name=Git @('config','user.name') $exportRoot;if($name.exitCode -ne 0 -or -not $name.stdout){[void](Git @('config','user.name','AFZ Git Migration') $exportRoot)}
  $email=Git @('config','user.email') $exportRoot;if($email.exitCode -ne 0 -or -not $email.stdout){[void](Git @('config','user.email','noreply@afz.local') $exportRoot)}
  $add=Git @('add','-A') $exportRoot;if($add.exitCode -ne 0){throw "git add failed: $($add.stderr)"}
  $tracked=(Git @('ls-files') $exportRoot).stdout -split "`n" | Where-Object {$_}
  $badTracked=@($tracked|Where-Object {Is-ForbiddenRelative $_})
  if($badTracked.Count -gt 0){throw ('Forbidden tracked files detected: '+($badTracked -join ', '))}
  $commit=Git @('commit','-m','Initial AFZ Blog production source baseline') $exportRoot
  if($commit.exitCode -ne 0 -and $commit.stdout -notmatch 'nothing to commit'){throw "git commit failed: $($commit.stderr)"}
  $baseline=(Git @('rev-parse','HEAD') $exportRoot).stdout

  $gh=Get-Gh
  $ghAuth=$false;$repoExists=$false;$repoPrivate=$false;$published=$false;$publishMessage=''
  if($gh){
    $auth=Run $gh @('auth','status','-h','github.com')
    $ghAuth=($auth.exitCode -eq 0)
  }
  if($ghAuth){
    $view=Run $gh @('repo','view',$TargetRepository,'--json','nameWithOwner,visibility')
    if($view.exitCode -eq 0){
      $repoExists=$true
      try{$v=$view.stdout|ConvertFrom-Json;$repoPrivate=([string]$v.visibility -eq 'PRIVATE')}catch{}
      if(-not $repoPrivate){throw "Existing target repository is not private: $TargetRepository"}
    }
    if(-not $repoExists){
      $create=Run $gh @('repo','create',$TargetRepository,'--private','--source',$exportRoot,'--remote','origin','--push')
      if($create.exitCode -ne 0){throw "gh repo create failed: $($create.stderr)"}
      $repoExists=$true;$repoPrivate=$true;$published=$true;$publishMessage='Created private repository and pushed main.'
    }else{
      $remote=Git @('remote','get-url','origin') $exportRoot
      if($remote.exitCode -ne 0){$r=Git @('remote','add','origin',("https://github.com/$TargetRepository.git")) $exportRoot;if($r.exitCode -ne 0){throw "git remote add failed: $($r.stderr)"}}
      $push=Git @('push','-u','origin','main') $exportRoot
      if($push.exitCode -ne 0){throw "git push failed: $($push.stderr)"}
      $published=$true;$publishMessage='Pushed sanitized baseline to existing private repository.'
    }
  }else{
    $publishMessage='Sanitized local Git baseline created, but GitHub CLI is missing or not authenticated under the execution identity.'
  }

  $result=[ordered]@{
    ok=$true;schema='afz.blog.git-migration.v1';action=$Action;jobId=$JobId;computer=$env:COMPUTERNAME
    classification=$(if($published){'AFZ_BLOG_GIT_BOOTSTRAP_PUBLISHED'}else{'AFZ_BLOG_GIT_BOOTSTRAP_LOCAL_READY'})
    sourceRoot=$sourceRoot;productionUnmodified=$true;productionGitRepo=$isGitRepo;productionHead=$(if($head){$head}else{$null});productionDirty=([bool]$gitStatus)
    backupRoot=$backup;exportRoot=$exportRoot;copiedFileCount=$copied;skippedFileCount=$skipped;forbiddenScanCount=$forbidden.Count
    baselineCommit=$baseline;targetRepository=$TargetRepository;ghAvailable=([bool]$gh);ghAuthenticated=$ghAuth;targetRepoExists=$repoExists;targetRepoPrivate=$repoPrivate;published=$published
    message=$publishMessage;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
  }
  Save-Result $result
  exit 0
}catch{
  $fail=[ordered]@{ok=$false;schema='afz.blog.git-migration.v1';action=$Action;jobId=$JobId;computer=$env:COMPUTERNAME;classification='AFZ_BLOG_GIT_BOOTSTRAP_FAILED';sourceRoot=$sourceRoot;exportRoot=$exportRoot;targetRepository=$TargetRepository;productionUnmodified=$true;error=$_.Exception.Message;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)}
  try{Save-Result $fail}catch{}
  Write-Error $_
  exit 1
}
