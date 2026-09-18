"""MissionEngine wiring tests for the typed read-only canary."""

from __future__ import annotations

import json
from pathlib import Path

from afz_hermes_autopilot.adapter import (
    CONTROL_SOURCE_SHA,
    FixedControlHubClient,
    verify_packet,
)
from afz_hermes_autopilot.canary import execute_health_canary


def health_bytes(stamp: str) -> bytes:
    return json.dumps(
        {
            "ok": True,
            "service": "AFZ-Agent-Control",
            "version": "1.10.2",
            "commit": CONTROL_SOURCE_SHA,
            "windowsWslMemoryAudit": {
                "typed": True,
                "route": "/api/windows-wsl-memory-audit",
                "actions": ["audit"],
                "readOnly": True,
                "arbitraryShell": False,
            },
            "time": stamp,
        },
        separators=(",", ":"),
    ).encode()


class OneRead:
    def __init__(self, raw: bytes):
        self.raw = raw
        self.calls = 0

    def __call__(
        self, url: str, method: str, body: bytes | None, timeout: float
    ) -> bytes:
        self.calls += 1
        assert url == "http://100.70.25.8:8797/health"
        assert method == "GET" and body is None
        return self.raw


def test_readonly_canary_success_is_durable_and_freshly_verified(
    tmp_path: Path,
) -> None:
    worker_transport = OneRead(health_bytes("worker"))
    verifier_transport = OneRead(health_bytes("verifier"))
    seen: dict = {}

    def verifier_launcher(**kwargs):
        seen.update(kwargs)
        receipt = verify_packet(
            kwargs["packet_path"],
            expected_packet_hash=kwargs["packet_hash"],
            expected_commit=kwargs["expected_commit"],
            expected_source_hash=kwargs["source_hash"],
            client=FixedControlHubClient(transport=verifier_transport),
            now_unix=1001.0,
            verifier_pid=202,
        )
        receipt["approval_id"] = kwargs["approval_id"]
        return receipt

    result = execute_health_canary(
        state_db=tmp_path / "state.sqlite3",
        admission_db=tmp_path / "admission.sqlite3",
        evidence_dir=tmp_path / "evidence",
        authorization_key="new-protected-integration-key",
        source_task_id="t_834aebec",
        source_task_status="triage",
        worker_client=FixedControlHubClient(transport=worker_transport),
        verifier_launcher=verifier_launcher,
        clock=lambda: 1000.0,
        worker_pid=101,
    )

    assert result["status"] == "READONLY_TRANSPORT_CANARY_PASS"
    assert result["canary_readback_status"] == "passed"
    assert result["authenticated_review_gate"] == "NOT_VERIFIED"
    assert result["production_completion"] is False
    assert result["authorization_provenance_verified"] is False
    assert result["mission_status"] == "checkpointed"
    assert result["step_status"] == "failed"
    assert result["engine_completion_gate"] == "HELD_UNAUTHENTICATED"
    assert "authenticated reviewer identity mismatch" in result["step_reason"]
    assert result["production_enforced"] is False
    assert result["cross_host_enabled"] is False
    assert result["worker_response_sha256"] != result["verifier_response_sha256"]
    assert result["worker_pid"] == 101 and result["verifier_pid"] == 202
    assert worker_transport.calls == 1 and verifier_transport.calls == 1
    assert Path(result["packet_path"]).is_file()
    assert Path(result["verifier_receipt_path"]).is_file()
    child = result["child_result"]
    typed = json.loads(child["narrative"])
    assert typed["target_identity"] == "windows-main@100.70.25.8:8797"
    assert typed["control_hub_commit"] == CONTROL_SOURCE_SHA
    assert typed["response_sha256"] == result["worker_response_sha256"]
    assert seen["approval_id"] == result["authorization_sha256"]
    assert result["review_receipt"]["authenticated"] is False


def test_duplicate_authorization_reuses_held_mission_without_second_network_call(
    tmp_path: Path,
) -> None:
    worker_transport = OneRead(health_bytes("worker"))
    verifier_transport = OneRead(health_bytes("verifier"))

    def verifier_launcher(**kwargs):
        receipt = verify_packet(
            kwargs["packet_path"],
            expected_packet_hash=kwargs["packet_hash"],
            expected_commit=kwargs["expected_commit"],
            expected_source_hash=kwargs["source_hash"],
            client=FixedControlHubClient(transport=verifier_transport),
            now_unix=1001.0,
            verifier_pid=202,
        )
        receipt["approval_id"] = kwargs["approval_id"]
        return receipt

    arguments = {
        "state_db": tmp_path / "state.sqlite3",
        "admission_db": tmp_path / "admission.sqlite3",
        "evidence_dir": tmp_path / "evidence",
        "authorization_key": "one-admission",
        "source_task_id": "t_834aebec",
        "source_task_status": "triage",
        "worker_client": FixedControlHubClient(transport=worker_transport),
        "verifier_launcher": verifier_launcher,
        "clock": lambda: 1000.0,
        "worker_pid": 101,
    }
    first = execute_health_canary(**arguments)
    second = execute_health_canary(**arguments)

    assert second["mission_id"] == first["mission_id"]
    assert worker_transport.calls == 1
    assert verifier_transport.calls == 1
