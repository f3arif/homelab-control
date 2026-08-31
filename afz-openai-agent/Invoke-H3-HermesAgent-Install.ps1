#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-agent-install.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "Hermes request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid Hermes request identity.'}
if([string]$req.action -ne 'install-and-configure' -or [string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'Hermes audit target mismatch.'}
if([string]$req.recovery_mode -ne 'post-timeout-audit-only'){throw 'Hermes runner is restricted to post-timeout audit-only mode.'}
if([string]$req.base_url -ne 'http://127.0.0.1:11434/v1' -or [int]$req.context_length -ne 65536){throw 'Hermes audit request mismatch.'}
if([bool]$req.start_gateway -or [bool]$req.run_generation_test){throw 'Hermes audit safety flags mismatch.'}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$auditRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-agent-audit'
$auditPath=Join-Path $auditRoot ($id+'.json')
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$mirrorPath=Join-Path $mirrorRoot 'H3-HERMES-POSTTIMEOUT-AUDIT-LATEST.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $auditRoot|Out-Null

function Save-Audit($o){
  $json=$o|ConvertTo-Json -Depth 12 -Compress
  [IO.File]::WriteAllText($auditPath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,($o|ConvertTo-Json -Depth 12),$utf8)}}catch{}
  Write-Output $json
}
$prior=$null
if(Test-Path -LiteralPath $auditPath -PathType Leaf){try{$prior=Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}
if($prior -and [string]$prior.classification -notmatch 'AUDIT_TRANSPORT_FAILED$'){Save-Audit $prior;exit 0}
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required elevated H3 audit path missing: $p"}}

$remote=@'
$ErrorActionPreference='Stop'
$baseModel='qwen3.6:35b-a3b'
$aliasModel='qwen3.6:35b-a3b-hermes64k'
$endpoint='http://127.0.0.1:11434/v1'
$hermesHome=Join-Path $env:LOCALAPPDATA 'hermes'
$launcher=Join-Path $hermesHome 'bin\hermes.exe'
$config=Join-Path $hermesHome 'config.yaml'
function Value([string]$t,[string]$p){$m=[regex]::Match($t,$p,[Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Multiline);if($m.Success){return ([string]$m.Groups[1].Value).Trim().Trim('"').Trim("'")};return $null}
function OllamaPath{$c=Get-Command ollama.exe -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){return [string]$c.Source};foreach($p in @((Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),'C:\Program Files\Ollama\ollama.exe')){if(Test-Path $p){return $p}};return $null}
function Ctx([string]$o,[string]$m){if(-not $o){return 0};$t=(& $o show --modelfile $m 2>&1|Out-String);if($LASTEXITCODE -ne 0){return 0};$x=[regex]::Matches($t,'(?im)^\s*PARAMETER\s+num_ctx\s+(\d+)\s*$');if($x.Count){return [int]$x[$x.Count-1].Groups[1].Value};return 0}
$launcherPresent=Test-Path -LiteralPath $launcher -PathType Leaf
$version=$null;if($launcherPresent){$v=(& $launcher --version 2>&1|Out-String).Trim();if($LASTEXITCODE -eq 0){$version=$v}}
$configPresent=Test-Path -LiteralPath $config -PathType Leaf
$model=$null;$provider=$null;$baseUrl=$null;$context=0;$apiKeyPresent=$false
if($configPresent){$t=[IO.File]::ReadAllText($config);$model=Value $t '^\s*default\s*:\s*([^#\r\n]+)';$provider=Value $t '^\s*provider\s*:\s*([^#\r\n]+)';$baseUrl=Value $t '^\s*base_url\s*:\s*([^#\r\n]+)';$cv=Value $t '^\s*context_length\s*:\s*(\d+)';if($cv -match '^\d+$'){$context=[int]$cv};$apiKeyPresent=($t -match '(?im)^\s*api_key\s*:\s*\S+')}
$o=OllamaPath;$reachable=$false;$names=@();if($o){try{$tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 10;$names=@($tags.models|ForEach-Object{[string]$_.name});$reachable=$true}catch{}}
$basePresent=($baseModel -in $names);$aliasPresent=($aliasModel -in $names);$baseContext=$(if($basePresent){Ctx $o $baseModel}else{0});$aliasContext=$(if($aliasPresent){Ctx $o $aliasModel}else{0});$selectedContext=$(if($model -eq $aliasModel){$aliasContext}elseif($model -eq $baseModel){$baseContext}else{0})
$configOk=($configPresent -and $model -in @($baseModel,$aliasModel) -and $provider -eq 'custom' -and $baseUrl -eq $endpoint -and $context -eq 65536 -and $apiKeyPresent)
$ready=($launcherPresent -and $version -and $reachable -and $configOk -and $selectedContext -ge 64000)
$classification=$(if($ready){'HERMES_READY_LOCAL_OLLAMA_64K'}elseif($launcherPresent){'HERMES_INSTALLED_CONFIG_INCOMPLETE'}else{'HERMES_LAUNCHER_MISSING_AFTER_TIMEOUT'})
[ordered]@{schema=1;ok=[bool]$ready;classification=$classification;host=$env:COMPUTERNAME;launcherPresent=$launcherPresent;version=$version;configPresent=$configPresent;configModel=$model;configProvider=$provider;configBaseUrl=$baseUrl;configContextLength=$context;apiKeyPresent=$apiKeyPresent;ollamaReachable=$reachable;baseModelPresent=$basePresent;baseModelContext=$baseContext;hermesAliasPresent=$aliasPresent;hermesAliasContext=$aliasContext;selectedModelContext=$selectedContext;generationTestStarted=$false;gatewayStarted=$false;capturedAt=(Get-Date -Format o)}|ConvertTo-Json -Depth 6 -Compress
'@
$inFile=Join-Path $env:TEMP ('afz-h3-hermes-audit-'+[guid]::NewGuid().ToString('n')+'.ps1')
$outFile=Join-Path $env:TEMP ('afz-h3-hermes-audit-'+[guid]::NewGuid().ToString('n')+'.out')
$errFile=Join-Path $env:TEMP ('afz-h3-hermes-audit-'+[guid]::NewGuid().ToString('n')+'.err')
$args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','-')
try{
  [IO.File]::WriteAllText($inFile,$remote,$utf8)
  $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
  if(-not $p.WaitForExit(90000)){try{$p.Kill()}catch{};throw 'H3 Hermes audit exceeded 90 seconds.'}
  $stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
  $stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
  if($p.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($stdout)){throw "H3 Hermes audit SSH failed exit=$($p.ExitCode) stderr=$stderr"}
  $lines=@($stdout -split "`r?`n"|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
  $result=$lines[$lines.Count-1]|ConvertFrom-Json
  $result|Add-Member -NotePropertyName jobId -NotePropertyValue $id -Force
  $result|Add-Member -NotePropertyName recoveryMode -NotePropertyValue 'post-timeout-audit-only' -Force
  Save-Audit $result
  exit 0
}catch{
  Save-Audit ([ordered]@{schema=1;ok=$false;classification='HERMES_POSTTIMEOUT_AUDIT_TRANSPORT_FAILED';jobId=$id;recoveryMode='post-timeout-audit-only';error=$_.Exception.Message;generationTestStarted=$false;gatewayStarted=$false;capturedAt=(Get-Date -Format o)})
  exit 75
}finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
