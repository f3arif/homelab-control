#!/usr/bin/env python3
"""Isolated Movie Night swap tests. Only writes temporary fixture files."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

STAGE = Path(__file__).resolve().parent
ORIGINAL_SRC = "/home/coolyo/afz-stremio-secondhost-20260918/movie-night-review-service/src"
FILES = ("screen.html", "screen.css", "screen.js")

def hashes(folder):
    return {name:hashlib.sha256((folder/name).read_bytes()).hexdigest() for name in FILES}

with tempfile.TemporaryDirectory(prefix="afz-movie-night-fixture-") as temp:
    root=Path(temp)
    stage=root/"stage"
    live=root/"live"
    stage.mkdir()
    live.mkdir()
    for kind in ("candidate","rollback"):
        (stage/kind).mkdir()
        for file in (*FILES,"SHA256SUMS"):
            shutil.copy2(STAGE/kind/file,stage/kind/file)
    for file in FILES:
        shutil.copy2(stage/"rollback"/file,live/file)
    old=hashes(stage/"rollback")
    new=hashes(stage/"candidate")
    script_text=(STAGE/"swap.sh").read_text()
    assert script_text.count("SRC="+ORIGINAL_SRC)==1
    script=stage/"swap.sh"
    script.write_text(script_text.replace("SRC="+ORIGINAL_SRC,"SRC="+str(live)))
    script.chmod(0o700)
    def run(mode="apply",env=None):
        return subprocess.run(["bash",str(script),mode],capture_output=True,text=True,env=env,timeout=15)
    applied=run()
    assert applied.returncode==0,(applied.stdout[-400:],applied.stderr[-400:])
    assert hashes(live)==new, "candidate install mismatch"
    restored=run("rollback")
    assert restored.returncode==0,(restored.stdout[-400:],restored.stderr[-400:])
    assert hashes(live)==old, "rollback did not restore files"
    print("APPLY_AND_ROLLBACK_PASS")
    (live/"screen.css").write_bytes(b"deliberately different in sandbox only")
    before=hashes(live)
    drift=run()
    assert drift.returncode!=0 and "DRIFT" in drift.stderr
    assert hashes(live)==before, "drift guard mutated live"
    shutil.copy2(stage/"rollback"/"screen.css",live/"screen.css")
    print("DRIFT_REJECTED")
    shim=root/"bin"
    shim.mkdir()
    (shim/"mv").write_text(
        '#!/bin/bash\n'
        'if [[ "$3" == */screen.css ]]; then exit 97; fi\n'
        'exec /usr/bin/mv "$@"\n'
    )
    (shim/"mv").chmod(0o700)
    marker='/usr/bin/mv -f "$WORK/$f" "$SRC/$f"'
    src=script.read_text()
    assert src.count(marker)==1
    script.write_text(src.replace(marker,'mv -f "$WORK/$f" "$SRC/$f"'))
    env=dict(os.environ,PATH=str(shim)+":"+os.environ.get("PATH",""))
    failure=run(env=env)
    assert failure.returncode!=0, "failure injection not triggered"
    assert "restoring" in failure.stderr.lower(),failure.stderr[-300:]
    assert hashes(live)==old,"partial swap not restored"
    print("PARTIAL_FAILURE_AUTORESTORE_PASS")
print("ALL_ISOLATED_TESTS_PASS")
