from pathlib import Path

p = Path('afz-openai-agent/tools/Recover-H3-AFZBlog-ModelComparison.ps1')
s = p.read_text(encoding='utf-8')
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
p.write_text(s, encoding='utf-8')
