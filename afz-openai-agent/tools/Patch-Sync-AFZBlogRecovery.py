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
  $marker=Join-Path $markerRoot ($jobId+'-activation-v3.json')
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
    # v2 reached the windows-main interactive carrier but failed before H3 due
    # to the validated ArgumentList binding defect. v3 permits exactly one new
    # transport launch after that fix. The H3 recovery script independently
    # forbids any 35B replay and permits Ridge only when prior state proves it
    # unattempted.
    start = s.index(f'function {fname}')
    end_anchor = "if(-not [string]::IsNullOrWhiteSpace($ExpectedSha)){"
    end = s.index(end_anchor, start)
    segment = s[start:end]
    v1 = "$marker=Join-Path $markerRoot ($jobId+'-activation-v1.json')"
    v2 = "$marker=Join-Path $markerRoot ($jobId+'-activation-v2.json')"
    v3 = "$marker=Join-Path $markerRoot ($jobId+'-activation-v3.json')"
    if segment.count(v3) == 1:
        pass
    elif segment.count(v2) == 1 and segment.count(v1) == 0:
        segment = segment.replace(v2, v3, 1)
        s = s[:start] + segment + s[end:]
    elif segment.count(v1) == 1 and segment.count(v2) == 0:
        segment = segment.replace(v1, v3, 1)
        s = s[:start] + segment + s[end:]
    else:
        raise SystemExit('recovery marker is not a single expected v1/v2/v3 marker')

call = "$afzBlogComparisonRecoveryActivation=Start-AFZBlogModelComparisonRecoveryOneShot -SyncedSha $resolvedSha"
if call not in s:
    anchor = "$afzBlogComparisonActivation=Start-AFZBlogModelComparisonOneShot -SyncedSha $resolvedSha"
    if anchor not in s:
        raise SystemExit('sync invocation anchor missing')
    s = s.replace(anchor, anchor + "\n\n  # Post-return recovery: never replays 35B; Ridge may run only if prior state proves it unattempted.\n  " + call, 1)

# Non-fatal, read-only observability of the recovery activation/carrier. This
# helper only reads windows-main marker/task/result state and mirrors it to the
# existing AFZ Results folder; it performs no model or H3 action.
diag_var = '$afzBlogComparisonRecoveryTransportDiagnostic'
diag_block = r'''

  $afzBlogComparisonRecoveryTransportDiagnostic=[ordered]@{ok=$false;status='not-run';syncedSha=$resolvedSha;readOnly=$true}
  try{
    $diagHelper=Join-Path $InstallRoot 'afz-openai-agent\Publish-AFZBlogRecoveryTransportState.ps1'
    if(Test-Path -LiteralPath $diagHelper -PathType Leaf){
      $diagRaw=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $diagHelper -SyncedSha $resolvedSha | Select-Object -Last 1
      $diagCode=$LASTEXITCODE
      if($diagRaw -is [string]){try{$diagParsed=$diagRaw|ConvertFrom-Json}catch{$diagParsed=[ordered]@{status='invalid-json';raw=[string]$diagRaw}}}else{$diagParsed=$diagRaw}
      $afzBlogComparisonRecoveryTransportDiagnostic=[ordered]@{ok=($diagCode -eq 0);status=$(if($diagCode -eq 0){'captured'}else{'helper-failed'});exit=$diagCode;result=$diagParsed;syncedSha=$resolvedSha;readOnly=$true}
    }else{
      $afzBlogComparisonRecoveryTransportDiagnostic=[ordered]@{ok=$false;status='helper-missing';path=$diagHelper;syncedSha=$resolvedSha;readOnly=$true}
    }
  }catch{
    $afzBlogComparisonRecoveryTransportDiagnostic=[ordered]@{ok=$false;status='helper-exception';error=$_.Exception.Message;syncedSha=$resolvedSha;readOnly=$true}
  }
'''
if diag_var not in s:
    if s.count(call) != 1:
        raise SystemExit('recovery invocation count mismatch for diagnostic insertion')
    s = s.replace(call, call + diag_block, 1)

out = "$out['afzBlogModelComparisonRecoveryActivation']=$afzBlogComparisonRecoveryActivation"
if out not in s:
    anchor = "$out['afzBlogModelComparisonActivation']=$afzBlogComparisonActivation"
    if anchor not in s:
        raise SystemExit('sync output anchor missing')
    s = s.replace(anchor, anchor + "\n  " + out, 1)

diag_out = "$out['afzBlogModelComparisonRecoveryTransportDiagnostic']=$afzBlogComparisonRecoveryTransportDiagnostic"
if diag_out not in s:
    if s.count(out) != 1:
        raise SystemExit('recovery output count mismatch for diagnostic output')
    s = s.replace(out, out + "\n  " + diag_out, 1)

# Preserve the safety contract while proving only the recovery marker advanced.
for required in (
    'replay35B=$false',
    'ridgeOnlyIfUnattempted=$true',
    "$jobId+'-activation-v3.json'",
    'Publish-AFZBlogRecoveryTransportState.ps1',
    'readOnly=$true',
):
    if required not in s:
        raise SystemExit(f'missing guarded recovery/diagnostic marker: {required}')

p.write_text(s, encoding='utf-8')
