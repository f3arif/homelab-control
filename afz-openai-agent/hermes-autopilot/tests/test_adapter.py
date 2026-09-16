"""Contract tests for the protected typed Control Hub adapter."""

from __future__ import annotations

import hashlib
import json
from dataclasses import replace
from pathlib import Path

import pytest

# isort: split
from afz_autopilot.core import MissionEngine, Policy
from afz_hermes_autopilot.adapter import (
    BASE_URL,
    CONTROL_SOURCE_SHA,
    HEALTH_RECIPE,
    AdmissionDenied,
    AdmissionGuard,
    CapabilityAttestationError,
    ControlHubContractError,
    FixedControlHubClient,
    NetworkReadError,
    PacketVerificationError,
    _validate_recipe,
    verify_packet,
    write_execution_packet,
)


def health_payload(*, commit: str = CONTROL_SOURCE_SHA) -> dict:
    return {
        "ok": True,
        "service": "AFZ-Agent-Control",
        "version": "1.10.2",
        "commit": commit,
        "windowsWslMemoryAudit": {
            "typed": True,
            "route": "/api/windows-wsl-memory-audit",
            "actions": ["audit"],
            "readOnly": True,
            "arbitraryShell": False,
        },
        "time": "2026-09-15T02:00:00.0000000-04:00",
    }


def encoded_health(**kwargs) -> bytes:
    return json.dumps(health_payload(**kwargs), separators=(",", ":")).encode()


class Transport:
    def __init__(
        self, responses: list[bytes] | None = None, error: Exception | None = None
    ):
        self.responses = list(responses or [])
        self.error = error
        self.calls: list[tuple[str, str, bytes | None, float]] = []

    def __call__(
        self, url: str, method: str, body: bytes | None, timeout: float
    ) -> bytes:
        self.calls.append((url, method, body, timeout))
        if self.error:
            raise self.error
        return self.responses.pop(0)


@pytest.mark.parametrize(
    "bad",
    [
        "https://100.70.25.8:8797",
        "http://100.70.25.9:8797",
        "http://100.70.25.8:8798",
        "http://user@100.70.25.8:8797",
        "http://100.70.25.8:8797/",
        "http://100.70.25.8:8797/health",
        "http://100.70.25.8:8797?x=1",
        "http://100.70.25.8:8797#fragment",
    ],
)
def test_fixed_base_url_rejects_every_variant(bad: str) -> None:
    with pytest.raises(ControlHubContractError):
        FixedControlHubClient(base_url=bad, transport=Transport([encoded_health()]))


def test_health_recipe_uses_only_registry_derived_get_without_body() -> None:
    transport = Transport([encoded_health()])
    result = FixedControlHubClient(transport=transport).run_recipe(
        "control-health-readonly-v1", expected_commit=CONTROL_SOURCE_SHA, timeout=3.5
    )

    assert transport.calls == [(f"{BASE_URL}/health", "GET", None, 3.5)]
    assert result.method == "GET"
    assert result.path == "/health"
    assert result.target_identity == "windows-main@100.70.25.8:8797"
    assert result.control_hub_commit == CONTROL_SOURCE_SHA


def test_unknown_recipe_and_arbitrary_recipe_shapes_are_rejected() -> None:
    client = FixedControlHubClient(transport=Transport([encoded_health()]))
    with pytest.raises(ControlHubContractError, match="unknown recipe"):
        client.run_recipe("user-supplied-path", expected_commit=CONTROL_SOURCE_SHA)

    for bad in (
        replace(HEALTH_RECIPE, method="POST"),
        replace(HEALTH_RECIPE, path="/api/control"),
        replace(HEALTH_RECIPE, body={"action": "anything"}),
        replace(HEALTH_RECIPE, path="/health?x=1"),
    ):
        with pytest.raises(ControlHubContractError):
            _validate_recipe(bad)


def test_commit_mismatch_fails_closed() -> None:
    wrong = "1" * 40
    client = FixedControlHubClient(transport=Transport([encoded_health(commit=wrong)]))
    with pytest.raises(CapabilityAttestationError, match="commit"):
        client.run_recipe(
            "control-health-readonly-v1", expected_commit=CONTROL_SOURCE_SHA
        )


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("typed", False),
        ("arbitraryShell", True),
        ("readOnly", False),
        ("route", "/other"),
    ],
)
def test_route_capability_mismatch_fails_closed(field: str, value: object) -> None:
    payload = health_payload()
    payload["windowsWslMemoryAudit"][field] = value
    client = FixedControlHubClient(
        transport=Transport([json.dumps(payload, separators=(",", ":")).encode()])
    )
    with pytest.raises(CapabilityAttestationError, match="windowsWslMemoryAudit"):
        client.run_recipe(
            "control-health-readonly-v1", expected_commit=CONTROL_SOURCE_SHA
        )


def test_network_timeout_is_sanitized_and_fails_closed() -> None:
    client = FixedControlHubClient(
        transport=Transport(error=TimeoutError("private endpoint"))
    )
    with pytest.raises(NetworkReadError, match="timed out") as raised:
        client.run_recipe(
            "control-health-readonly-v1", expected_commit=CONTROL_SOURCE_SHA
        )
    assert "private endpoint" not in str(raised.value)


def test_execution_packet_contains_bound_target_commit_and_response_hash(
    tmp_path: Path,
) -> None:
    raw = encoded_health()
    result = FixedControlHubClient(transport=Transport([raw])).run_recipe(
        "control-health-readonly-v1", expected_commit=CONTROL_SOURCE_SHA
    )
    packet_path = tmp_path / "packet.json"
    packet_hash = write_execution_packet(
        packet_path,
        result=result,
        source_hash="a" * 64,
        observed_unix=1000.0,
        worker_pid=101,
    )
    packet = json.loads(packet_path.read_text())

    assert packet["target_identity"] == "windows-main@100.70.25.8:8797"
    assert packet["control_hub_commit"] == CONTROL_SOURCE_SHA
    assert packet["response_sha256"] == hashlib.sha256(raw).hexdigest()
    assert packet["request"] == {"method": "GET", "path": "/health", "body": None}
    assert packet_hash == hashlib.sha256(packet_path.read_bytes()).hexdigest()


def test_packet_mutation_and_staleness_are_rejected(tmp_path: Path) -> None:
    raw = encoded_health()
    result = FixedControlHubClient(transport=Transport([raw])).run_recipe(
        "control-health-readonly-v1", expected_commit=CONTROL_SOURCE_SHA
    )
    packet_path = tmp_path / "packet.json"
    digest = write_execution_packet(
        packet_path,
        result=result,
        source_hash="a" * 64,
        observed_unix=1000.0,
        worker_pid=101,
    )

    packet_path.write_bytes(packet_path.read_bytes() + b" ")
    with pytest.raises(PacketVerificationError, match="packet hash"):
        verify_packet(
            packet_path,
            expected_packet_hash=digest,
            expected_commit=CONTROL_SOURCE_SHA,
            expected_source_hash="a" * 64,
            client=FixedControlHubClient(transport=Transport([raw])),
            now_unix=1001.0,
            verifier_pid=202,
        )

    digest = write_execution_packet(
        packet_path,
        result=result,
        source_hash="a" * 64,
        observed_unix=1000.0,
        worker_pid=101,
    )
    with pytest.raises(PacketVerificationError, match="stale"):
        verify_packet(
            packet_path,
            expected_packet_hash=digest,
            expected_commit=CONTROL_SOURCE_SHA,
            expected_source_hash="a" * 64,
            client=FixedControlHubClient(transport=Transport([raw])),
            now_unix=1401.0,
            verifier_pid=202,
        )


def test_fresh_verifier_readback_revalidates_contract_in_another_pid(
    tmp_path: Path,
) -> None:
    first_raw = encoded_health()
    second_payload = health_payload()
    second_payload["time"] = "2026-09-15T02:00:01.0000000-04:00"
    second_raw = json.dumps(second_payload, separators=(",", ":")).encode()
    result = FixedControlHubClient(transport=Transport([first_raw])).run_recipe(
        "control-health-readonly-v1", expected_commit=CONTROL_SOURCE_SHA
    )
    packet_path = tmp_path / "packet.json"
    digest = write_execution_packet(
        packet_path,
        result=result,
        source_hash="a" * 64,
        observed_unix=1000.0,
        worker_pid=101,
    )

    receipt = verify_packet(
        packet_path,
        expected_packet_hash=digest,
        expected_commit=CONTROL_SOURCE_SHA,
        expected_source_hash="a" * 64,
        client=FixedControlHubClient(transport=Transport([second_raw])),
        now_unix=1001.0,
        verifier_pid=202,
    )

    assert receipt["target_readback"] is True
    assert receipt["verifier_pid"] == 202
    assert receipt["worker_pid"] == 101
    assert receipt["fresh_response_sha256"] == hashlib.sha256(second_raw).hexdigest()
    assert receipt["packet_response_sha256"] == hashlib.sha256(first_raw).hexdigest()
    assert receipt["authenticated"] is False
    assert receipt["integrity_verified"] is True
    assert receipt["os_identity_boundary"] is False
    assert receipt["authentication_scope"] == "immutable-packet-hash-only"


def test_fresh_verifier_rejects_response_contract_change(tmp_path: Path) -> None:
    raw = encoded_health()
    result = FixedControlHubClient(transport=Transport([raw])).run_recipe(
        "control-health-readonly-v1", expected_commit=CONTROL_SOURCE_SHA
    )
    packet_path = tmp_path / "packet.json"
    digest = write_execution_packet(
        packet_path,
        result=result,
        source_hash="a" * 64,
        observed_unix=1000.0,
        worker_pid=101,
    )
    changed = health_payload()
    changed["windowsWslMemoryAudit"]["typed"] = False

    with pytest.raises(CapabilityAttestationError):
        verify_packet(
            packet_path,
            expected_packet_hash=digest,
            expected_commit=CONTROL_SOURCE_SHA,
            expected_source_hash="a" * 64,
            client=FixedControlHubClient(
                transport=Transport(
                    [json.dumps(changed, separators=(",", ":")).encode()]
                )
            ),
            now_unix=1001.0,
            verifier_pid=202,
        )


def test_held_triage_requires_new_key_and_duplicate_key_cannot_create_fresh_mission(
    tmp_path: Path,
) -> None:
    engine = MissionEngine(
        tmp_path / "engine.sqlite3", policy=Policy(), clock=lambda: 1000.0
    )
    guard = AdmissionGuard(tmp_path / "admission.sqlite3", clock=lambda: 1000.0)

    with pytest.raises(AdmissionDenied, match="explicit authorization"):
        guard.admit_recipe(
            engine,
            source_task_id="t_held",
            source_task_status="triage",
            authorization_key="",
            recipe_name="control-health-readonly-v1",
        )

    first = guard.admit_recipe(
        engine,
        source_task_id="t_held",
        source_task_status="triage",
        authorization_key="new-integration-authorization",
        recipe_name="control-health-readonly-v1",
    )
    duplicate = guard.admit_recipe(
        engine,
        source_task_id="t_held",
        source_task_status="triage",
        authorization_key="new-integration-authorization",
        recipe_name="control-health-readonly-v1",
    )

    assert duplicate == first
    assert engine.mission_count() == 1


def test_authorization_key_cannot_be_rebound_to_another_recipe_or_task(
    tmp_path: Path,
) -> None:
    engine = MissionEngine(
        tmp_path / "engine.sqlite3", policy=Policy(), clock=lambda: 1000.0
    )
    guard = AdmissionGuard(tmp_path / "admission.sqlite3", clock=lambda: 1000.0)
    guard.admit_recipe(
        engine,
        source_task_id="t_held",
        source_task_status="triage",
        authorization_key="one-use-key",
        recipe_name="control-health-readonly-v1",
    )

    with pytest.raises(AdmissionDenied, match="already bound"):
        guard.admit_recipe(
            engine,
            source_task_id="t_other",
            source_task_status="blocked",
            authorization_key="one-use-key",
            recipe_name="control-health-readonly-v1",
        )
