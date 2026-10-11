from pathlib import Path
from tempfile import TemporaryDirectory
import shutil, subprocess, hashlib, ast, json, datetime, sys

stage=Path(r"C:\AFZ\Nuvio-Setup-20260923\onn-expired-token-repair-20261011")
original=stage/"stremio_catalog.original.py"
candidate=stage/"stremio_catalog.r2.candidate.py"
patch=stage/"expired-token-history-r2.patch"
live=Path(r"C:\AFZ\Stremio-Failover-H3\stremio_catalog.py")
want_original="d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f"
want_candidate="3dab113e23725a39401f8ba3c619b9eb0b6cd5eec47a0f677df2dc84404a74a5"

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

receipt={
    "time_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "original_source_sha":sha(original),
    "live_source_sha":sha(live),
    "staged_candidate_sha":sha(candidate),
    "expected_original":want_original,
    "expected_candidate":want_candidate,
    "status":"STARTED",
    "live_changed":False
}
try:
    assert sha(original)==want_original, "Original hash mismatch"
    assert sha(live)==want_original, "Live backend baseline unexpectedly changed"
    assert sha(candidate)==want_candidate, "Candidate hash mismatch"
    ast.parse(candidate.read_text(encoding="utf-8"))
    with TemporaryDirectory(prefix="afz_nuvio_r2_verification_") as t:
        temp=Path(t)
        shutil.copy2(original,temp/"stremio_catalog.py")
        for args in (
            ["git","-c","core.autocrlf=false","apply","--check",str(patch)],
            ["git","-c","core.autocrlf=false","apply",str(patch)]
        ):
            result=subprocess.run(args,cwd=temp,capture_output=True,text=True,timeout=25)
            assert result.returncode==0, f"Git apply failed: {result.stderr[:150]}"
        got=(temp/"stremio_catalog.py").read_bytes()
        assert got==candidate.read_bytes(), "Git-patched bytes differ from candidate"
    test=json.loads((stage/"r2-regression.json").read_text(encoding="utf-8"))
    integration=json.loads((stage/"r2-bridge-integration.json").read_text(encoding="utf-8"))
    assert test.get("result")=="PASS" and int(test.get("test_count") or 0)>=23
    assert integration.get("result")=="PASS" and len(integration.get("cases") or [])>=2
    receipt["test_count"]=test.get("test_count")
    receipt["bridge_integration_count"]=len(integration.get("cases") or [])
    receipt["patch_applies_byte_exact"]=True
    receipt["status"]="PASS"
except Exception as exc:
    receipt["status"]="FAIL"
    receipt["failure"]=type(exc).__name__+": "+str(exc)[:150]
(stage/"r2-artifact-verification.json").write_text(json.dumps(receipt,indent=2),encoding="utf-8")
print(json.dumps({k:v for k,v in receipt.items() if k not in {"expected_original","expected_candidate"}},indent=2))
sys.exit(0 if receipt["status"]=="PASS" else 1)
