#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0

if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-pdf-runtime-audit.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Hermes PDF runtime request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid H3 Hermes PDF request identity.'}
if([string]$req.status -ne 'ACTIVE' -or [string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'H3 Hermes PDF request target/status mismatch.'}
if(-not [bool]$req.inspect_latest_cached_pdf -or [bool]$req.return_document_text){throw 'H3 Hermes PDF content guard mismatch.'}
if([int]$req.max_pages -lt 1 -or [int]$req.max_pages -gt 5){throw 'H3 Hermes PDF max_pages out of range.'}
if([bool]$req.change_config -or [bool]$req.restart_gateway -or [bool]$req.change_provider -or [bool]$req.mutate_ollama -or [bool]$req.change_network -or [bool]$req.run_model_generation){throw 'H3 Hermes PDF forbidden mutation requested.'}

$repair=$false
if([string]$req.action -eq 'audit-pdf-runtime'){
  if(-not [bool]$req.read_only -or [bool]$req.install_dependencies){throw 'H3 Hermes PDF audit guard mismatch.'}
}elseif([string]$req.action -eq 'audit-and-repair-pdf-runtime'){
  if([bool]$req.read_only -or -not [bool]$req.install_dependencies){throw 'H3 Hermes PDF repair guard mismatch.'}
  $packages=@($req.packages|ForEach-Object{([string]$_).Trim().ToLowerInvariant()})
  if(($packages -join ',') -ne 'pypdf,reportlab,pdfplumber'){throw 'H3 Hermes PDF repair package allowlist mismatch.'}
  $repair=$true
}else{throw 'Unsupported H3 Hermes PDF action.'}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-pdf-runtime-audit'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-PDF-RUNTIME-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required H3 PDF runtime path missing: $p"}}

function Save-Result($o){
  $j=$o|ConvertTo-Json -Depth 30
  [IO.File]::WriteAllText($statePath,$j,$utf8)
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$j,$utf8)}}catch{}
  Write-Output ($o|ConvertTo-Json -Depth 30 -Compress)
}

function Invoke-RemoteScript([string]$Target,[string[]]$Extra,[string]$Script,[int]$TimeoutMs,[string]$Transport){
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''stdin empty''};Invoke-Expression $script'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $inFile=Join-Path $env:TEMP ('h3-pdf-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('h3-pdf-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('h3-pdf-'+[guid]::NewGuid().ToString('n')+'.err')
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
    try{if($stdout){$parsed=$stdout|ConvertFrom-Json}}catch{}
    if($parsed){$parsed|Add-Member transport $Transport -Force;return $parsed}
    $preview=$stderr
    if($preview.Length -gt 600){$preview=$preview.Substring(0,600)}
    return [pscustomobject]@{ok=$false;classification=$(if($timedOut){'HERMES_PDF_RUNTIME_REMOTE_TIMEOUT'}else{'HERMES_PDF_RUNTIME_INVALID_REMOTE_RESULT'});transport=$Transport;timedOut=$timedOut;exit=$(if($timedOut){$null}else{[int]$p.ExitCode});stdoutBytes=[Text.Encoding]::UTF8.GetByteCount($stdout);stderrBytes=[Text.Encoding]::UTF8.GetByteCount($stderr);stderrPreview=$preview}
  }finally{Remove-Item $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}

$remoteTemplate=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
function Emit($o,[int]$code){$o|ConvertTo-Json -Depth 30 -Compress;exit $code}
try{
  if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_RUNTIME_WRONG_HOST';mutation='NONE'}) 30}
  $repairMode=__REPAIR_MODE__
  $root=Join-Path $env:LOCALAPPDATA 'hermes'
  $source=Join-Path $root 'hermes-agent'
  $python=Join-Path $source 'venv\Scripts\python.exe'
  $skill=Join-Path $source 'skills\productivity\pdf\SKILL.md'
  $pdfRead=Join-Path $source 'skills\productivity\pdf\scripts\pdf_read.py'
  $cache=Join-Path $root 'cache\documents'
  if(-not(Test-Path -LiteralPath $python -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_PYTHON_RUNTIME_MISSING';mutation='NONE'}) 41}
  if(-not(Test-Path -LiteralPath $skill -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_SKILL_MISSING';mutation='NONE'}) 42}
  if(-not(Test-Path -LiteralPath $pdfRead -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_HELPER_MISSING';mutation='NONE'}) 43}
  if(-not(Test-Path -LiteralPath $cache -PathType Container)){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_CACHE_PDF_NOT_FOUND';mutation='NONE';cachedPdfCount=0}) 44}
  $pdfs=@(Get-ChildItem -LiteralPath $cache -File -Filter '*.pdf' -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending)
  if($pdfs.Count -eq 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_CACHE_PDF_NOT_FOUND';mutation='NONE';cachedPdfCount=0}) 45}
  $pdf=$pdfs[0]
  $skillText=[IO.File]::ReadAllText($skill)
  $suspicious=($skillText -match '(?im)^\s*pdf\s+text\b')

  $depCode='import json,importlib.util;mods=["pypdf","reportlab","pdfplumber"];print(json.dumps({m:(importlib.util.find_spec(m) is not None) for m in mods}))'
  $priorEap=$ErrorActionPreference;$ErrorActionPreference='Continue'
  try{$depsRaw=(& $python -c $depCode 2>$null|Out-String).Trim();$depExit=$LASTEXITCODE}finally{$ErrorActionPreference=$priorEap}
  if($depExit -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEPENDENCY_PROBE_FAILED';mutation='NONE';pythonExit=$depExit}) 46}
  try{$deps=$depsRaw|ConvertFrom-Json}catch{Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEPENDENCY_PROBE_FAILED';mutation='NONE';stdoutBytes=[Text.Encoding]::UTF8.GetByteCount($depsRaw)}) 47}
  $depsReady=([bool]$deps.pypdf -and [bool]$deps.reportlab -and [bool]$deps.pdfplumber)
  $installed=$false;$preFreeze=$null;$pipExit=$null;$pipErrBytes=0

  if(-not $depsReady){
    if(-not $repairMode){
      Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEPENDENCY_MISSING';mutation='NONE';readOnly=$true;dependencies=$deps;skillFound=$true;requiredHelperMissing=$false;suspiciousLiteralPdfTextCommand=$suspicious;cachedPdfCount=$pdfs.Count;latestCachedPdfName=$pdf.Name;latestCachedPdfSizeBytes=[int64]$pdf.Length;latestCachedPdfSha256=(Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash.ToLowerInvariant();documentTextReturned=$false;gatewayRestarted=$false;providerTouched=$false;ollamaMutationStarted=$false;networkChanged=$false;modelGenerationStarted=$false;observedAt=(Get-Date -Format o)}) 10
    }
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$preFreeze=Join-Path $root ('pdf-deps-pre-'+$stamp+'.txt')
    try{(& $python -m pip freeze 2>$null|Out-String)|Set-Content -LiteralPath $preFreeze -Encoding UTF8}catch{}
    $pipErr=Join-Path $env:TEMP ('afz-hermes-pip-'+[guid]::NewGuid().ToString('n')+'.err')
    $priorEap=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{& $python -m pip install --disable-pip-version-check --no-input pypdf reportlab pdfplumber 2>$pipErr|Out-Null;$pipExit=$LASTEXITCODE}finally{$ErrorActionPreference=$priorEap}
    if(Test-Path $pipErr){$pipErrBytes=[Text.Encoding]::UTF8.GetByteCount([IO.File]::ReadAllText($pipErr));Remove-Item $pipErr -Force -ErrorAction SilentlyContinue}
    if($pipExit -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEP_INSTALL_FAILED';mutation='HERMES_VENV_PDF_DEPENDENCIES_ONLY';pipExit=$pipExit;pipStderrBytes=$pipErrBytes;preFreeze=$preFreeze}) 51}
    $installed=$true
  }

  $versionsCode='import json,pypdf,reportlab,pdfplumber;print(json.dumps({"pypdf":getattr(pypdf,"__version__",""),"reportlab":getattr(reportlab,"Version",getattr(reportlab,"__version__","")),"pdfplumber":getattr(pdfplumber,"__version__","")}))'
  $priorEap=$ErrorActionPreference;$ErrorActionPreference='Continue'
  try{$versionsRaw=(& $python -c $versionsCode 2>$null|Out-String).Trim();$versionsExit=$LASTEXITCODE}finally{$ErrorActionPreference=$priorEap}
  if($versionsExit -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEP_IMPORT_VERIFY_FAILED';mutation=$(if($installed){'HERMES_VENV_PDF_DEPENDENCIES_ONLY'}else{'NONE'});pythonExit=$versionsExit;preFreeze=$preFreeze}) 52}
  try{$versions=$versionsRaw|ConvertFrom-Json}catch{Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEP_IMPORT_VERIFY_FAILED';mutation=$(if($installed){'HERMES_VENV_PDF_DEPENDENCIES_ONLY'}else{'NONE'});preFreeze=$preFreeze}) 52}

  $readErr=Join-Path $env:TEMP ('afz-hermes-pdf-read-'+[guid]::NewGuid().ToString('n')+'.err')
  $priorEap=$ErrorActionPreference;$ErrorActionPreference='Continue'
  try{$raw=(& $python $pdfRead $pdf.FullName --text 2>$readErr|Out-String).Trim();$readExit=$LASTEXITCODE}finally{$ErrorActionPreference=$priorEap}
  $readErrBytes=0;if(Test-Path $readErr){$readErrBytes=[Text.Encoding]::UTF8.GetByteCount([IO.File]::ReadAllText($readErr));Remove-Item $readErr -Force -ErrorAction SilentlyContinue}
  if($readExit -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_READ_VERIFY_FAILED';mutation=$(if($installed){'HERMES_VENV_PDF_DEPENDENCIES_ONLY'}else{'NONE'});versions=$versions;readExit=$readExit;readStderrBytes=$readErrBytes;preFreeze=$preFreeze}) 54}
  try{$obj=$raw|ConvertFrom-Json}catch{Emit ([ordered]@{ok=$false;classification='HERMES_PDF_READ_VERIFY_INVALID_JSON';mutation=$(if($installed){'HERMES_VENV_PDF_DEPENDENCIES_ONLY'}else{'NONE'});versions=$versions;readStdoutBytes=[Text.Encoding]::UTF8.GetByteCount($raw);preFreeze=$preFreeze}) 55}
  $pages=@($obj.pages);$chars=0;foreach($pageText in $pages){$chars+=([string]$pageText).Length}
  $classification=$(if([int]$obj.page_count -gt 0 -and $chars -gt 0){'HERMES_PDF_DEPENDENCIES_AND_READ_VERIFIED'}else{'HERMES_PDF_LIKELY_SCANNED_OCR_REQUIRED'})
  Emit ([ordered]@{ok=$true;classification=$classification;mutation=$(if($installed){'HERMES_VENV_PDF_DEPENDENCIES_ONLY'}else{'NONE'});readOnly=(-not $repairMode);packages=@('pypdf','reportlab','pdfplumber');versions=$versions;dependenciesInstalled=$installed;pipExit=$pipExit;pipStderrBytes=$pipErrBytes;preFreeze=$preFreeze;pageCount=[int]$obj.page_count;extractedChars=$chars;cachedPdfCount=$pdfs.Count;latestCachedPdfName=$pdf.Name;latestCachedPdfSizeBytes=[int64]$pdf.Length;latestCachedPdfSha256=(Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash.ToLowerInvariant();skillFound=$true;requiredHelperMissing=$false;suspiciousLiteralPdfTextCommand=$suspicious;documentTextReturned=$false;configChanged=$false;gatewayRestarted=$false;providerTouched=$false;ollamaMutationStarted=$false;networkChanged=$false;modelGenerationStarted=$false;observedAt=(Get-Date -Format o)}) 0
}catch{
  $msg=[string]$_.Exception.Message;if($msg.Length -gt 500){$msg=$msg.Substring(0,500)}
  Emit ([ordered]@{ok=$false;classification='HERMES_PDF_RUNTIME_REMOTE_EXCEPTION';mutation='NONE_OR_INCOMPLETE';errorType=$_.Exception.GetType().FullName;errorMessage=$msg;documentTextReturned=$false;gatewayRestarted=$false;providerTouched=$false;ollamaMutationStarted=$false;networkChanged=$false;modelGenerationStarted=$false;observedAt=(Get-Date -Format o)}) 60
}
'@

$remote=$remoteTemplate.Replace('__REPAIR_MODE__',$(if($repair){'$true'}else{'$false'}))
$routes=@([pscustomobject]@{target='Faiz@100.106.186.118';transport='tailscale';extra=@()},[pscustomobject]@{target='Faiz@192.168.50.185';transport='lan-hostkey-alias';extra=@('-o','HostKeyAlias=100.106.186.118')})
$result=$null
foreach($r in $routes){$candidate=Invoke-RemoteScript -Target $r.target -Extra $r.extra -Script $remote -TimeoutMs 330000 -Transport $r.transport;$result=$candidate;if([string]$candidate.classification -notin @('HERMES_PDF_RUNTIME_REMOTE_TIMEOUT','HERMES_PDF_RUNTIME_INVALID_REMOTE_RESULT')){break}}
if($null -eq $result){$result=[pscustomobject]@{ok=$false;classification='HERMES_PDF_RUNTIME_UNREACHABLE'}}
Save-Result $result
exit $(if([bool]$result.ok){0}else{1})
