#Requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$path='afz-openai-agent/Invoke-H3-Hermes-TelegramFollowupRepair.ps1'
$text=[IO.File]::ReadAllText($path)
$old=@'
$before=(Get-FileHash -LiteralPath $adapter -Algorithm SHA256).Hash.ToLowerInvariant()
$text=[IO.File]::ReadAllText($adapter)
$already=($text.Contains('HERMES_TELEGRAM_DOCUMENT_FOLLOWUP_DELAY_SECONDS') -and $text.Contains('_document_followup_pending') -and $text.Contains('not (getattr(msg, "caption", None) or "").strip()'))
$backup=$null
$mutation='NONE'
if(-not $already){
'@
$new=@'
$before=(Get-FileHash -LiteralPath $adapter -Algorithm SHA256).Hash.ToLowerInvariant()
$text=[IO.File]::ReadAllText($adapter)
$backup=$null
$mutation='NONE'
$malformedFollowup=($text.Contains('HERMES_TELEGRAM_TEXT_BATCH_SPLIT_6.0_SECONDS') -and $text.Contains('HERMES_TELEGRAM_DOCUMENT_FOLLOWUP_6.0_SECONDS') -and $text.Contains('_document_followup_pending') -and $text.Contains('not (getattr(msg, "caption", None) or "").strip()'))
if($before -eq '7bd2d6ee20275175131606728a5334a4af0210bd4fcb61fff69b3e7c28ae2667' -and $malformedFollowup){
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup="$adapter.afz-pre-followup-env-normalize-$stamp.bak"
  Copy-Item -LiteralPath $adapter -Destination $backup -Force
  try{
    if(([regex]::Matches($text,[regex]::Escape('HERMES_TELEGRAM_TEXT_BATCH_SPLIT_6.0_SECONDS'))).Count -ne 1){throw 'Malformed split-delay marker count mismatch.'}
    if(([regex]::Matches($text,[regex]::Escape('HERMES_TELEGRAM_DOCUMENT_FOLLOWUP_6.0_SECONDS'))).Count -ne 1){throw 'Malformed document-followup marker count mismatch.'}
    $normalized=$text.Replace('HERMES_TELEGRAM_TEXT_BATCH_SPLIT_6.0_SECONDS','HERMES_TELEGRAM_TEXT_BATCH_SPLIT_DELAY_SECONDS').Replace('HERMES_TELEGRAM_DOCUMENT_FOLLOWUP_6.0_SECONDS','HERMES_TELEGRAM_DOCUMENT_FOLLOWUP_DELAY_SECONDS')
    [IO.File]::WriteAllText($adapter,$normalized,(New-Object Text.UTF8Encoding($false)))
    $text=[IO.File]::ReadAllText($adapter)
    $mutation='TELEGRAM_ADAPTER_DOCUMENT_FOLLOWUP_ENV_NORMALIZATION'
  }catch{
    try{Copy-Item -LiteralPath $backup -Destination $adapter -Force}catch{}
    Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_FOLLOWUP_ENV_NORMALIZATION_FAILED';mutation='ROLLED_BACK';beforeSha256=$before;errorType=$_.Exception.GetType().Name}) 47
  }
}
$already=($text.Contains('HERMES_TELEGRAM_DOCUMENT_FOLLOWUP_DELAY_SECONDS') -and $text.Contains('_document_followup_pending') -and $text.Contains('not (getattr(msg, "caption", None) or "").strip()'))
if(-not $already){
'@
if(([regex]::Matches($text,[regex]::Escape($old))).Count -ne 1){throw 'Follow-up remote preflight marker count mismatch.'}
$text=$text.Replace($old,$new)
[IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false)))
$tokens=$null;$errors=$null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path),[ref]$tokens,[ref]$errors)|Out-Null
if($errors.Count){$errors|ForEach-Object{Write-Error $_.Message};exit 1}
$verify=[IO.File]::ReadAllText($path)
foreach($m in @('7bd2d6ee20275175131606728a5334a4af0210bd4fcb61fff69b3e7c28ae2667','TELEGRAM_ADAPTER_DOCUMENT_FOLLOWUP_ENV_NORMALIZATION','HERMES_TELEGRAM_TEXT_BATCH_SPLIT_6.0_SECONDS','HERMES_TELEGRAM_DOCUMENT_FOLLOWUP_6.0_SECONDS','HERMES_TELEGRAM_TEXT_BATCH_SPLIT_DELAY_SECONDS','HERMES_TELEGRAM_DOCUMENT_FOLLOWUP_DELAY_SECONDS','HERMES_TELEGRAM_FOLLOWUP_ENV_NORMALIZATION_FAILED')){if(-not $verify.Contains($m)){throw "Missing normalization marker: $m"}}
'FOLLOWUP_MALFORMED_ENV_NORMALIZATION_PATCH=PASS'
