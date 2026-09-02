#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-agent-install.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Hermes request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid H3 Hermes request identity.'}
if([string]$req.action -ne 'install-and-configure' -or [string]$req.status -ne 'ACTIVE'){throw 'H3 Hermes provider repair request is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'H3 Hermes target mismatch.'}
if([string]$req.provider_name -ne 'ollama' -or [string]$req.base_url -ne 'http://127.0.0.1:11434/v1'){throw 'H3 Hermes provider route mismatch.'}
if([string]$req.base_model -ne 'qwen3.6:35b-a3b' -or [int]$req.context_length -ne 65536){throw 'H3 Hermes model mismatch.'}
if([bool]$req.restart_desktop_backend -or [bool]$req.restart_electron_ui -or [bool]$req.restart_messaging_gateway -or [bool]$req.mutate_ollama -or [bool]$req.run_generation_test -or [bool]$req.expose_api){throw 'H3 Hermes provider repair safety flags mismatch.'}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-agent'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-DOCKER-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
foreach($required in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "Required H3 SSH path missing: $required"}}

function Save-Result($result){
  $json=$result|ConvertTo-Json -Depth 20 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{
    if(Test-Path -LiteralPath $diagRoot -PathType Container){
      $safe=[ordered]@{
        schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';controlPlane='github';source='windows-main';target='h3';host='DESKTOP-H3R6CQN'
        jobId=$id;ok=[bool]$result.ok;classification=[string]$result.classification;retryable=$false;deployment='native'
        providerName='ollama';providerIdentity=$(if($result.PSObject.Properties.Name -contains 'providerIdentity'){[string]$result.providerIdentity}else{$null})
        providerConfigured=$(if($result.PSObject.Properties.Name -contains 'providerConfigured'){[bool]$result.providerConfigured}else{$false})
        providerApi=$(if($result.PSObject.Properties.Name -contains 'providerApi'){[string]$result.providerApi}else{$null})
        providerTransport=$(if($result.PSObject.Properties.Name -contains 'providerTransport'){[string]$result.providerTransport}else{$null})
        runtimeResolved=$(if($result.PSObject.Properties.Name -contains 'runtimeResolved'){[bool]$result.runtimeResolved}else{$false})
        runtimeProvider=$(if($result.PSObject.Properties.Name -contains 'runtimeProvider'){[string]$result.runtimeProvider}else{$null})
        runtimeBaseUrl=$(if($result.PSObject.Properties.Name -contains 'runtimeBaseUrl'){[string]$result.runtimeBaseUrl}else{$null})
        runtimeApiMode=$(if($result.PSObject.Properties.Name -contains 'runtimeApiMode'){[string]$result.runtimeApiMode}else{$null})
        ollamaReachable=$(if($result.PSObject.Properties.Name -contains 'ollamaReachable'){[bool]$result.ollamaReachable}else{$false})
        selectedModel='qwen3.6:35b-a3b';contextLength=65536
        configBackup=$(if($result.PSObject.Properties.Name -contains 'configBackup'){[string]$result.configBackup}else{$null})
        electronUiTouched=$false;desktopBackendTouched=$false;messagingGatewayTouched=$false;ollamaMutationStarted=$false;generationTestStarted=$false
        error=$(if($result.PSObject.Properties.Name -contains 'error'){[string]$result.error}else{$null});observedAt=(Get-Date -Format o)
      }
      [IO.File]::WriteAllText($diagPath,($safe|ConvertTo-Json -Depth 12),$utf8)
    }
  }catch{}
  Write-Output $json
}

$remote=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
function Emit($o,[int]$code){$o|ConvertTo-Json -Depth 20 -Compress;exit $code}
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=$false;classification='HERMES_WRONG_HOST';error=$env:COMPUTERNAME}) 30}
$root=Join-Path $env:LOCALAPPDATA 'hermes'
$hermes=Join-Path $root 'bin\hermes.exe'
$python=Join-Path $root 'hermes-agent\venv\Scripts\python.exe'
$config=Join-Path $root 'config.yaml'
$marker=Join-Path $root 'afz-provider-schema-r18.json'
if(-not(Test-Path -LiteralPath $hermes -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_NATIVE_RUNTIME_NOT_FOUND'}) 41}
if(-not(Test-Path -LiteralPath $python -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_PYTHON_RUNTIME_NOT_FOUND'}) 42}
if(-not(Test-Path -LiteralPath $config -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_CONFIG_NOT_FOUND'}) 43}
if(Test-Path -LiteralPath $marker -PathType Leaf){
  try{$prior=Get-Content -LiteralPath $marker -Raw -Encoding UTF8|ConvertFrom-Json;Emit $prior 0}catch{}
}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backup="$config.afz-pre-r18-$stamp.bak"
Copy-Item -LiteralPath $config -Destination $backup -Force
$priorHome=$env:HERMES_HOME
try{
  $env:HERMES_HOME=$root
  & $hermes config set providers.ollama.api 'http://127.0.0.1:11434/v1' | Out-Null
  if($LASTEXITCODE -ne 0){throw 'Failed to set providers.ollama.api'}
  & $hermes config set providers.ollama.transport 'openai_chat' | Out-Null
  if($LASTEXITCODE -ne 0){throw 'Failed to set providers.ollama.transport'}
  $providerRaw=(& $hermes config get providers.ollama --json 2>&1|Out-String).Trim()
  if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($providerRaw)){throw 'Unable to read providers.ollama after repair'}
  $provider=$providerRaw|ConvertFrom-Json
  $providerApi='';$providerTransport=''
  if($provider.PSObject.Properties.Name -contains 'api'){$providerApi=[string]$provider.api}
  if($provider.PSObject.Properties.Name -contains 'transport'){$providerTransport=[string]$provider.transport}

  $ollamaReachable=$false
  try{
    $models=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/v1/models' -Method Get -TimeoutSec 5
    $ids=@($models.data|ForEach-Object{[string]$_.id})
    $ollamaReachable=($ids -contains 'qwen3.6:35b-a3b')
  }catch{}

  $pyCode=@"
import json
from hermes_cli.runtime_provider import resolve_runtime_provider
out = {}
for name in ('custom:ollama','ollama'):
    try:
        try:
            r = resolve_runtime_provider(requested=name, target_model='qwen3.6:35b-a3b')
        except TypeError:
            r = resolve_runtime_provider(requested=name)
        safe = {
            'ok': bool(r),
            'provider': str((r or {}).get('provider') or (r or {}).get('provider_id') or ''),
            'base_url': str((r or {}).get('base_url') or ''),
            'api_mode': str((r or {}).get('api_mode') or (r or {}).get('transport') or ''),
            'has_api_key': bool((r or {}).get('api_key')),
        }
        out[name] = safe
    except Exception as e:
        out[name] = {'ok': False, 'error': type(e).__name__ + ': ' + str(e)[:240]}
print(json.dumps(out))
"@
  $runtimeRaw=(& $python -c $pyCode 2>&1|Out-String).Trim()
  $runtime=$null
  try{$runtime=$runtimeRaw|ConvertFrom-Json}catch{}
  $chosen=$null;$identity=''
  if($runtime -and $runtime.PSObject.Properties.Name -contains 'custom:ollama'){$candidate=$runtime.'custom:ollama';if($candidate.ok){$chosen=$candidate;$identity='custom:ollama'}}
  if(-not $chosen -and $runtime -and $runtime.PSObject.Properties.Name -contains 'ollama'){$candidate=$runtime.ollama;if($candidate.ok){$chosen=$candidate;$identity='ollama'}}
  $resolved=($null -ne $chosen -and [string]$chosen.base_url -match '127\.0\.0\.1:11434')
  $result=[ordered]@{
    ok=($providerApi -eq 'http://127.0.0.1:11434/v1' -and $providerTransport -eq 'openai_chat' -and $ollamaReachable -and $resolved)
    classification=$(if($providerApi -ne 'http://127.0.0.1:11434/v1'){'HERMES_OLLAMA_API_FIELD_NOT_READY'}elseif($providerTransport -ne 'openai_chat'){'HERMES_OLLAMA_TRANSPORT_NOT_READY'}elseif(-not $ollamaReachable){'HERMES_OLLAMA_MODEL_NOT_REACHABLE'}elseif(-not $resolved){'HERMES_OLLAMA_RUNTIME_ROUTE_NOT_RESOLVED'}else{'HERMES_OLLAMA_RUNTIME_ROUTE_READY'})
    providerConfigured=$true;providerIdentity=$identity;providerApi=$providerApi;providerTransport=$providerTransport
    runtimeResolved=$resolved;runtimeProvider=$(if($chosen){[string]$chosen.provider}else{''});runtimeBaseUrl=$(if($chosen){[string]$chosen.base_url}else{''});runtimeApiMode=$(if($chosen){[string]$chosen.api_mode}else{''})
    ollamaReachable=$ollamaReachable;configBackup=$backup;runtimeProbeRaw=$(if($runtime){$runtime}else{$runtimeRaw});finishedAt=(Get-Date -Format o)
  }
  $result|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $marker -Encoding UTF8
  Emit $result $(if($result.ok){0}else{44})
}catch{
  try{Copy-Item -LiteralPath $backup -Destination $config -Force}catch{}
  Emit ([ordered]@{ok=$false;classification='HERMES_OLLAMA_PROVIDER_SCHEMA_REPAIR_FAILED';configBackup=$backup;error=$_.Exception.Message}) 45
}finally{
  if($null -eq $priorHome){Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue}else{$env:HERMES_HOME=$priorHome}
}
'@

$bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 Hermes stdin empty.''};Invoke-Expression $script'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
$inFile=Join-Path $env:TEMP ('afz-h3-hermes-provider-'+[guid]::NewGuid().ToString('n')+'.ps1')
$outFile=Join-Path $env:TEMP ('afz-h3-hermes-provider-'+[guid]::NewGuid().ToString('n')+'.out')
$errFile=Join-Path $env:TEMP ('afz-h3-hermes-provider-'+[guid]::NewGuid().ToString('n')+'.err')
$args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
try{
  [IO.File]::WriteAllText($inFile,$remote,$utf8)
  $proc=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
  if(-not $proc.WaitForExit(60000)){try{$proc.Kill()}catch{};Save-Result ([pscustomobject]@{ok=$false;classification='HERMES_OLLAMA_PROVIDER_REPAIR_REMOTE_TIMEOUT';error='Provider repair exceeded 60 seconds.'});exit 75}
  $stdout=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
  $stderr=$(if(Test-Path -LiteralPath $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
  $parsed=$null
  foreach($line in @($stdout -split "`r?`n"|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})){try{$parsed=$line|ConvertFrom-Json}catch{}}
  if($null -eq $parsed){$parsed=[pscustomobject]@{ok=$false;classification='HERMES_OLLAMA_PROVIDER_REPAIR_INVALID_REMOTE_RESULT';error=$(if($stderr){$stderr}else{$stdout})}}
  Save-Result $parsed
  exit $(if([bool]$parsed.ok){0}else{1})
}finally{
  Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue
}
