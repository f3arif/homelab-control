#Requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$path='afz-openai-agent/Invoke-H3-Hermes-TelegramFollowupRepair.ps1'
$text=[IO.File]::ReadAllText($path)
$old=@'
    $adapterTracked=$false
    $adapterDirty=$null
    try{
'@
$new=@'
    $adapterTracked=$false
    $adapterDirty=$null
    $adapterDiff=$null
    try{
'@
if(([regex]::Matches($text,[regex]::Escape($old))).Count -ne 1){throw 'provenance variable marker count mismatch'}
$text=$text.Replace($old,$new)
$old2=@'
          $status=((& $git.Source status --porcelain -- 'plugins/platforms/telegram/adapter.py' 2>$null) | Out-String).Trim()
          $adapterDirty=(-not [string]::IsNullOrWhiteSpace($status))
'@
$new2=@'
          $status=((& $git.Source status --porcelain -- 'plugins/platforms/telegram/adapter.py' 2>$null) | Out-String).Trim()
          $adapterDirty=(-not [string]::IsNullOrWhiteSpace($status))
          if($adapterDirty){
            $rawDiff=((& $git.Source diff --no-ext-diff --unified=2 -- 'plugins/platforms/telegram/adapter.py' 2>$null) | Out-String).Trim()
            $safeDiff=[regex]::Replace($rawDiff,'\b\d{5,}:[A-Za-z0-9_-]{20,}\b','<redacted-telegram-token>')
            if($safeDiff.Length -gt 12000){$safeDiff=$safeDiff.Substring(0,12000)+"`n<diff-truncated>"}
            $adapterDiff=$safeDiff
          }
'@
if(([regex]::Matches($text,[regex]::Escape($old2))).Count -ne 1){throw 'provenance status marker count mismatch'}
$text=$text.Replace($old2,$new2)
$old3='beforeSha256=$before;gitHead=$gitHead;adapterTracked=$adapterTracked;adapterDirty=$adapterDirty}) 43'
$new3='beforeSha256=$before;gitHead=$gitHead;adapterTracked=$adapterTracked;adapterDirty=$adapterDirty;adapterDiff=$adapterDiff}) 43'
if(([regex]::Matches($text,[regex]::Escape($old3))).Count -ne 1){throw 'provenance emit marker count mismatch'}
$text=$text.Replace($old3,$new3)
[IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false)))
$tokens=$null;$errors=$null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path),[ref]$tokens,[ref]$errors)|Out-Null
if($errors.Count){$errors|ForEach-Object{Write-Error $_.Message};exit 1}
$verify=[IO.File]::ReadAllText($path)
foreach($m in @('$adapterDiff=$null','git.Source diff --no-ext-diff --unified=2','<redacted-telegram-token>','adapterDiff=$adapterDiff')){if(-not $verify.Contains($m)){throw "missing diff telemetry marker: $m"}}
'FOLLOWUP_DIFF_TELEMETRY_PATCH=PASS'
