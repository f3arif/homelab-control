#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [switch]$Force
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repoApi='https://api.github.com/repos/f3arif/homelab-control/commits/main'
$repoZip='https://github.com/f3arif/homelab-control/archive/refs/heads/main.zip'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent'
$stateFile=Join-Path $stateRoot 'source-state.json'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
function Emit($o){$o|ConvertTo-Json -Depth 8 -Compress; exit 0}
$headers=@{'User-Agent'='AFZ-OpenAI-Agent-Updater'}
$remote=Invoke-RestMethod -Uri $repoApi -Headers $headers -TimeoutSec 30
$remoteSha=[string]$remote.sha
if([string]::IsNullOrWhiteSpace($remoteSha)){throw 'GitHub main commit SHA unavailable'}
$localSha=$null
if(Test-Path $stateFile){try{$localSha=[string]((Get-Content $stateFile -Raw|ConvertFrom-Json).remoteSha)}catch{}}
if((-not $Force) -and $localSha -eq $remoteSha -and (Test-Path (Join-Path $InstallRoot 'afz-openai-agent\AFZ-OpenAI-Agent-v2.ps1'))){Emit ([ordered]@{ok=$true;changed=$false;remoteSha=$remoteSha;localSha=$localSha;installRoot=$InstallRoot})}
$temp=Join-Path $env:TEMP ('AFZ-AgentSync-'+[guid]::NewGuid().ToString('n'))
$zip=Join-Path $temp 'main.zip'
$extract=Join-Path $temp 'extract'
New-Item -ItemType Directory -Force -Path $temp,$extract | Out-Null
try{
  Invoke-WebRequest -Uri $repoZip -Headers $headers -OutFile $zip -UseBasicParsing -TimeoutSec 120
  Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
  $src=Join-Path $extract 'homelab-control-main\afz-openai-agent'
  if(-not(Test-Path $src)){throw "Downloaded archive missing afz-openai-agent: $src"}
  $dst=Join-Path $InstallRoot 'afz-openai-agent'
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  $copied=@()
  foreach($f in @(Get-ChildItem -LiteralPath $src -Recurse -File)){
    $rel=$f.FullName.Substring($src.Length).TrimStart('\')
    $target=Join-Path $dst $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
    $needs=$true
    if(Test-Path $target){try{$needs=((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash)}catch{$needs=$true}}
    if($needs){Copy-Item -LiteralPath $f.FullName -Destination $target -Force; $copied+=$rel}
  }

  # Compatibility normalization for Windows PowerShell 5.1 DPAPI type resolution.
  foreach($ps1 in @(Get-ChildItem -LiteralPath $dst -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue)){
    try{
      $text=Get-Content -LiteralPath $ps1.FullName -Raw
      $fixed=$text.Replace('[Security.Cryptography.ProtectedData]','[System.Security.Cryptography.ProtectedData]').Replace('[Security.Cryptography.DataProtectionScope]','[System.Security.Cryptography.DataProtectionScope]')
      if($fixed -match '\[System\.Security\.Cryptography\.ProtectedData\]' -and $fixed -notmatch '(?im)^\s*Add-Type\s+-AssemblyName\s+System\.Security'){
        $load="try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { throw \"Unable to load System.Security required for DPAPI: $($_.Exception.Message)\" }"
        if($fixed -match '(?m)^\$ErrorActionPreference\s*=\s*[\'\"]Stop[\'\"]\s*$'){
          $fixed=[regex]::Replace($fixed,'(?m)^(\$ErrorActionPreference\s*=\s*[\'\"]Stop[\'\"]\s*)$',('$1'+"`r`n"+$load),1)
        }else{
          $fixed=$load+"`r`n"+$fixed
        }
      }
      if($fixed -ne $text){
        Set-Content -LiteralPath $ps1.FullName -Value $fixed -Encoding UTF8
        $relFixed=$ps1.FullName.Substring($dst.Length).TrimStart('\')
        if($copied -notcontains $relFixed){$copied+=$relFixed}
      }
    }catch{throw "Compatibility patch failed for $($ps1.FullName): $($_.Exception.Message)"}
  }

  $state=[ordered]@{remoteSha=$remoteSha;syncedAt=(Get-Date -Format o);installRoot=$InstallRoot;copied=$copied;compatibility='windows-powershell-5.1-dpapi-system-security'}
  $state|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $stateFile -Encoding UTF8
  Emit ([ordered]@{ok=$true;changed=($copied.Count -gt 0 -or $localSha -ne $remoteSha);remoteSha=$remoteSha;localSha=$localSha;copied=$copied;installRoot=$InstallRoot})
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
