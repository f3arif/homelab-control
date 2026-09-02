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
$maxPages=[int]$req.max_pages
if($maxPages -lt 1 -or $maxPages -gt 5){throw 'H3 Hermes PDF max_pages out of range.'}
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
  $sshArgs=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=7','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known))
  if($Extra){$sshArgs+=@($Extra)}
  $sshArgs+=@($Target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  try{
    [IO.File]::WriteAllText($inFile,$Script,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $sshArgs -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    $timedOut=(-not $p.WaitForExit($TimeoutMs))
    if($timedOut){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{}}
    $stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
    $stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
    $parsed=$null;try{if($stdout){$parsed=$stdout|ConvertFrom-Json}}catch{}
    if($parsed){$parsed|Add-Member transport $Transport -Force;return $parsed}
    $preview=$stderr;if($preview.Length -gt 600){$preview=$preview.Substring(0,600)}
    return [pscustomobject]@{ok=$false;classification=$(if($timedOut){'HERMES_PDF_RUNTIME_REMOTE_TIMEOUT'}else{'HERMES_PDF_RUNTIME_INVALID_REMOTE_RESULT'});transport=$Transport;timedOut=$timedOut;exit=$(if($timedOut){$null}else{[int]$p.ExitCode});stdoutBytes=[Text.Encoding]::UTF8.GetByteCount($stdout);stderrBytes=[Text.Encoding]::UTF8.GetByteCount($stderr);stderrPreview=$preview}
  }finally{Remove-Item $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}

$remoteTemplate=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
function Emit($o,[int]$code){$o|ConvertTo-Json -Depth 30 -Compress;exit $code}
function Stage([string]$name){[Console]::Error.WriteLine(('AFZPDF_STAGE='+$name))}
function Run-Python([string[]]$PyArgs,[int]$TimeoutSeconds){
  if($null -eq $PyArgs -or $PyArgs.Count -eq 0){throw 'Run-Python received empty argument list.'}
  foreach($a in $PyArgs){if($null -eq $a){throw 'Run-Python received null argument.'}}
  $codeFile=$null
  $p=$null
  try{
    $effectiveArgs=@($PyArgs)
    if($effectiveArgs.Count -ge 2 -and [string]$effectiveArgs[0] -eq '-c'){
      $codeFile=Join-Path $env:TEMP ('afz-pdf-py-'+[guid]::NewGuid().ToString('n')+'.py')
      [IO.File]::WriteAllText($codeFile,[string]$effectiveArgs[1],(New-Object Text.UTF8Encoding($false)))
      if($effectiveArgs.Count -gt 2){$effectiveArgs=@($codeFile)+@($effectiveArgs[2..($effectiveArgs.Count-1)])}else{$effectiveArgs=@($codeFile)}
    }
    $quoted=@()
    foreach($a in $effectiveArgs){
      $s=[string]$a
      if($s.Contains('"')){throw 'Run-Python argument contains unsupported double quote after code staging.'}
      if($s -match '\s'){
        if($s.EndsWith('\')){throw 'Run-Python spaced argument cannot end with backslash.'}
        $quoted+=('"'+$s+'"')
      }else{$quoted+=$s}
    }
    $argLine=$quoted -join ' '
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$script:python
    $psi.Arguments=$argLine
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    $p=New-Object System.Diagnostics.Process
    $p.StartInfo=$psi
    if(-not $p.Start()){throw 'Run-Python process failed to start.'}
    $stdoutTask=$p.StandardOutput.ReadToEndAsync()
    $stderrTask=$p.StandardError.ReadToEndAsync()
    $to=(-not $p.WaitForExit($TimeoutSeconds*1000))
    if($to){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{}}else{try{$p.WaitForExit()}catch{}}
    try{$stdout=$stdoutTask.GetAwaiter().GetResult()}catch{$stdout=''}
    try{$stderr=$stderrTask.GetAwaiter().GetResult()}catch{$stderr=''}
    $stderrPreview=$stderr;if($stderrPreview.Length -gt 600){$stderrPreview=$stderrPreview.Substring(0,600)}
    $exit=$(if($to){$null}else{[int]$p.ExitCode})
    return [pscustomobject]@{timedOut=$to;exit=$exit;stdout=$stdout;stderrBytes=[Text.Encoding]::UTF8.GetByteCount($stderr);stderrPreview=$stderrPreview}
  }finally{
    if($p){try{$p.Dispose()}catch{}}
    if($codeFile){Remove-Item -LiteralPath $codeFile -Force -ErrorAction SilentlyContinue}
  }
}

try{
  if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_RUNTIME_WRONG_HOST';mutation='NONE'}) 30}
  $repairMode=__REPAIR_MODE__
  $maxPages=__MAX_PAGES__
  $root=Join-Path $env:LOCALAPPDATA 'hermes'
  $source=Join-Path $root 'hermes-agent'
  $script:python=Join-Path $source 'venv\Scripts\python.exe'
  $skill=Join-Path $source 'skills\productivity\pdf\SKILL.md'
  $pdfRead=Join-Path $source 'skills\productivity\pdf\scripts\pdf_read.py'
  $cache=Join-Path $root 'cache\documents'
  if(-not(Test-Path -LiteralPath $script:python -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_PYTHON_RUNTIME_MISSING';mutation='NONE'}) 41}
  if(-not(Test-Path -LiteralPath $skill -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_SKILL_MISSING';mutation='NONE'}) 42}
  if(-not(Test-Path -LiteralPath $pdfRead -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_HELPER_MISSING';mutation='NONE'}) 43}
  $pdfs=@();if(Test-Path -LiteralPath $cache -PathType Container){$pdfs=@(Get-ChildItem -LiteralPath $cache -File -Filter '*.pdf' -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending)}
  if($pdfs.Count -eq 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_CACHE_PDF_NOT_FOUND';mutation='NONE';cachedPdfCount=0}) 44}
  $pdf=$pdfs[0]
  $skillText=[IO.File]::ReadAllText($skill);$suspicious=($skillText -match '(?im)^\s*pdf\s+text\b')

  $depCode='import importlib.util;mods=["pypdf","reportlab","pdfplumber"];print(";".join(m+"="+("1" if importlib.util.find_spec(m) is not None else "0") for m in mods))'
  Stage 'dep-probe'
  $dep=Run-Python -PyArgs @('-c',$depCode) -TimeoutSeconds 20
  if($dep.timedOut -or $dep.exit -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEPENDENCY_PROBE_FAILED';mutation='NONE';pythonTimedOut=$dep.timedOut;pythonExit=$dep.exit;pythonStderrBytes=$dep.stderrBytes;pythonStderrPreview=$dep.stderrPreview}) 46}
  $depLine=([string]$dep.stdout).Trim()
  $deps=[ordered]@{pypdf=$false;reportlab=$false;pdfplumber=$false}
  $seen=@{}
  foreach($part in @($depLine -split ';')){
    $kv=@($part -split '=',2)
    if($kv.Count -ne 2){continue}
    $name=([string]$kv[0]).Trim().ToLowerInvariant();$value=([string]$kv[1]).Trim()
    if($deps.Contains($name) -and $value -in @('0','1')){$deps[$name]=($value -eq '1');$seen[$name]=$true}
  }
  $requiredDepNames=@('pypdf','reportlab','pdfplumber')
  $missingDepMarkers=@($requiredDepNames|Where-Object{-not $seen.ContainsKey($_)})
  if($missingDepMarkers.Count -gt 0){
    $preview=$depLine;if($preview.Length -gt 300){$preview=$preview.Substring(0,300)}
    Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEPENDENCY_PROBE_INVALID_OUTPUT';mutation='NONE';missingMarkers=$missingDepMarkers;stdoutPreview=$preview}) 47
  }
  $depsReady=([bool]$deps['pypdf'] -and [bool]$deps['reportlab'] -and [bool]$deps['pdfplumber'])
  $installed=$false;$pipBootstrapped=$false;$pipExit=$null;$pipErrBytes=0;$preFreeze=$null
  if(-not $depsReady){
    if(-not $repairMode){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEPENDENCY_MISSING';mutation='NONE';readOnly=$true;dependencies=$deps;skillFound=$true;requiredHelperMissing=$false;suspiciousLiteralPdfTextCommand=$suspicious;cachedPdfCount=$pdfs.Count;latestCachedPdfName=$pdf.Name;latestCachedPdfSizeBytes=[int64]$pdf.Length;latestCachedPdfSha256=(Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash.ToLowerInvariant();documentTextReturned=$false;observedAt=(Get-Date -Format o)}) 10}
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$preFreeze=Join-Path $root ('pdf-deps-pre-'+$stamp+'.txt')
    Stage 'pip-probe'
    $pipProbe=Run-Python -PyArgs @('-m','pip','--version') -TimeoutSeconds 20
    if($pipProbe.timedOut -or $pipProbe.exit -ne 0){
      Stage 'ensurepip'
      $ensure=Run-Python -PyArgs @('-m','ensurepip','--upgrade') -TimeoutSeconds 120
      if($ensure.timedOut){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_PIP_BOOTSTRAP_TIMEOUT';mutation='HERMES_VENV_PDF_DEPENDENCIES_ONLY';ensurepipStderrBytes=$ensure.stderrBytes;ensurepipStderrPreview=$ensure.stderrPreview;preFreeze=$preFreeze}) 48}
      if($ensure.exit -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_PIP_BOOTSTRAP_FAILED';mutation='HERMES_VENV_PDF_DEPENDENCIES_ONLY';ensurepipExit=$ensure.exit;ensurepipStderrBytes=$ensure.stderrBytes;ensurepipStderrPreview=$ensure.stderrPreview;preFreeze=$preFreeze}) 48}
      $pipBootstrapped=$true
      Stage 'pip-verify'
      $pipProbe=Run-Python -PyArgs @('-m','pip','--version') -TimeoutSeconds 20
      if($pipProbe.timedOut -or $pipProbe.exit -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_PIP_VERIFY_FAILED';mutation='HERMES_VENV_PDF_DEPENDENCIES_ONLY';pythonTimedOut=$pipProbe.timedOut;pythonExit=$pipProbe.exit;pythonStderrBytes=$pipProbe.stderrBytes;pythonStderrPreview=$pipProbe.stderrPreview;preFreeze=$preFreeze}) 49}
    }
    Stage 'pip-freeze'
    $freeze=Run-Python -PyArgs @('-m','pip','freeze') -TimeoutSeconds 30;if(-not $freeze.timedOut -and $freeze.exit -eq 0){[IO.File]::WriteAllText($preFreeze,$freeze.stdout,(New-Object Text.UTF8Encoding($false)))}
    Stage 'pip-install'
    $pip=Run-Python -PyArgs @('-m','pip','install','--disable-pip-version-check','--no-input','pypdf','reportlab','pdfplumber') -TimeoutSeconds 150
    $pipExit=$pip.exit;$pipErrBytes=$pip.stderrBytes
    if($pip.timedOut){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEP_INSTALL_TIMEOUT';mutation='HERMES_VENV_PDF_DEPENDENCIES_ONLY';preFreeze=$preFreeze;pipStderrBytes=$pip.stderrBytes;pipStderrPreview=$pip.stderrPreview}) 50}
    if($pip.exit -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEP_INSTALL_FAILED';mutation='HERMES_VENV_PDF_DEPENDENCIES_ONLY';pipExit=$pip.exit;pipStderrBytes=$pip.stderrBytes;pipStderrPreview=$pip.stderrPreview;preFreeze=$preFreeze}) 51}
    $installed=$true
  }

  $versionsCode='import json,pypdf,reportlab,pdfplumber;print(json.dumps({"pypdf":getattr(pypdf,"__version__",""),"reportlab":getattr(reportlab,"Version",getattr(reportlab,"__version__","")),"pdfplumber":getattr(pdfplumber,"__version__","")}))'
  Stage 'import-verify'
  $vr=Run-Python -PyArgs @('-c',$versionsCode) -TimeoutSeconds 30
  if($vr.timedOut -or $vr.exit -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEP_IMPORT_VERIFY_FAILED';mutation=$(if($installed){'HERMES_VENV_PDF_DEPENDENCIES_ONLY'}else{'NONE'});pythonExit=$vr.exit;pythonTimedOut=$vr.timedOut;pythonStderrBytes=$vr.stderrBytes;pythonStderrPreview=$vr.stderrPreview;preFreeze=$preFreeze}) 52}
  try{$versions=$vr.stdout|ConvertFrom-Json}catch{Emit ([ordered]@{ok=$false;classification='HERMES_PDF_DEP_IMPORT_VERIFY_FAILED';mutation=$(if($installed){'HERMES_VENV_PDF_DEPENDENCIES_ONLY'}else{'NONE'});preFreeze=$preFreeze}) 52}

  $subset=Join-Path $env:TEMP ('afz-hermes-pdf-subset-'+[guid]::NewGuid().ToString('n')+'.pdf')
  try{
    $subsetCode='import sys,json;from pypdf import PdfReader,PdfWriter;r=PdfReader(sys.argv[1]);w=PdfWriter();n=min(int(sys.argv[3]),len(r.pages));[w.add_page(r.pages[i]) for i in range(n)];f=open(sys.argv[2],"wb");w.write(f);f.close();print(json.dumps({"page_count":len(r.pages),"sample_pages":n}))'
    Stage 'sample-build'
    $sr=Run-Python -PyArgs @('-c',$subsetCode,$pdf.FullName,$subset,[string]$maxPages) -TimeoutSeconds 45
    if($sr.timedOut -or $sr.exit -ne 0 -or -not(Test-Path -LiteralPath $subset -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_SAMPLE_BUILD_FAILED';mutation=$(if($installed){'HERMES_VENV_PDF_DEPENDENCIES_ONLY'}else{'NONE'});pythonExit=$sr.exit;pythonTimedOut=$sr.timedOut;pythonStderrBytes=$sr.stderrBytes;pythonStderrPreview=$sr.stderrPreview;preFreeze=$preFreeze}) 53}
    try{$sampleMeta=$sr.stdout|ConvertFrom-Json}catch{Emit ([ordered]@{ok=$false;classification='HERMES_PDF_SAMPLE_BUILD_INVALID_JSON';mutation=$(if($installed){'HERMES_VENV_PDF_DEPENDENCIES_ONLY'}else{'NONE'});preFreeze=$preFreeze}) 53}
    Stage 'pdf-read'
    $rr=Run-Python -PyArgs @($pdfRead,$subset,'--text') -TimeoutSeconds 90
    if($rr.timedOut){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_READ_VERIFY_TIMEOUT';mutation=$(if($installed){'HERMES_VENV_PDF_DEPENDENCIES_ONLY'}else{'NONE'});versions=$versions;samplePages=[int]$sampleMeta.sample_pages;readStderrBytes=$rr.stderrBytes;readStderrPreview=$rr.stderrPreview;preFreeze=$preFreeze}) 54}
    if($rr.exit -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_PDF_READ_VERIFY_FAILED';mutation=$(if($installed){'HERMES_VENV_PDF_DEPENDENCIES_ONLY'}else{'NONE'});versions=$versions;readExit=$rr.exit;readStderrBytes=$rr.stderrBytes;readStderrPreview=$rr.stderrPreview;samplePages=[int]$sampleMeta.sample_pages;preFreeze=$preFreeze}) 54}
    try{$obj=$rr.stdout|ConvertFrom-Json}catch{Emit ([ordered]@{ok=$false;classification='HERMES_PDF_READ_VERIFY_INVALID_JSON';mutation=$(if($installed){'HERMES_VENV_PDF_DEPENDENCIES_ONLY'}else{'NONE'});versions=$versions;readStdoutBytes=[Text.Encoding]::UTF8.GetByteCount($rr.stdout);preFreeze=$preFreeze}) 55}
    $pages=@($obj.pages);$chars=0;foreach($pageText in $pages){$chars+=([string]$pageText).Length}
    $classification=$(if([int]$obj.page_count -gt 0 -and $chars -gt 0){'HERMES_PDF_DEPENDENCIES_AND_READ_VERIFIED'}else{'HERMES_PDF_LIKELY_SCANNED_OCR_REQUIRED'})
    Emit ([ordered]@{ok=$true;classification=$classification;mutation=$(if($installed){'HERMES_VENV_PDF_DEPENDENCIES_ONLY'}else{'NONE'});readOnly=(-not $repairMode);packages=@('pypdf','reportlab','pdfplumber');versions=$versions;dependenciesInstalled=$installed;pipBootstrapped=$pipBootstrapped;pipExit=$pipExit;pipStderrBytes=$pipErrBytes;preFreeze=$preFreeze;pageCount=[int]$sampleMeta.page_count;samplePages=[int]$sampleMeta.sample_pages;extractedChars=$chars;cachedPdfCount=$pdfs.Count;latestCachedPdfName=$pdf.Name;latestCachedPdfSizeBytes=[int64]$pdf.Length;latestCachedPdfSha256=(Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash.ToLowerInvariant();skillFound=$true;requiredHelperMissing=$false;suspiciousLiteralPdfTextCommand=$suspicious;documentTextReturned=$false;configChanged=$false;gatewayRestarted=$false;providerTouched=$false;ollamaMutationStarted=$false;networkChanged=$false;modelGenerationStarted=$false;observedAt=(Get-Date -Format o)}) 0
  }finally{Remove-Item -LiteralPath $subset -Force -ErrorAction SilentlyContinue}
}catch{
  $msg=[string]$_.Exception.Message;if($msg.Length -gt 500){$msg=$msg.Substring(0,500)}
  Emit ([ordered]@{ok=$false;classification='HERMES_PDF_RUNTIME_REMOTE_EXCEPTION';mutation='NONE_OR_INCOMPLETE';errorType=$_.Exception.GetType().FullName;errorMessage=$msg;documentTextReturned=$false;observedAt=(Get-Date -Format o)}) 60
}
'@
$remote=$remoteTemplate.Replace('__REPAIR_MODE__',$(if($repair){'$true'}else{'$false'})).Replace('__MAX_PAGES__',[string]$maxPages)
$routes=if($repair){@([pscustomobject]@{target='Faiz@100.106.186.118';transport='tailscale';extra=@()})}else{@([pscustomobject]@{target='Faiz@100.106.186.118';transport='tailscale';extra=@()},[pscustomobject]@{target='Faiz@192.168.50.185';transport='lan-hostkey-alias';extra=@('-o','HostKeyAlias=100.106.186.118')})}
$result=$null
foreach($r in $routes){$candidate=Invoke-RemoteScript -Target $r.target -Extra $r.extra -Script $remote -TimeoutMs 600000 -Transport $r.transport;$result=$candidate;if([string]$candidate.classification -notin @('HERMES_PDF_RUNTIME_REMOTE_TIMEOUT','HERMES_PDF_RUNTIME_INVALID_REMOTE_RESULT')){break}}
if($null -eq $result){$result=[pscustomobject]@{ok=$false;classification='HERMES_PDF_RUNTIME_UNREACHABLE'}}
Save-Result $result
exit $(if([bool]$result.ok){0}else{1})
