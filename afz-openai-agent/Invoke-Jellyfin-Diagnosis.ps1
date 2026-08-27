#Requires -Version 5.1
param([int]$Port=8796)
$ErrorActionPreference='Stop'
$prompt=@'
Continue diagnosing the Jellyfin/TorBox native-library regression from live Windows-main state. TorBox, Bollywood, Real-Debrid, qBittorrent and related native My Media libraries were visible previously and disappeared after later Jellyfin changes. Use the read-only typed tools automatically. Compare current state against JellyfinNativeLibrariesV3-20260824-151412 and JellyfinOverlayIsolation-20260825-160957, inspect CollectionFolder/root linkage, user permissions/preferences/display preferences, root\default definitions, current/backup Jellyfin web scripts and the failed ProgramData TorBox canary. Also query live user views for coolyo if a valid local session token can be found without exposing it. Do not create libraries, rescan media, write jellyfin.db, restore the old overlay wholesale, or change storage locations. Identify the exact regression and the smallest reversible repair. If a mutation is needed, return APPROVAL_REQUIRED with the precise evidence and proposed change.
'@
$body=[ordered]@{processor='sol';project='torbox';prompt=$prompt}|ConvertTo-Json -Compress
$r=Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/api/request" -ContentType 'application/json' -Body $body -TimeoutSec 240
$outDir='C:\AFZ\Diagnostics\Jellyfin'
New-Item -ItemType Directory -Force -Path $outDir|Out-Null
$out=Join-Path $outDir 'OpenAI-Agent-Jellyfin-Latest.json'
$r|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $out -Encoding UTF8
Write-Host ''
Write-Host '===== AFZ OPENAI JELLYFIN RESULT =====' -ForegroundColor Cyan
Write-Host $r.answer
Write-Host ''
Write-Host "Saved locally: $out"
Write-Host "Tool trace: $((@($r.toolTrace)|ForEach-Object{$_.name+':'+$_.ok}) -join ', ')"
