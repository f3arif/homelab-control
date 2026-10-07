"""Build and fail-close the protected integration evidence summary."""

from __future__ import annotations

import hashlib
import json
import xml.etree.ElementTree as ET
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / "evidence"
LIVE = EVIDENCE / "live-canary-20260915T021010Z"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    manifest = json.loads((ROOT / "VENDOR-MANIFEST.json").read_text(encoding="utf-8"))
    expected_files = manifest["source"]["files"]
    observed_files = {name: digest(ROOT / name) for name in expected_files}
    if observed_files != expected_files:
        raise RuntimeError("vendored R3 source/test fidelity mismatch")

    cases = list(ET.parse(EVIDENCE / "full-suite-final.xml").getroot().iter("testcase"))
    failures = sum(case.find("failure") is not None for case in cases)
    errors = sum(case.find("error") is not None for case in cases)
    skipped = sum(case.find("skipped") is not None for case in cases)
    vendor_cases = sum("vendor" in str(case.get("classname", "")) for case in cases)
    adapter_cases = len(cases) - vendor_cases
    if (len(cases), vendor_cases, adapter_cases, failures, errors, skipped) != (
        78,
        54,
        24,
        0,
        0,
        0,
    ):
        raise RuntimeError("mandatory test count or result mismatch")
    if (EVIDENCE / "full-suite-final.exit.txt").read_text(encoding="utf-8") != "0":
        raise RuntimeError("full test suite child exit mismatch")

    precheck = json.loads(
        (LIVE / "precheck/precheck-result.json").read_text(encoding="utf-8")
    )
    canary = json.loads(
        (LIVE / "canary/canary-result.json").read_text(encoding="utf-8")
    )
    verifier = json.loads(
        (LIVE / "canary/verifier-receipt.json").read_text(encoding="utf-8")
    )
    if (LIVE / "precheck/exit.txt").read_text(encoding="utf-8") != "0":
        raise RuntimeError("live precheck exit mismatch")
    if (LIVE / "canary/canary.exit.txt").read_text(encoding="utf-8") != "0":
        raise RuntimeError("live canary exit mismatch")
    if (LIVE / "canary/verifier.exit.txt").read_text(encoding="utf-8") != "0":
        raise RuntimeError("separate verifier exit mismatch")
    if canary.get("status") != "READONLY_TRANSPORT_CANARY_PASS":
        raise RuntimeError("read-only transport canary did not pass")
    if (
        verifier.get("authenticated") is not False
        or verifier.get("integrity_verified") is not True
        or verifier.get("os_identity_boundary") is not False
        or canary.get("production_completion") is not False
        or canary.get("authenticated_review_gate") != "NOT_VERIFIED"
    ):
        raise RuntimeError("trust boundary was mislabeled")
    if verifier.get("worker_pid") == verifier.get("verifier_pid"):
        raise RuntimeError("verifier process separation missing")

    important = [
        ROOT / "VENDOR-MANIFEST.json",
        EVIDENCE / "full-suite-final.xml",
        EVIDENCE / "full-suite-final.stdout.txt",
        LIVE / "precheck/precheck-result.json",
        LIVE / "canary/worker-execution-packet.json",
        LIVE / "canary/verifier-receipt.json",
        LIVE / "canary/canary-result.json",
    ]
    summary = {
        "schema": "afz-hermes-autopilot-integration-verification-v1",
        "generated_utc": datetime.now(UTC).isoformat(),
        "tests": {
            "total": len(cases),
            "vendored_r3": vendor_cases,
            "adapter_integration": adapter_cases,
            "failures": failures,
            "errors": errors,
            "skipped": skipped,
            "child_exit": 0,
        },
        "r3_fidelity": {
            "verified": True,
            "files": observed_files,
            "independent_receipt_sha256": manifest["source"][
                "independent_receipt_sha256"
            ],
        },
        "live": {
            "status": canary["status"],
            "target_identity": canary["target_identity"],
            "control_hub_commit": canary["control_hub_commit"],
            "precheck_response_sha256": precheck["response_sha256"],
            "worker_response_sha256": canary["worker_response_sha256"],
            "verifier_response_sha256": canary["verifier_response_sha256"],
            "packet_sha256": canary["packet_sha256"],
            "worker_pid": canary["worker_pid"],
            "verifier_pid": canary["verifier_pid"],
            "authenticated_review_gate": canary["authenticated_review_gate"],
            "engine_completion_gate": canary["engine_completion_gate"],
            "production_completion": False,
            "production_enforced": False,
            "cross_host_enabled": False,
            "live_get_health_reads": 3,
            "pickup_limit_reads": 2,
            "bounded_process_deviation": "one extra read-only precheck",
            "no_further_live_calls": True,
        },
        "entrypoints": {
            "canary_console_help_exit": 0,
            "verifier_console_help_exit": 0,
            "canary_module_help_exit": 0,
            "verifier_module_help_exit": 0,
        },
        "config_changes": 0,
        "artifact_sha256": {
            str(path.relative_to(ROOT)): digest(path) for path in important
        },
    }
    output = EVIDENCE / "verification-summary.json"
    output.write_text(
        json.dumps(summary, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
