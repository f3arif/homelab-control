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
$args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$core,'-InstallRoot',$InstallRoot)
if(-not [string]::IsNullOrWhiteSpace($RequestPath)){$args+=@('-RequestPath',$RequestPath)}
$raw=(& powershell.exe @args 2>&1|Out-String).Trim()
$code=$LASTEXITCODE
$result=$null
if(-not [string]::IsNullOrWhiteSpace($raw)){
  $lines=@($raw -split "`r?`n"|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
  for($i=$lines.Count-1;$i -ge 0;$i--){
    try{$result=$lines[$i]|ConvertFrom-Json;break}catch{}
  }
}
if($null -eq $result){
  $result=[pscustomobject]@{schema=2;ok=$false;classification='HERMES_DOCKER_WRAPPER_NO_JSON';deployment='docker-desktop';retryable=$true;capturedAt=(Get-Date -Format o)}
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
      jobId=(V 'jobId')
      ok=[bool](V 'ok' $false)
      classification=[string](V 'classification' 'UNKNOWN')
      retryable=[bool](V 'retryable' $false)
      transportError=(SafeText (V 'error'))
      deployment=[string](V 'deployment' 'docker-desktop')
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
