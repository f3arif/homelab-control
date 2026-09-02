#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$Port=8797,
  [string]$BindHost='100.70.25.8'
)
$ErrorActionPreference='Stop'
$core=Join-Path $InstallRoot 'afz-openai-agent\AFZ-Agent-Control-Core.ps1'
$helper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-AFZ-Blog-GitMigration.ps1'
$request=Join-Path $InstallRoot 'afz-openai-agent\requests\afz-blog-git-migration.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-blog-git-migration'
$marker=Join-Path $stateRoot 'wrapper-request.json'
$log='C:\ProgramData\AFZ\OpenAIAgent\logs\control-wrapper.log'
New-Item -ItemType Directory -Force -Path $stateRoot,(Split-Path $log -Parent)|Out-Null
function WLog([string]$m){try{Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) $m" -Encoding UTF8}catch{}}
try{
  if((Test-Path -LiteralPath $request -PathType Leaf) -and (Test-Path -LiteralPath $helper -PathType Leaf)){
    $r=Get-Content -LiteralPath $request -Raw -Encoding UTF8|ConvertFrom-Json
    $id=[string]$r.id;$enabled=[bool]$r.enabled;$action=([string]$r.action).Trim().ToLowerInvariant()
    $already=$false
    if(Test-Path -LiteralPath $marker -PathType Leaf){try{$m=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json;$already=([string]$m.id -eq $id)}catch{}}
    if($enabled -and $action -eq 'apply' -and $id -match '^afz-blog-git-migration-[A-Za-z0-9._-]+$' -and -not $already){
      WLog "blog migration request start id=$id"
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -Action apply -RequestId $id | Out-Null
      $code=$LASTEXITCODE
      [ordered]@{id=$id;attemptedAt=(Get-Date -Format o);exitCode=$code}|ConvertTo-Json|Set-Content -LiteralPath $marker -Encoding UTF8
      WLog "blog migration request finish id=$id exit=$code"
    }
  }
}catch{WLog "blog migration wrapper error=$($_.Exception.Message)"}
if(-not(Test-Path -LiteralPath $core -PathType Leaf)){throw "Preserved AFZ control core missing: $core"}
WLog 'launching preserved AFZ control core'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $core -InstallRoot $InstallRoot -Port $Port -BindHost $BindHost
exit $LASTEXITCODE
