from pathlib import Path

p = Path('afz-openai-agent/tools/Recover-H3-AFZBlog-ModelComparison.ps1')
s = p.read_text(encoding='utf-8')

# Keep the already-validated PowerShell interpolation fixes idempotent.
replacements = {
    '$Model: $respFile': '${Model}: $respFile',
    '$Path: $($r.Stderr)': '${Path}: $($r.Stderr)',
}
for old, new in replacements.items():
    count = s.count(old)
    if count == 1:
        s = s.replace(old, new, 1)
    elif count == 0 and new in s:
        pass
    else:
        raise SystemExit(f'unexpected replacement count for {old!r}: {count}')

# StrictMode requires the GitHub publisher variable to exist before the first
# running-state Publish call. Initialize/authenticate it before model-state
# handling so an observability failure can never occur after the Ridge guard is
# written but before the Ollama POST begins.
init = "$script:gh=Find-Gh\nif($script:gh){$auth=Invoke-Gh @('auth','status','--hostname','github.com');if($auth.ExitCode -ne 0){$script:gh=$null}}"
state_anchor = "\n\nif(-not(Test-Path $stateFile)){throw 'Prior state file missing; refusing recovery.'}"
if s.count(state_anchor) != 1:
    raise SystemExit('recovery GitHub-init insertion anchor mismatch')
state_pos = s.index(state_anchor)
if init not in s[:state_pos]:
    s = s.replace(state_anchor, "\n\n" + init + state_anchor, 1)

# Remove the obsolete late initialization and duplicate final publication. At
# this point $script:gh is already initialized above, and Publish safely becomes
# a no-op when authenticated gh is unavailable.
old_final = "$pushed=Publish $request $states $finalStatus\n$script:gh=Find-Gh\nif($script:gh){$auth=Invoke-Gh @('auth','status','--hostname','github.com');if($auth.ExitCode -ne 0){$script:gh=$null}}\nif($script:gh){[void](Publish $request $states $finalStatus);Comment \"[RESULT][H3-AFZ-BLOG-COMPARE-RECOVERY] Job $JobId status=$finalStatus completed=$completed/2 blocked=$blocked failed=$failed. 35B was recovered from its saved response without replay; Ridge was called only if prior state proved it unattempted. publish=false db_mutation=false.\"}"
new_final = "$pushed=Publish $request $states $finalStatus\nif($script:gh){Comment \"[RESULT][H3-AFZ-BLOG-COMPARE-RECOVERY] Job $JobId status=$finalStatus completed=$completed/2 blocked=$blocked failed=$failed. 35B was recovered from its saved response without replay; Ridge was called only if prior state proved it unattempted. publish=false db_mutation=false.\"}"
if old_final in s:
    s = s.replace(old_final, new_final, 1)
elif new_final not in s:
    raise SystemExit('recovery final publisher block did not match expected old or new form')

# Safety assertions: exactly one initializer, and it must be before any state
# handling/model guard. The model single-flight markers remain untouched.
if s.count(init) != 1:
    raise SystemExit(f'expected exactly one GitHub initializer, found {s.count(init)}')
state_pos = s.index(state_anchor)
if s.index(init) > state_pos:
    raise SystemExit('GitHub initializer is still late')
for required in (
    '35B prior state does not prove an attempted call; recovery refuses to create one.',
    'Ridge Ollama POST starting; single-flight guard set before request.',
    'publish_article=$false',
    'production_db_mutation=$false',
):
    if required not in s:
        raise SystemExit(f'missing recovery safety marker: {required}')

p.write_text(s, encoding='utf-8')
