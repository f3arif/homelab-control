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
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-pdf-runtime-audit.json'
}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Hermes PDF audit request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid H3 Hermes PDF audit request identity.'}
if([string]$req.action -ne 'audit-pdf-runtime' -or [string]$req.status -ne 'ACTIVE'){throw 'H3 Hermes PDF audit request is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'H3 Hermes PDF audit target mismatch.'}
if(-not [bool]$req.read_only -or -not [bool]$req.inspect_latest_cached_pdf -or [bool]$req.return_document_text){throw 'H3 Hermes PDF audit read-only/content guard mismatch.'}
if([int]$req.max_pages -lt 1 -or [int]$req.max_pages -gt 5){throw 'H3 Hermes PDF audit max_pages out of range.'}
if([bool]$req.install_dependencies -or [bool]$req.change_config -or [bool]$req.restart_gateway -or [bool]$req.change_provider -or [bool]$req.mutate_ollama -or [bool]$req.change_network -or [bool]$req.run_model_generation){throw 'H3 Hermes PDF audit forbidden mutation requested.'}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-pdf-runtime-audit'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-PDF-RUNTIME-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required H3 PDF audit path missing: $p"}}

function Save-Result($o){
  $j=$o | ConvertTo-Json -Depth 30
  [IO.File]::WriteAllText($statePath,$j,$utf8)
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$j,$utf8)}}catch{}
  Write-Output ($o | ConvertTo-Json -Depth 30 -Compress)
}

function Invoke-RemoteScript([string]$Target,[string[]]$Extra,[string]$Script,[int]$TimeoutMs,[string]$Transport){
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''stdin empty''};Invoke-Expression $script'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $inFile=Join-Path $env:TEMP ('h3-pdf-audit-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('h3-pdf-audit-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('h3-pdf-audit-'+[guid]::NewGuid().ToString('n')+'.err')
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
    return [pscustomobject]@{ok=$false;classification=$(if($timedOut){'HERMES_PDF_AUDIT_REMOTE_TIMEOUT'}else{'HERMES_PDF_AUDIT_INVALID_REMOTE_RESULT'});transport=$Transport;timedOut=$timedOut;exit=$(if($timedOut){$null}else{[int]$p.ExitCode});stderrPresent=(-not [string]::IsNullOrWhiteSpace($stderr))}
  }finally{Remove-Item $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}

$maxPages=[int]$req.max_pages
$remote=@"
`$ErrorActionPreference='Stop'
`$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
function Emit(`$o,[int]`$code){`$o | ConvertTo-Json -Depth 30 -Compress;exit `$code}
if(`$env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=`$false;classification='HERMES_PDF_AUDIT_WRONG_HOST';host=`$env:COMPUTERNAME}) 30}
`$root=Join-Path `$env:LOCALAPPDATA 'hermes'
`$source=Join-Path `$root 'hermes-agent'
`$python=Join-Path `$source 'venv\Scripts\python.exe'
`$cache=Join-Path `$root 'cache\documents'
if(-not(Test-Path -LiteralPath `$python -PathType Leaf)){Emit ([ordered]@{ok=`$false;classification='HERMES_PDF_PYTHON_RUNTIME_MISSING';readOnly=`$true}) 41}
`$pdfs=@()
if(Test-Path -LiteralPath `$cache -PathType Container){`$pdfs=@(Get-ChildItem -LiteralPath `$cache -File -Filter '*.pdf' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)}
if(`$pdfs.Count -eq 0){Emit ([ordered]@{ok=`$false;classification='HERMES_PDF_CACHE_PDF_NOT_FOUND';readOnly=`$true;cachePath=`$cache;cachedPdfCount=0}) 42}
`$pdf=`$pdfs[0]

`$skillCandidates=@(
  (Join-Path `$source 'skills\productivity\pdf\SKILL.md'),
  (Join-Path `$source 'skills\productivity\ocr-and-documents\SKILL.md'),
  (Join-Path `$root 'skills\productivity\pdf\SKILL.md'),
  (Join-Path `$root 'skills\pdf\SKILL.md'),
  (Join-Path `$env:USERPROFILE '.hermes\skills\productivity\pdf\SKILL.md'),
  (Join-Path `$env:USERPROFILE '.hermes\skills\pdf\SKILL.md')
)
`$skills=@()
`$helperSignals=@()
`$requiredHelperMissing=`$false
foreach(`$sp in `$skillCandidates | Select-Object -Unique){
  if(-not(Test-Path -LiteralPath `$sp -PathType Leaf)){continue}
  `$st=[IO.File]::ReadAllText(`$sp)
  `$hasPdfRead=(`$st -match 'pdf_read[.]py')
  `$hasPyMu=(`$st -match 'extract_pymupdf[.]py|PyMuPDF|import\s+fitz')
  `$hasSuspicious=(`$st -match '(?im)^\s*pdf\s+text\b')
  `$skillDir=Split-Path -Parent `$sp
  `$pdfRead=Join-Path `$skillDir 'scripts\pdf_read.py'
  `$extractPyMu=Join-Path `$skillDir 'scripts\extract_pymupdf.py'
  if(`$hasPdfRead -and -not(Test-Path -LiteralPath `$pdfRead -PathType Leaf)){`$requiredHelperMissing=`$true}
  if((`$st -match 'extract_pymupdf[.]py') -and -not(Test-Path -LiteralPath `$extractPyMu -PathType Leaf)){`$requiredHelperMissing=`$true}
  `$skills += [ordered]@{path=`$sp;sha256=(Get-FileHash -LiteralPath `$sp -Algorithm SHA256).Hash.ToLowerInvariant();sizeBytes=[int64](Get-Item `$sp).Length;referencesPdfRead=`$hasPdfRead;referencesPyMuPdf=`$hasPyMu;containsLiteralPdfTextCommand=`$hasSuspicious}
  `$helperSignals += [ordered]@{skillPath=`$sp;pdfReadExists=(Test-Path -LiteralPath `$pdfRead -PathType Leaf);pdfReadPath=`$pdfRead;extractPyMuPdfExists=(Test-Path -LiteralPath `$extractPyMu -PathType Leaf);extractPyMuPdfPath=`$extractPyMu}
}

`$py=@'
import sys, json, importlib.util
path=sys.argv[1]
max_pages=max(1,min(5,int(sys.argv[2])))
deps={
  'pypdf': importlib.util.find_spec('pypdf') is not None,
  'pdfplumber': importlib.util.find_spec('pdfplumber') is not None,
  'fitz': importlib.util.find_spec('fitz') is not None,
}
out={'dependencies':deps,'engine':None,'pageCount':None,'pagesSampled':0,'extractedChars':0,'containsIslington':False,'containsHrv':False,'containsHeatRecovery':False,'errorType':None}
text=''
try:
    if deps['pypdf']:
        from pypdf import PdfReader
        doc=PdfReader(path)
        out['engine']='pypdf'; out['pageCount']=len(doc.pages)
        n=min(max_pages,len(doc.pages)); out['pagesSampled']=n
        for i in range(n):
            try: text += (doc.pages[i].extract_text() or '') + '\n'
            except Exception: pass
    elif deps['fitz']:
        import fitz
        doc=fitz.open(path)
        out['engine']='pymupdf'; out['pageCount']=doc.page_count
        n=min(max_pages,doc.page_count); out['pagesSampled']=n
        for i in range(n):
            try: text += (doc.load_page(i).get_text('text') or '') + '\n'
            except Exception: pass
        doc.close()
    elif deps['pdfplumber']:
        import pdfplumber
        with pdfplumber.open(path) as doc:
            out['engine']='pdfplumber'; out['pageCount']=len(doc.pages)
            n=min(max_pages,len(doc.pages)); out['pagesSampled']=n
            for i in range(n):
                try: text += (doc.pages[i].extract_text() or '') + '\n'
                except Exception: pass
    else:
        out['errorType']='NO_SUPPORTED_PDF_LIBRARY'
    text=text[:100000]
    low=text.lower()
    out['extractedChars']=len(text)
    out['containsIslington']='islington' in low
    out['containsHrv']='hrv' in low
    out['containsHeatRecovery']='heat recovery' in low
except Exception as e:
    out['errorType']=type(e).__name__
print(json.dumps(out,separators=(',',':')))
'@
`$probeRaw=(& `$python -c `$py `$pdf.FullName '$maxPages' 2>&1 | Out-String).Trim()
`$probe=`$null
foreach(`$line in @(`$probeRaw -split "`r?`n" | Where-Object{`$_})){try{`$probe=`$line | ConvertFrom-Json}catch{}}
if(`$null -eq `$probe){`$probe=[pscustomobject]@{dependencies=[pscustomobject]@{pypdf=`$false;pdfplumber=`$false;fitz=`$false};engine=`$null;pageCount=`$null;pagesSampled=0;extractedChars=0;containsIslington=`$false;containsHrv=`$false;containsHeatRecovery=`$false;errorType='PROBE_RESULT_UNPARSEABLE'}}
`$hasAnyDep=([bool]`$probe.dependencies.pypdf -or [bool]`$probe.dependencies.pdfplumber -or [bool]`$probe.dependencies.fitz)
`$skillFound=(`$skills.Count -gt 0)
`$suspicious=@(`$skills | Where-Object{[bool]`$_.containsLiteralPdfTextCommand}).Count -gt 0
`$classification='HERMES_PDF_RUNTIME_AUDIT_COMPLETE'
`$ok=`$true
if(-not `$skillFound){`$classification='HERMES_PDF_SKILL_MISSING';`$ok=`$false}
elseif(`$requiredHelperMissing){`$classification='HERMES_PDF_HELPER_MISSING';`$ok=`$false}
elseif(-not `$hasAnyDep){`$classification='HERMES_PDF_DEPENDENCY_MISSING';`$ok=`$false}
elseif(`$probe.errorType){`$classification='HERMES_PDF_EXTRACTION_FAILED';`$ok=`$false}
elseif([int]`$probe.extractedChars -lt 50){`$classification='HERMES_PDF_LIKELY_SCANNED_OCR_REQUIRED';`$ok=`$true}
elseif(`$suspicious){`$classification='HERMES_PDF_SKILL_COMMAND_MISMATCH';`$ok=`$false}
else{`$classification='HERMES_PDF_TEXT_EXTRACTION_READY';`$ok=`$true}
Emit ([ordered]@{
  ok=`$ok;classification=`$classification;readOnly=`$true;host=`$env:COMPUTERNAME;
  cachePath=`$cache;cachedPdfCount=`$pdfs.Count;latestCachedPdfName=`$pdf.Name;latestCachedPdfSizeBytes=[int64]`$pdf.Length;latestCachedPdfModified=`$pdf.LastWriteTime.ToString('o');latestCachedPdfSha256=(Get-FileHash -LiteralPath `$pdf.FullName -Algorithm SHA256).Hash.ToLowerInvariant();
  skillFound=`$skillFound;skills=`$skills;helpers=`$helperSignals;requiredHelperMissing=`$requiredHelperMissing;suspiciousLiteralPdfTextCommand=`$suspicious;
  extraction=`$probe;documentTextReturned=`$false;configChanged=`$false;gatewayRestarted=`$false;providerTouched=`$false;ollamaMutationStarted=`$false;networkChanged=`$false;modelGenerationStarted=`$false;observedAt=(Get-Date -Format o)
}) $(if(`$ok){0}else{1})
"@

$routes=@(
  [pscustomobject]@{target='Faiz@100.106.186.118';transport='tailscale';extra=@()},
  [pscustomobject]@{target='Faiz@192.168.50.185';transport='lan-hostkey-alias';extra=@('-o','HostKeyAlias=100.106.186.118')}
)
$result=$null
foreach($r in $routes){
  $candidate=Invoke-RemoteScript -Target $r.target -Extra $r.extra -Script $remote -TimeoutMs 45000 -Transport $r.transport
  $result=$candidate
  if([string]$candidate.classification -notin @('HERMES_PDF_AUDIT_REMOTE_TIMEOUT','HERMES_PDF_AUDIT_INVALID_REMOTE_RESULT')){break}
}
if($null -eq $result){$result=[pscustomobject]@{ok=$false;classification='HERMES_PDF_AUDIT_UNREACHABLE';readOnly=$true}}
Save-Result $result
exit $(if([bool]$result.ok){0}else{1})
