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
  $marker=Join-Path $markerRoot ($jobId+'-activation-v2.json')
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
else:
    # Re-arm only this recovery carrier.  v1 may already exist from the failed
    # transport attempt; v2 permits one new carrier launch while the H3 recovery
    # script still independently forbids a 35B replay and guards Ridge.
    start = s.index(f'function {fname}')
    end_anchor = "if(-not [string]::IsNullOrWhiteSpace($ExpectedSha)){"
    end = s.index(end_anchor, start)
    segment = s[start:end]
    old = "$marker=Join-Path $markerRoot ($jobId+'-activation-v1.json')"
    new = "$marker=Join-Path $markerRoot ($jobId+'-activation-v2.json')"
    if old in segment:
        if segment.count(old) != 1:
            raise SystemExit('unexpected v1 recovery marker count')
        segment = segment.replace(old, new, 1)
        s = s[:start] + segment + s[end:]
    elif segment.count(new) != 1:
        raise SystemExit('recovery marker is neither expected v1 nor v2')

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

# Preserve the safety contract while proving only the recovery marker advanced.
for required in (
    'replay35B=$false',
    'ridgeOnlyIfUnattempted=$true',
    "$jobId+'-activation-v2.json'",
):
    if required not in s:
        raise SystemExit(f'missing guarded recovery marker: {required}')

p.write_text(s, encoding='utf-8')
