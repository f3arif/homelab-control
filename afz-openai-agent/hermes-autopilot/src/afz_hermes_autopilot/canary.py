"""MissionEngine wiring for the single read-only Control Hub health recipe."""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from afz_autopilot.core import (
    ChildResult,
    MissionEngine,
    Policy,
    ReviewReceipt,
    hash_file,
)

from .adapter import (
    CONTROL_SOURCE_SHA,
    HEALTH_RECIPE,
    AdmissionGuard,
    ControlHubContractError,
    FixedControlHubClient,
    write_execution_packet,
)

VerifierLauncher = Callable[..., dict[str, Any]]


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(
        json.dumps(value, sort_keys=True, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def launch_verifier_subprocess(
    *,
    packet_path: Path,
    packet_hash: str,
    source_hash: str,
    expected_commit: str,
    approval_id: str,
    evidence_dir: Path,
) -> dict[str, Any]:
    """Run the fresh read-back in another process; this is not an OS trust boundary."""
    output_path = evidence_dir / "verifier-process-output.json"
    command = [
        sys.executable,
        "-m",
        "afz_hermes_autopilot.verifier_cli",
        "--packet",
        str(packet_path),
        "--packet-sha256",
        packet_hash,
        "--source-sha256",
        source_hash,
        "--expected-commit",
        expected_commit,
        "--approval-id",
        approval_id,
        "--output",
        str(output_path),
    ]
    _write_json(evidence_dir / "verifier-command.json", command)
    environment = dict(os.environ)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    process = subprocess.run(
        command,
        cwd=Path(__file__).resolve().parent.parent.parent,
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=60,
        check=False,
    )
    (evidence_dir / "verifier.stdout.txt").write_text(process.stdout, encoding="utf-8")
    (evidence_dir / "verifier.stderr.txt").write_text(process.stderr, encoding="utf-8")
    (evidence_dir / "verifier.exit.txt").write_text(
        str(process.returncode), encoding="utf-8"
    )
    if process.returncode != 0:
        raise ControlHubContractError(
            f"separate verifier process failed with exit {process.returncode}"
        )
    if not output_path.is_file():
        raise ControlHubContractError(
            "separate verifier process did not produce a receipt"
        )
    try:
        result = json.loads(output_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ControlHubContractError("separate verifier receipt is invalid") from error
    if not isinstance(result, dict):
        raise ControlHubContractError("separate verifier receipt must be an object")
    return result


def execute_health_canary(
    *,
    state_db: str | Path,
    admission_db: str | Path,
    evidence_dir: str | Path,
    authorization_key: str,
    source_task_id: str,
    source_task_status: str,
    worker_client: FixedControlHubClient | None = None,
    verifier_launcher: VerifierLauncher = launch_verifier_subprocess,
    clock: Callable[[], float] = time.time,
    worker_pid: int | None = None,
) -> dict[str, Any]:
    """Admit once, run one GET, and gate completion on a fresh verifier process read."""
    evidence = Path(evidence_dir).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    authorization_sha256 = hashlib.sha256(authorization_key.encode("utf-8")).hexdigest()
    policy = Policy(
        allowed_actions=frozenset({"execute"}),
        approved_routes=frozenset({"local"}),
        required_reviewer="control-health-verifier-process",
        required_approval=authorization_sha256,
        production_enforced=False,
    )
    engine = MissionEngine(Path(state_db), policy=policy, clock=clock)
    guard = AdmissionGuard(Path(admission_db), clock=clock)
    mission_id = guard.admit_recipe(
        engine,
        source_task_id=source_task_id,
        source_task_status=source_task_status,
        authorization_key=authorization_key,
        recipe_name=HEALTH_RECIPE.name,
    )
    source_path = Path(__file__).with_name("adapter.py").resolve()
    source_hash = hash_file(source_path)
    packet_path = evidence / "worker-execution-packet.json"
    verifier_receipt_path = evidence / "verifier-receipt.json"
    try:
        engine.add_step(
            mission_id,
            HEALTH_RECIPE.name,
            action="execute",
            source_path=source_path,
            expected_artifacts=[packet_path],
            required_tests=1,
        )
    except sqlite3.IntegrityError:
        existing = engine.step(mission_id, HEALTH_RECIPE.name)
        if Path(existing["source_path"]).resolve() != source_path or existing[
            "expected_artifacts"
        ] != [str(packet_path)]:
            raise ControlHubContractError(
                "duplicate admission step binding mismatch"
            ) from None

    client = worker_client or FixedControlHubClient()
    actual_worker_pid = os.getpid() if worker_pid is None else int(worker_pid)

    def runner(step: dict[str, Any], attempt: int) -> ChildResult:
        result = client.run_recipe(
            HEALTH_RECIPE.name, expected_commit=CONTROL_SOURCE_SHA
        )
        packet_hash = write_execution_packet(
            packet_path,
            result=result,
            source_hash=source_hash,
            observed_unix=clock(),
            worker_pid=actual_worker_pid,
        )
        typed_result = {
            "schema": "afz-control-health-child-result-v1",
            "attempt": attempt,
            "recipe": result.recipe_name,
            "request": {"method": result.method, "path": result.path, "body": None},
            "target_identity": result.target_identity,
            "control_hub_commit": result.control_hub_commit,
            "response_sha256": result.response_sha256,
            "packet_sha256": packet_hash,
            "capability_contract": result.capability_contract,
            "production_enforced": False,
            "cross_host_enabled": False,
        }
        return ChildResult(
            exit_code=0,
            tests_executed=1,
            tests_skipped=0,
            source_hash=source_hash,
            artifact_hashes={str(packet_path): packet_hash},
            narrative=json.dumps(typed_result, sort_keys=True, separators=(",", ":")),
            target_readback=True,
        )

    def verifier(step: dict[str, Any], child: ChildResult) -> ReviewReceipt:
        packet_hash = child.artifact_hashes.get(str(packet_path), "")
        receipt = verifier_launcher(
            packet_path=packet_path,
            packet_hash=packet_hash,
            source_hash=source_hash,
            expected_commit=CONTROL_SOURCE_SHA,
            approval_id=authorization_sha256,
            evidence_dir=evidence,
        )
        required = {
            "schema": "afz-control-health-verifier-receipt-v1",
            "verifier": "control-health-verifier-process",
            "authenticated": False,
            "integrity_verified": True,
            "authentication_scope": "immutable-packet-hash-only",
            "os_identity_boundary": False,
            "target_readback": True,
            "control_hub_commit": CONTROL_SOURCE_SHA,
            "packet_sha256": packet_hash,
            "source_sha256": source_hash,
            "approval_id": authorization_sha256,
            "production_enforced": False,
            "cross_host_enabled": False,
        }
        if any(receipt.get(key) != value for key, value in required.items()):
            raise ControlHubContractError("separate verifier receipt contract mismatch")
        if receipt.get("worker_pid") == receipt.get("verifier_pid"):
            raise ControlHubContractError("verifier did not prove process separation")
        _write_json(verifier_receipt_path, receipt)
        return ReviewReceipt(
            verifier=str(receipt["verifier"]),
            authenticated=False,
            source_hash=source_hash,
            artifact_hashes=child.artifact_hashes,
            approval_id=authorization_sha256,
            target_readback=True,
        )

    engine.run_until_parked(mission_id, runner, verifier)
    mission = engine.mission(mission_id)
    step = engine.step(mission_id, HEALTH_RECIPE.name)
    child_result = step.get("child") or {}
    review_receipt = (
        json.loads(verifier_receipt_path.read_text(encoding="utf-8"))
        if verifier_receipt_path.is_file()
        else {}
    )
    typed_child = json.loads(child_result.get("narrative", "{}"))
    outcome = {
        "schema": "afz-control-health-canary-result-v1",
        "status": (
            "READONLY_TRANSPORT_CANARY_PASS"
            if review_receipt.get("integrity_verified") is True
            and review_receipt.get("target_readback") is True
            and review_receipt.get("authenticated") is False
            else "READONLY_TRANSPORT_CANARY_FAIL"
        ),
        "mission_id": mission_id,
        "mission_status": mission["status"],
        "step_status": step["status"],
        "step_reason": step["reason"],
        "canary_readback_status": (
            "passed"
            if review_receipt.get("integrity_verified") is True
            and review_receipt.get("target_readback") is True
            and review_receipt.get("authenticated") is False
            else "failed"
        ),
        "recipe": HEALTH_RECIPE.name,
        "target_identity": typed_child.get("target_identity"),
        "control_hub_commit": typed_child.get("control_hub_commit"),
        "worker_response_sha256": typed_child.get("response_sha256"),
        "verifier_response_sha256": review_receipt.get("fresh_response_sha256"),
        "packet_sha256": typed_child.get("packet_sha256"),
        "source_sha256": source_hash,
        "authorization_sha256": authorization_sha256,
        "worker_pid": actual_worker_pid,
        "verifier_pid": review_receipt.get("verifier_pid"),
        "packet_path": str(packet_path),
        "verifier_receipt_path": str(verifier_receipt_path),
        "child_result": child_result,
        "review_receipt": step.get("review"),
        "production_enforced": bool(mission["production_enforced"]),
        "cross_host_enabled": bool(engine.cross_host_enabled),
        "os_identity_boundary_verified": False,
        "authenticated_review_gate": "NOT_VERIFIED",
        "engine_completion_gate": "HELD_UNAUTHENTICATED",
        "authorization_provenance_verified": False,
        "production_completion": False,
        "config_changes": 0,
    }
    _write_json(evidence / "canary-result.json", outcome)
    return outcome
