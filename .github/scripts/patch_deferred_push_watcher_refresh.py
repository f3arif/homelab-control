from pathlib import Path

p = Path('afz-openai-agent/Sync-AFZ-AgentFromGitHub.ps1')
s = p.read_text(encoding='utf-8')
anchor = """  if($raw -is [string]){try{$result=$raw|ConvertFrom-Json}catch{throw \"Core source sync returned invalid JSON: $raw\"}}else{$result=$raw}


# AFZ_BLOG_RUNTIME_SYNC_HOOK
"""
insert = r'''  if($raw -is [string]){try{$result=$raw|ConvertFrom-Json}catch{throw "Core source sync returned invalid JSON: $raw"}}else{$result=$raw}

  # DEFERRED_PUSH_WATCHER_REFRESH_V1
  # Exact-SHA passes may be invoked by the watcher they are updating, so they must
  # not stop their parent inline. If the installed watcher source hash changed,
  # schedule one independent SYSTEM task to restart only that watcher after this
  # updater has had time to return. The refresh task writes the applied hash and
  # unregisters itself, making this idempotent.
  $deferredPushWatcherRefresh=[ordered]@{ok=$true;status='not-needed';mutation='NONE'}
  try{
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if([string]$identity.User.Value -eq 'S-1-5-18'){
      $watcherPath=Join-Path $InstallRoot 'afz-openai-agent\Push-Deploy-Watcher.ps1'
      $hashMarker='C:\ProgramData\AFZ\OpenAIAgent\push-watcher-source.sha256'
      if(Test-Path -LiteralPath $watcherPath -PathType Leaf){
        $sourceHash=(Get-FileHash -LiteralPath $watcherPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $appliedHash=''
        if(Test-Path -LiteralPath $hashMarker -PathType Leaf){try{$appliedHash=([string](Get-Content -LiteralPath $hashMarker -Raw -Encoding ASCII)).Trim().ToLowerInvariant()}catch{}}
        if($sourceHash -ne $appliedHash){
          $refreshTask='AFZ OpenAI Agent Push Watcher Deferred Refresh'
          $targetTask='AFZ OpenAI Agent Push Deploy Watcher'
          $refreshScript='C:\ProgramData\AFZ\OpenAIAgent\Restart-PushWatcher-Deferred.ps1'
          $body=@'
$ErrorActionPreference='Stop'
$target='AFZ OpenAI Agent Push Deploy Watcher'
$refresh='AFZ OpenAI Agent Push Watcher Deferred Refresh'
$marker='C:\ProgramData\AFZ\OpenAIAgent\push-watcher-source.sha256'
$expected='__SOURCE_HASH__'
try{Stop-ScheduledTask -TaskName $target -ErrorAction SilentlyContinue}catch{}
Start-Sleep -Seconds 1
Start-ScheduledTask -TaskName $target -ErrorAction Stop
Set-Content -LiteralPath $marker -Value $expected -Encoding ASCII
try{Unregister-ScheduledTask -TaskName $refresh -Confirm:$false -ErrorAction SilentlyContinue}catch{}
'@.Replace('__SOURCE_HASH__',$sourceHash)
          [IO.File]::WriteAllText($refreshScript,$body,(New-Object Text.UTF8Encoding($false)))
          $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
          $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$refreshScript`""
          $trigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds(8))
          $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
          Register-ScheduledTask -TaskName $refreshTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
          $deferredPushWatcherRefresh=[ordered]@{ok=$true;status='scheduled';mutation='DEFERRED_WATCHER_RESTART';taskName=$refreshTask;targetTask=$targetTask;sourceHash=$sourceHash;appliedHash=$appliedHash}
        }else{
          $deferredPushWatcherRefresh=[ordered]@{ok=$true;status='hash-current';mutation='NONE';sourceHash=$sourceHash;appliedHash=$appliedHash}
        }
      }
    }else{
      $deferredPushWatcherRefresh=[ordered]@{ok=$true;status='skipped-non-system';mutation='NONE';identity=[string]$identity.Name}
    }
  }catch{
    $deferredPushWatcherRefresh=[ordered]@{ok=$false;status='schedule-failed';mutation='DEFERRED_WATCHER_RESTART_ATTEMPTED';error=$_.Exception.Message}
  }

# AFZ_BLOG_RUNTIME_SYNC_HOOK
'''
if s.count(anchor) != 1:
    raise SystemExit(f'expected one post-core anchor, got {s.count(anchor)}')
s = s.replace(anchor, insert, 1)
out_anchor = "  $out['fallbackUpdaterRepair']=$fallbackUpdaterRepair\n"
if s.count(out_anchor) != 1:
    raise SystemExit(f'expected one output anchor, got {s.count(out_anchor)}')
s = s.replace(out_anchor, out_anchor + "  $out['deferredPushWatcherRefresh']=$deferredPushWatcherRefresh\n", 1)
p.write_text(s, encoding='utf-8', newline='\n')
