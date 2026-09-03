from pathlib import Path

p = Path('afz-openai-agent/Sync-AFZ-AgentFromGitHub.ps1')
s = p.read_text(encoding='utf-8')

fname = 'Start-AFZBlogModelComparisonRecoveryOneShot'
if f'function {fname}' not in s:
    anchor = "if(-not [string]::IsNullOrWhiteSpace($ExpectedSha)){"
    if anchor not in s:
        raise SystemExit('sync function insertion anchor missing')
    fn = r'''function Start-AFZBlogModelComparisonRecoveryOneShot {
  param([string]$SyncedSha)
  $jobId='afz-blog-qwen35b-vs-ridge27b-20260902-r1'
  $bootstrap=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-H3-AFZBlog-ModelComparisonRecovery.ps1'
  $markerRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-afz-blog-model-comparison-recovery-request'
  $marker=Join-Path $markerRoot ($jobId+'-activation-v1.json')
  $utf8=New-Object Text.UTF8Encoding($false)
  New-Item -ItemType Directory -Force -Path $markerRoot|Out-Null
  if(Test-Path -LiteralPath $marker -PathType Leaf){
    try{return Get-Content -LiteralPath $marker -Raw -Encoding UTF8|ConvertFrom-Json}catch{return [ordered]@{ok=$true;status='already-activated';jobId=$jobId;marker=$marker;syncedSha=$SyncedSha}}
  }
  if(-not(Test-Path -LiteralPath $bootstrap -PathType Leaf)){return [ordered]@{ok=$false;status='bootstrap-missing';jobId=$jobId;syncedSha=$SyncedSha}}
  try{
    $o=[ordered]@{ok=$true;status='recovery-starting';jobId=$jobId;syncedSha=$SyncedSha;marker=$marker;replay35B=$false;ridgeOnlyIfUnattempted=$true;activatedAt=(Get-Date -Format o)}
    [IO.File]::WriteAllText($marker,($o|ConvertTo-Json -Depth 10 -Compress),$utf8)
    $argLine="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$bootstrap`" -ExpectedSha `"$SyncedSha`" -JobId `"$jobId`" -Mode Bootstrap"
    $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $o['status']='recovery-bootstrap-started';$o['bootstrapPid']=$p.Id
    [IO.File]::WriteAllText($marker,($o|ConvertTo-Json -Depth 10 -Compress),$utf8)
    return $o
  }catch{
    return [ordered]@{ok=$false;status='recovery-activation-exception';jobId=$jobId;syncedSha=$SyncedSha;error=$_.Exception.Message;marker=$marker}
  }
}

'''
    s = s.replace(anchor, fn + anchor, 1)

call = "$afzBlogComparisonRecoveryActivation=Start-AFZBlogModelComparisonRecoveryOneShot -SyncedSha $resolvedSha"
if call not in s:
    anchor = "$afzBlogComparisonActivation=Start-AFZBlogModelComparisonOneShot -SyncedSha $resolvedSha"
    if anchor not in s:
        raise SystemExit('sync invocation anchor missing')
    s = s.replace(anchor, anchor + "\n\n  # Post-return recovery: never replays 35B; Ridge may run only if prior state proves it unattempted.\n  " + call, 1)

out = "$out['afzBlogModelComparisonRecoveryActivation']=$afzBlogComparisonRecoveryActivation"
if out not in s:
    anchor = "$out['afzBlogModelComparisonActivation']=$afzBlogComparisonActivation"
    if anchor not in s:
        raise SystemExit('sync output anchor missing')
    s = s.replace(anchor, anchor + "\n  " + out, 1)

p.write_text(s, encoding='utf-8')
