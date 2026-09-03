#Requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$path='afz-openai-agent/Invoke-H3-Hermes-TelegramFollowupRepair.ps1'
$text=[IO.File]::ReadAllText($path)
$old=@'
  if($before -ne '__EXPECTED_SHA__'){Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_FOLLOWUP_ADAPTER_HASH_MISMATCH';mutation='NONE';beforeSha256=$before}) 43}
'@
$new=@'
  if($before -ne '__EXPECTED_SHA__'){
    $gitHead=$null
    $adapterTracked=$false
    $adapterDirty=$null
    try{
      $git=Get-Command git.exe -ErrorAction SilentlyContinue
      if(-not $git){$git=Get-Command git -ErrorAction SilentlyContinue}
      if($git){
        Push-Location $source
        try{
          $gitHead=((& $git.Source rev-parse HEAD 2>$null | Select-Object -First 1) | Out-String).Trim()
          & $git.Source ls-files --error-unmatch -- 'plugins/platforms/telegram/adapter.py' *> $null
          $adapterTracked=($LASTEXITCODE -eq 0)
          $status=((& $git.Source status --porcelain -- 'plugins/platforms/telegram/adapter.py' 2>$null) | Out-String).Trim()
          $adapterDirty=(-not [string]::IsNullOrWhiteSpace($status))
        }finally{Pop-Location}
      }
    }catch{}
    Emit ([ordered]@{ok=$false;classification='HERMES_TELEGRAM_FOLLOWUP_ADAPTER_HASH_MISMATCH';mutation='NONE';beforeSha256=$before;gitHead=$gitHead;adapterTracked=$adapterTracked;adapterDirty=$adapterDirty}) 43
  }
'@
if(([regex]::Matches($text,[regex]::Escape($old))).Count -ne 1){throw 'follow-up hash mismatch marker count is not exactly one'}
$text=$text.Replace($old,$new)
[IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false)))
$tokens=$null;$errors=$null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path),[ref]$tokens,[ref]$errors)|Out-Null
if($errors.Count){$errors|ForEach-Object{Write-Error $_.Message};exit 1}
$verify=[IO.File]::ReadAllText($path)
foreach($m in @('gitHead=$gitHead','adapterTracked=$adapterTracked','adapterDirty=$adapterDirty','HERMES_TELEGRAM_FOLLOWUP_ADAPTER_HASH_MISMATCH')){if(-not $verify.Contains($m)){throw "missing provenance marker: $m"}}
'FOLLOWUP_PROVENANCE_PATCH=PASS'
