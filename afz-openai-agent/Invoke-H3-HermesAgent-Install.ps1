#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$core=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-HermesAgent-Install.Core.ps1'
if(-not(Test-Path -LiteralPath $core -PathType Leaf)){throw "H3 Hermes core runner missing: $core"}
if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-agent-install.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Hermes request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$jobId=([string]$req.id).Trim()

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$probe=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
function Emit($o,[int]$code){$o|ConvertTo-Json -Depth 6 -Compress;exit $code}
try{
  if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){
    Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_DOCKER_WRONG_HOST';host=$env:COMPUTERNAME;retryable=$false}) 30
  }
  $dockerCmd=Get-Command docker.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  $dockerPath=$null
  if($dockerCmd){
    if($dockerCmd.Source){$dockerPath=[string]$dockerCmd.Source}elseif($dockerCmd.Path){$dockerPath=[string]$dockerCmd.Path}
  }
  if([string]::IsNullOrWhiteSpace($dockerPath)){
    foreach($candidate in @((Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'),'C:\Program Files\Docker\Docker\resources\bin\docker.exe')){
      if(Test-Path -LiteralPath $candidate -PathType Leaf){$dockerPath=$candidate;break}
    }
  }
  $desktopExe='C:\Program Files\Docker\Docker\Docker Desktop.exe'
  $desktopPresent=Test-Path -LiteralPath $desktopExe -PathType Leaf
  $desktopRunning=[bool](Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue|Select-Object -First 1)
  $dockerService=Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
  $dockerServiceStatus=$(if($dockerService){[string]$dockerService.Status}else{'missing'})
  if([string]::IsNullOrWhiteSpace($dockerPath)){
    Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_DOCKER_ENGINE_MISSING';host=$env:COMPUTERNAME;retryable=$false;dockerCliPresent=$false;dockerDesktopInstalled=$desktopPresent;dockerDesktopRunning=$desktopRunning;dockerServiceStatus=$dockerServiceStatus;dockerProbeTimedOut=$false}) 31
  }
  $psi=New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName=$dockerPath
  $psi.Arguments='version --format "{{.Server.Version}}"'
  $psi.UseShellExecute=$false
  $psi.RedirectStandardOutput=$true
  $psi.RedirectStandardError=$true
  $psi.CreateNoWindow=$true
  $p=New-Object System.Diagnostics.Process
  $p.StartInfo=$psi
  [void]$p.Start()
  if(-not $p.WaitForExit(12000)){
    try{$p.Kill()}catch{}
    Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_DOCKER_ENGINE_UNAVAILABLE';host=$env:COMPUTERNAME;retryable=$true;dockerCliPresent=$true;dockerDesktopInstalled=$desktopPresent;dockerDesktopRunning=$desktopRunning;dockerServiceStatus=$dockerServiceStatus;dockerProbeTimedOut=$true}) 32
  }
  $serverVersion=$p.StandardOutput.ReadToEnd().Trim()
  $probeError=$p.StandardError.ReadToEnd().Trim()
  if($probeError.Length -gt 300){$probeError=$probeError.Substring(0,300)}
  if($p.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($serverVersion)){
    Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_DOCKER_ENGINE_UNAVAILABLE';host=$env:COMPUTERNAME;retryable=$true;dockerCliPresent=$true;dockerDesktopInstalled=$desktopPresent;dockerDesktopRunning=$desktopRunning;dockerServiceStatus=$dockerServiceStatus;dockerProbeTimedOut=$false;error=$probeError}) 32
  }
  Emit ([ordered]@{schema=1;ok=$true;classification='HERMES_DOCKER_ENGINE_READY';host=$env:COMPUTERNAME;retryable=$false;dockerCliPresent=$true;dockerDesktopInstalled=$desktopPresent;dockerDesktopRunning=$desktopRunning;dockerServiceStatus=$dockerServiceStatus;dockerProbeTimedOut=$false;dockerServerVersion=$serverVersion}) 0
}catch{
  Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_DOCKER_PROBE_FAILED';host=$env:COMPUTERNAME;retryable=$true;error=$_.Exception.Message}) 75
}
'@

$result=$null
$code=75
$probeResult=$null
$probeError=$null
if((Test-Path -LiteralPath $key -PathType Leaf) -and (Test-Path -LiteralPath $known -PathType Leaf) -and (Test-Path -LiteralPath $ssh -PathType Leaf)){
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
  $outFile=Join-Path $env:TEMP ('afz-h3-docker-probe-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('afz-h3-docker-probe-'+[guid]::NewGuid().ToString('n')+'.err')
  $sshArgs=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  try{
    $sp=Start-Process -FilePath $ssh -ArgumentList $sshArgs -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $sp.WaitForExit(30000)){
      try{$sp.Kill()}catch{}
      $probeError='H3 Docker preflight exceeded 30 seconds.'
    }else{
      $probeRaw=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
      $probeErrRaw=$(if(Test-Path -LiteralPath $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
      if(-not [string]::IsNullOrWhiteSpace($probeRaw)){
        $probeLines=@($probeRaw -split "`r?`n"|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
        for($i=$probeLines.Count-1;$i -ge 0;$i--){try{$probeResult=$probeLines[$i]|ConvertFrom-Json;break}catch{}}
      }
      if($null -eq $probeResult){$probeError=$(if($probeErrRaw){$probeErrRaw}else{"H3 Docker preflight returned no JSON. exit=$($sp.ExitCode)"})}
    }
  }catch{$probeError=$_.Exception.Message}
  finally{Remove-Item -LiteralPath $outFile,$errFile -Force -ErrorAction SilentlyContinue}
}else{$probeError='Required H3 SSH preflight path is missing on Windows-main.'}

if($probeResult -and [bool]$probeResult.ok -and [string]$probeResult.classification -eq 'HERMES_DOCKER_ENGINE_READY'){
  $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$core,'-InstallRoot',$InstallRoot,'-RequestPath',$RequestPath)
  $raw=(& powershell.exe @args 2>&1|Out-String).Trim()
  $code=$LASTEXITCODE
  if(-not [string]::IsNullOrWhiteSpace($raw)){
    $lines=@($raw -split "`r?`n"|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
    for($i=$lines.Count-1;$i -ge 0;$i--){try{$result=$lines[$i]|ConvertFrom-Json;break}catch{}}
  }
}else{
  if($probeResult){
    $result=[pscustomobject]@{
      schema=2
      ok=$false
      classification=[string]$probeResult.classification
      deployment='docker-desktop'
      host=[string]$probeResult.host
      jobId=$jobId
      retryable=[bool]$probeResult.retryable
      dockerCliPresent=$(if($probeResult.PSObject.Properties.Name -contains 'dockerCliPresent'){[bool]$probeResult.dockerCliPresent}else{$false})
      dockerDesktopInstalled=$(if($probeResult.PSObject.Properties.Name -contains 'dockerDesktopInstalled'){[bool]$probeResult.dockerDesktopInstalled}else{$false})
      dockerDesktopRunning=$(if($probeResult.PSObject.Properties.Name -contains 'dockerDesktopRunning'){[bool]$probeResult.dockerDesktopRunning}else{$false})
      dockerServiceStatus=$(if($probeResult.PSObject.Properties.Name -contains 'dockerServiceStatus'){[string]$probeResult.dockerServiceStatus}else{$null})
      dockerProbeTimedOut=$(if($probeResult.PSObject.Properties.Name -contains 'dockerProbeTimedOut'){[bool]$probeResult.dockerProbeTimedOut}else{$false})
      dockerServerVersion=$(if($probeResult.PSObject.Properties.Name -contains 'dockerServerVersion'){[string]$probeResult.dockerServerVersion}else{$null})
      error=$(if($probeResult.PSObject.Properties.Name -contains 'error'){[string]$probeResult.error}else{$null})
      generationTestStarted=$false
      ollamaMutationStarted=$false
      repaired=$false
      capturedAt=(Get-Date -Format o)
    }
    $code=$(if([string]$probeResult.classification -eq 'HERMES_DOCKER_ENGINE_MISSING'){31}elseif([string]$probeResult.classification -eq 'HERMES_DOCKER_ENGINE_UNAVAILABLE'){32}else{75})
  }else{
    $result=[pscustomobject]@{schema=2;ok=$false;classification='HERMES_DOCKER_PROBE_TRANSPORT_FAILED';deployment='docker-desktop';host=$null;jobId=$jobId;retryable=$true;error=$probeError;generationTestStarted=$false;ollamaMutationStarted=$false;repaired=$false;capturedAt=(Get-Date -Format o)}
    $code=75
  }
}

if($null -eq $result){
  $result=[pscustomobject]@{schema=2;ok=$false;classification='HERMES_DOCKER_WRAPPER_NO_JSON';deployment='docker-desktop';jobId=$jobId;retryable=$true;capturedAt=(Get-Date -Format o)}
  if($code -eq 0){$code=75}
}
function V([string]$name,$fallback=$null){if($result.PSObject.Properties.Name -contains $name){return $result.$name};return $fallback}
function SafeText($value){
  if($null -eq $value){return $null}
  $s=([string]$value).Trim()
  if([string]::IsNullOrWhiteSpace($s)){return $null}
  $s=[regex]::Replace($s,'(?i)(password|secret|token)\s*[:=]\s*[^\s;]+','$1=<redacted>')
  if($s.Length -gt 1200){$s=$s.Substring(0,1200)+'...<truncated>'}
  return $s
}
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-DOCKER-LATEST.txt'
try{
  if(Test-Path -LiteralPath $diagRoot -PathType Container){
    $safe=[ordered]@{
      schema=1
      purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY'
      controlPlane='github'
      source='windows-main'
      target='h3'
      host=(V 'host')
      jobId=(V 'jobId' $jobId)
      ok=[bool](V 'ok' $false)
      classification=[string](V 'classification' 'UNKNOWN')
      retryable=[bool](V 'retryable' $false)
      transportError=(SafeText (V 'error'))
      deployment=[string](V 'deployment' 'docker-desktop')
      dockerCliPresent=[bool](V 'dockerCliPresent' $false)
      dockerDesktopInstalled=[bool](V 'dockerDesktopInstalled' $false)
      dockerDesktopRunning=[bool](V 'dockerDesktopRunning' $false)
      dockerServiceStatus=(V 'dockerServiceStatus')
      dockerProbeTimedOut=[bool](V 'dockerProbeTimedOut' $false)
      dockerServerVersion=(V 'dockerServerVersion')
      containerName=(V 'containerName')
      dashboardUrl=(V 'dashboardUrl')
      containerRunning=[bool](V 'containerRunning' $false)
      dashboardPortBindingOk=[bool](V 'dashboardPortBindingOk' $false)
      dashboardStatusReachable=[bool](V 'dashboardStatusReachable' $false)
      authRequired=[bool](V 'authRequired' $false)
      basicAuthProvider=[bool](V 'basicAuthProvider' $false)
      apiPublished=[bool](V 'apiPublished' $false)
      hostOllamaReachable=[bool](V 'hostOllamaReachable' $false)
      containerOllamaReachable=[bool](V 'containerOllamaReachable' $false)
      selectedModel=(V 'selectedModel')
      selectedModelListed=[bool](V 'selectedModelListed' $false)
      hermesVersion=(V 'hermesVersion')
      repaired=[bool](V 'repaired' $false)
      githubPublished=[bool](V 'githubPublished' $false)
      generationTestStarted=[bool](V 'generationTestStarted' $false)
      ollamaMutationStarted=[bool](V 'ollamaMutationStarted' $false)
      observedAt=(Get-Date -Format o)
    }
    [IO.File]::WriteAllText($diagPath,($safe|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
  }
}catch{}
$result|ConvertTo-Json -Depth 16 -Compress
exit $code
