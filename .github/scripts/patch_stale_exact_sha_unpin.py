from pathlib import Path

p = Path('afz-openai-agent/Sync-AFZ-AgentFromGitHub.ps1')
s = p.read_text(encoding='utf-8')
old = """if(-not [string]::IsNullOrWhiteSpace($ExpectedSha)){
  $resolvedSha=$ExpectedSha.Trim().ToLowerInvariant()
  if($resolvedSha -notmatch '^[0-9a-f]{40}$'){throw 'ExpectedSha must be a 40-character Git commit SHA'}
}else{
  $nonce=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $ref=Invoke-RestMethod -Uri ('https://api.github.com/repos/f3arif/homelab-control/git/ref/heads/main?nocache='+$nonce) -Headers $headers -TimeoutSec 30
  $resolvedSha=([string]$ref.object.sha).Trim().ToLowerInvariant()
  if($resolvedSha -notmatch '^[0-9a-f]{40}$'){throw 'Unable to resolve current main SHA'}
}
"""
new = """if(-not [string]::IsNullOrWhiteSpace($ExpectedSha)){
  $resolvedSha=$ExpectedSha.Trim().ToLowerInvariant()
  if($resolvedSha -notmatch '^[0-9a-f]{40}$'){throw 'ExpectedSha must be a 40-character Git commit SHA'}

  # MONOTONIC_STALE_EXACT_SHA_UNPIN_V1
  # The updater downloads this wrapper fresh on every pass. If a long-lived
  # watcher is still passing an older exact SHA, advance only when the current
  # deploy signal is a valid SHA and GitHub proves it descends from the requested
  # SHA. Never move sideways, backwards, or to an unproven ref.
  try{
    $nonce=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $signalRaw=(Invoke-WebRequest -Uri ('https://raw.githubusercontent.com/f3arif/homelab-control/main/.github/afz-agent-deploy-signal.txt?nocache='+$nonce) -Headers $headers -UseBasicParsing -TimeoutSec 20).Content
    $signalSha=([string]$signalRaw).Trim().ToLowerInvariant()
    if($signalSha -match '^[0-9a-f]{40}$' -and $signalSha -ne $resolvedSha){
      $pair=($resolvedSha+'...'+$signalSha)
      $cmp=Invoke-RestMethod -Uri ('https://api.github.com/repos/f3arif/homelab-control/compare/'+$pair+'?nocache='+$nonce) -Headers $headers -TimeoutSec 30
      if(([string]$cmp.status).ToLowerInvariant() -eq 'ahead'){$resolvedSha=$signalSha}
    }
  }catch{}
}else{
  $nonce=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $ref=Invoke-RestMethod -Uri ('https://api.github.com/repos/f3arif/homelab-control/git/ref/heads/main?nocache='+$nonce) -Headers $headers -TimeoutSec 30
  $resolvedSha=([string]$ref.object.sha).Trim().ToLowerInvariant()
  if($resolvedSha -notmatch '^[0-9a-f]{40}$'){throw 'Unable to resolve current main SHA'}
}
"""
if s.count(old) != 1:
    raise SystemExit(f'expected one resolver block, got {s.count(old)}')
p.write_text(s.replace(old, new, 1), encoding='utf-8', newline='\n')
