# AFZ_JELLYFIN_CONTROLLED_RELOAD_REMOTEOPS_V2
function Invoke-JellyfinControlledReloadSafe {
    param($Config,$Job)
    $repo='C:\AFZ\homelab-control'
    $sourceSha='d39100dd635ad1b56346796609b81d98f5e58a68'
    $sourcePath='afz-openai-agent/tools/Jellyfin-Controlled-Reload.ps1'
    $git=(Get-Command git.exe,git -ErrorAction Stop|Select-Object -First 1).Source
    & $git -C $repo fetch origin main --quiet
    if($LASTEXITCODE -ne 0){throw 'Jellyfin reload source fetch failed'}
    $spec=$sourceSha+':'+$sourcePath
    $body=(& $git -C $repo show $spec 2>&1|Out-String)
    if($LASTEXITCODE -ne 0 -or $body -notmatch 'AFZ_JELLYFIN_CONTROLLED_RELOAD_V4'){throw 'Jellyfin reload exact-SHA source/marker failed'}
    $tmp=Join-Path $env:TEMP ('jf-controlled-reload-'+[guid]::NewGuid().ToString('n')+'.ps1')
    [IO.File]::WriteAllText($tmp,$body,(New-Object Text.UTF8Encoding($false)))
    try {
        $tokens=$null;$errors=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)
        if(@($errors).Count){throw ('Jellyfin reload parser failed: '+$errors[0].Message)}
        $lines=@(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $tmp 2>&1|ForEach-Object{[string]$_})
        $ec=$LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    if($ec -ne 0 -or $lines -notcontains 'RELOAD_STATUS=PASS'){
        throw ('Controlled Jellyfin reload did not PASS: '+($lines -join '; '))
    }
    return [ordered]@{
        action='jellyfin-controlled-reload-safe'
        ok=$true
        bridgeOk=$true
        sourceSha=$sourceSha
        summary=@($lines)
    }
}
