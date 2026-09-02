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
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-pdf-dependency-repair.json'
}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Hermes PDF dependency repair request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid PDF dependency repair request identity.'}
if([string]$req.action -ne 'install-pdf-skill-dependencies' -or [string]$req.status -ne 'ACTIVE'){throw 'PDF dependency repair request is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'PDF dependency repair target mismatch.'}
$packages=@($req.packages | ForEach-Object{([string]$_).Trim().ToLowerInvariant()})
$expected=@('pypdf','reportlab','pdfplumber')
if(-not [bool]$req.venv_only -or -not [bool]$req.use_upstream_skill_command -or -not [bool]$req.verify_latest_cached_pdf -or [bool]$req.return_document_text){throw 'PDF dependency repair guard mismatch.'}
if(($packages -join ',') -ne ($expected -join ',')){throw 'PDF dependency package allowlist mismatch.'}
if([bool]$req.restart_gateway -or [bool]$req.change_provider -or [bool]$req.mutate_ollama -or [bool]$req.change_network_config -or [bool]$req.run_model_generation){throw 'PDF dependency repair forbidden mutation requested.'}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-pdf-dependency-repair'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-PDF-DEPENDENCY-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required H3 PDF dependency path missing: $p"}}

function Save-Result($o){
  $j=$o | ConvertTo-Json -Depth 30
  [IO.File]::WriteAllText($statePath,$j,$utf8)
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$j,$utf8)}}catch{}
  Write-Output ($o | ConvertTo-Json -Depth 30 -Compress)
}

function Invoke-RemoteScript([string]$Target,[string[]]$Extra,[string]$Script,[int]$TimeoutMs,[string]$Transport){
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''stdin empty''};Invoke-Expression $script'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $inFile=Join-Path $env:TEMP ('h3-pdf-deps-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('h3-pdf-deps-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('h3-pdf-deps-'+[guid]::NewGuid().ToString('n')+'.err')
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=7','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known))
  if($Extra){$args+=@($Extra)}
  $args+=@($Target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  try{
    [IO.File]::WriteAllText($inFile,$Script,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    $timedOut=(-not $p.WaitForExit($TimeoutMs))
    if($timedOut){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{}}
    $stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
    $stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
    $parsed=$null
    foreach($line in @($stdout -split "`r?`n" | Where-Object{$_})){try{$parsed=$line | ConvertFrom-Json}catch{}}
    if($parsed){$parsed | Add-Member transport $Transport -Force;return $parsed}
    return [pscustomobject]@{ok=$false;classification=$(if($timedOut){'HERMES_PDF_DEP_REPAIR_REMOTE_TIMEOUT'}else{'HERMES_PDF_DEP_REPAIR_INVALID_REMOTE_RESULT'});transport=$Transport;exit=$(if($timedOut){$null}else{[int]$p.ExitCode});stdoutBytes=[Text.Encoding]::UTF8.GetByteCount($stdout);stderrBytes=[Text.Encoding]::UTF8.GetByteCount($stderr)}
  }finally{Remove-Item $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}

$remote=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
function Emit($o,[int]$code){$o | ConvertTo-Json -Depth 30 -Compress;exit $code}
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEP_REPAIR_WRONG_HOST'}) 30}
$root=Join-Path $env:LOCALAPPDATA 'hermes'
$source=Join-Path $root 'hermes-agent'
$python=Join-Path $source 'venv\Scripts\python.exe'
$pdfRead=Join-Path $source 'skills\productivity\pdf\scripts\pdf_read.py'
$cache=Join-Path $root 'cache\documents'
if(-not(Test-Path -LiteralPath $python -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_PYTHON_RUNTIME_MISSING'}) 41}
if(-not(Test-Path -LiteralPath $pdfRead -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_READ_HELPER_MISSING'}) 42}
$pdfs=@(Get-ChildItem -LiteralPath $cache -File -Filter '*.pdf' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if($pdfs.Count -eq 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_CACHE_PDF_NOT_FOUND'}) 43}
$pdf=$pdfs[0]

# Record pre-install environment for rollback/reference; no secrets or PDF content.
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$preFreeze=Join-Path $root ('pdf-deps-pre-'+$stamp+'.txt')
try{(& $python -m pip freeze 2>$null | Out-String) | Set-Content -LiteralPath $preFreeze -Encoding UTF8}catch{}

$work=Join-Path $env:TEMP ('afz-pdf-deps-'+[guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$pipOut=Join-Path $work 'pip.out';$pipErr=Join-Path $work 'pip.err'
$readOut=Join-Path $work 'read.out';$readErr=Join-Path $work 'read.err'
try{
  $pip=Start-Process -FilePath $python -ArgumentList @('-m','pip','install','--disable-pip-version-check','--no-input','pypdf','reportlab','pdfplumber') -RedirectStandardOutput $pipOut -RedirectStandardError $pipErr -PassThru -WindowStyle Hidden
  $pipTimedOut=(-not $pip.WaitForExit(180000))
  if($pipTimedOut){try{$pip.Kill()}catch{};try{$pip.WaitForExit()}catch{};Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEP_INSTALL_TIMEOUT';preFreeze=$preFreeze}) 50}
  $pipExit=[int]$pip.ExitCode
  $pipErrBytes=$(if(Test-Path $pipErr){[Text.Encoding]::UTF8.GetByteCount([IO.File]::ReadAllText($pipErr))}else{0})
  if($pipExit -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEP_INSTALL_FAILED';pipExit=$pipExit;pipStderrBytes=$pipErrBytes;preFreeze=$preFreeze}) 51}

  $versionCode='import json,pypdf,reportlab,pdfplumber;print(json.dumps({"pypdf":getattr(pypdf,"__version__",""),"reportlab":getattr(reportlab,"Version",getattr(reportlab,"__version__","")),"pdfplumber":getattr(pdfplumber,"__version__","")}))'
  $versionsRaw=(& $python -c $versionCode 2>$null | Out-String).Trim()
  try{$versions=$versionsRaw|ConvertFrom-Json}catch{Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEP_IMPORT_VERIFY_FAILED';preFreeze=$preFreeze}) 52}

  # Verify the official Hermes helper, capturing text locally and returning counts only.
  $quotedHelper='"'+$pdfRead.Replace('"','\"')+'"'
  $quotedPdf='"'+$pdf.FullName.Replace('"','\"')+'"'
  $argLine=$quotedHelper+' '+$quotedPdf+' --text'
  $rp=Start-Process -FilePath $python -ArgumentList $argLine -RedirectStandardOutput $readOut -RedirectStandardError $readErr -PassThru -WindowStyle Hidden
  $readTimedOut=(-not $rp.WaitForExit(60000))
  if($readTimedOut){try{$rp.Kill()}catch{};try{$rp.WaitForExit()}catch{};Emit ([ordered]@{ok=$false;classification='HERMES_PDF_READ_VERIFY_TIMEOUT';versions=$versions;preFreeze=$preFreeze}) 53}
  $readExit=[int]$rp.ExitCode
  $readErrBytes=$(if(Test-Path $readErr){[Text.Encoding]::UTF8.GetByteCount([IO.File]::ReadAllText($readErr))}else{0})
  if($readExit -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_READ_VERIFY_FAILED';versions=$versions;readExit=$readExit;readStderrBytes=$readErrBytes;preFreeze=$preFreeze}) 54}
  $raw=[IO.File]::ReadAllText($readOut)
  try{$obj=$raw|ConvertFrom-Json}catch{Emit ([ordered]@{ok=$false;classification='HERMES_PDF_READ_VERIFY_INVALID_JSON';versions=$versions;readStdoutBytes=[Text.Encoding]::UTF8.GetByteCount($raw);preFreeze=$preFreeze}) 55}
  $pages=@($obj.pages)
  $chars=0
  foreach($p in $pages){$chars += ([string]$p).Length}
  $ok=([int]$obj.page_count -gt 0 -and $chars -gt 0)
  Emit ([ordered]@{
    ok=$ok
    classification=$(if($ok){'HERMES_PDF_DEPENDENCIES_AND_READ_VERIFIED'}else{'HERMES_PDF_READ_EMPTY'})
    mutation='HERMES_VENV_PDF_DEPENDENCIES_ONLY'
    packages=@('pypdf','reportlab','pdfplumber')
    versions=$versions
    pageCount=[int]$obj.page_count
    extractedChars=$chars
    latestCachedPdfName=$pdf.Name
    latestCachedPdfSha256=(Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    preFreeze=$preFreeze
    documentTextReturned=$false
    gatewayRestarted=$false
    providerTouched=$false
    ollamaMutationStarted=$false
    networkConfigChanged=$false
    modelGenerationStarted=$false
    verifiedAt=(Get-Date -Format o)
  }) $(if($ok){0}else{1})
}finally{Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
'@

$routes=@(
  [pscustomobject]@{target='Faiz@100.106.186.118';transport='tailscale';extra=@()},
  [pscustomobject]@{target='Faiz@192.168.50.185';transport='lan-hostkey-alias';extra=@('-o','HostKeyAlias=100.106.186.118')}
)
$result=$null
foreach($r in $routes){
  $candidate=Invoke-RemoteScript -Target $r.target -Extra $r.extra -Script $remote -TimeoutMs 270000 -Transport $r.transport
  $result=$candidate
  if([string]$candidate.classification -notin @('HERMES_PDF_DEP_REPAIR_REMOTE_TIMEOUT','HERMES_PDF_DEP_REPAIR_INVALID_REMOTE_RESULT')){break}
}
if($null -eq $result){$result=[pscustomobject]@{ok=$false;classification='HERMES_PDF_DEP_REPAIR_UNREACHABLE'}}
Save-Result $result
exit $(if([bool]$result.ok){0}else{1})
