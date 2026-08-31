#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceSha,
    [string]$RepoRoot='C:\AFZ\homelab-control'
)
$ErrorActionPreference='Stop'
$actions='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius\actions.ps1'
$helperDir='C:\AFZ\RemoteOps\helpers'
$helper=Join-Path $helperDir 'Jellyfin-Controlled-Reload.ps1'
if(-not(Test-Path -LiteralPath $actions -PathType Leaf)){throw 'RemoteOps bridge actions.ps1 missing'}
New-Item -ItemType Directory -Force -Path $helperDir|Out-Null
$git=(Get-Command git.exe,git -ErrorAction Stop|Select-Object -First 1).Source
& $git -C $RepoRoot fetch origin main --quiet
if($LASTEXITCODE -ne 0){throw 'git fetch failed'}
$spec=$SourceSha+':afz-openai-agent/tools/Jellyfin-Controlled-Reload.ps1'
$helperText=(& $git -C $RepoRoot show $spec 2>&1|Out-String)
if($LASTEXITCODE -ne 0 -or $helperText -notmatch 'AFZ_JELLYFIN_CONTROLLED_RELOAD_V3'){throw 'Exact-SHA helper fetch/marker failed'}
[IO.File]::WriteAllText($helper,$helperText,(New-Object Text.UTF8Encoding($false)))
$t=$null;$e=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($helper,[ref]$t,[ref]$e)
if(@($e).Count){throw ('Helper parser failed: '+$e[0].Message)}
$src=[IO.File]::ReadAllText($actions)
if($src -notmatch 'AFZ_JELLYFIN_CONTROLLED_RELOAD_REMOTEOPS_V1'){
$wrapper=@'
# AFZ_JELLYFIN_CONTROLLED_RELOAD_REMOTEOPS_V1
function Invoke-JellyfinControlledReloadSafe {
 param($Config,$Job)
 $h='C:\AFZ\RemoteOps\helpers\Jellyfin-Controlled-Reload.ps1'
 if(-not(Test-Path -LiteralPath $h)){throw 'Controlled reload helper missing'}
 $lines=@(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $h 2>&1|ForEach-Object{[string]$_})
 $ec=$LASTEXITCODE
 $pass=($ec -eq 0 -and ($lines -contains 'RELOAD_STATUS=PASS'))
 if(-not $pass){throw ('Controlled Jellyfin reload did not PASS: '+($lines -join '; '))}
 return [ordered]@{action='jellyfin-controlled-reload-safe';ok=$true;bridgeOk=$true;summary=@($lines)}
}

'@
    $anchor='function Invoke-AFZAction {'
    if(-not $src.Contains($anchor)){throw 'Invoke-AFZAction anchor missing'}
    $src=$src.Replace($anchor,$wrapper+$anchor)
    $switchAnchor='    switch ([string]$Job.action) {'
    if(-not $src.Contains($switchAnchor)){throw 'action switch anchor missing'}
    $caseLine='        "jellyfin-controlled-reload-safe" { return Invoke-JellyfinControlledReloadSafe $Config $Job }'
    $caseLine=$caseLine.Replace([char]92+[char]34,[char]34)
    $src=$src.Replace($switchAnchor,$switchAnchor+"`r`n"+$caseLine)
}
if(([regex]::Matches($src,'AFZ_JELLYFIN_CONTROLLED_RELOAD_REMOTEOPS_V1')).Count -ne 1){throw 'Reload wrapper marker count invalid'}
if(([regex]::Matches($src,'jellyfin-controlled-reload-safe')).Count -lt 2){throw 'Reload dispatch installation failed'}
$tmp=$actions+'.candidate'
[IO.File]::WriteAllText($tmp,$src,(New-Object Text.UTF8Encoding($false)))
$t=$null;$e=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$t,[ref]$e)
if(@($e).Count){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue;throw ('actions parser failed: '+$e[0].Message)}
$bak=$actions+'.before-jellyfin-reload-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak'
Copy-Item -LiteralPath $actions -Destination $bak -Force
Move-Item -LiteralPath $tmp -Destination $actions -Force
Write-Output 'INSTALL_STATUS=PASS'
Write-Output ('SOURCE_SHA='+$SourceSha)
Write-Output ('ACTIONS_BACKUP='+$bak)
Write-Output ('HELPER='+$helper)
