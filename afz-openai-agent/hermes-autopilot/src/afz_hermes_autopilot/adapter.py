"""Fixed-route, fail-closed adapter for AFZ Agent Control.

This module deliberately exposes no generic HTTP method.  The Python registry is
defense in depth; Windows-main's typed endpoint allowlist, source-SHA checks and
peer checks remain the production action boundary.
"""

from __future__ import annotations

import base64
import hashlib
import json
import re
import sqlite3
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from afz_autopilot.core import MissionEngine

BASE_URL = "http://100.70.25.8:8797"
CONTROL_SOURCE_SHA = "0e8987577c5d5860ca55cdff4e1943bc22ff67e9"
TARGET_IDENTITY = "windows-main@100.70.25.8:8797"
MAX_RESPONSE_BYTES = 1024 * 1024
PACKET_MAX_AGE_SECONDS = 300.0
_SHA40 = re.compile(r"[0-9a-f]{40}")
_SHA64 = re.compile(r"[0-9a-f]{64}")


class ControlHubContractError(RuntimeError):
    """A caller or response violated the fixed typed contract."""


class CapabilityAttestationError(ControlHubContractError):
    """The live health response did not attest the required source/capability."""


class NetworkReadError(ControlHubContractError):
    """A bounded read-only request failed without leaking endpoint details."""


class PacketVerificationError(ControlHubContractError):
    """An immutable worker packet failed verifier validation."""


class AdmissionDenied(ControlHubContractError):
    """A held/history task lacked a new, single-binding authorization."""


@dataclass(frozen=True)
class CapabilityRequirement:
    name: str
    route: str
    action: str
    read_only: bool = True


@dataclass(frozen=True)
class Recipe:
    name: str
    method: str
    path: str
    body: dict[str, Any] | None
    capability: CapabilityRequirement


HEALTH_RECIPE = Recipe(
    name="control-health-readonly-v1",
    method="GET",
    path="/health",
    body=None,
    capability=CapabilityRequirement(
        name="windowsWslMemoryAudit",
        route="/api/windows-wsl-memory-audit",
        action="audit",
        read_only=True,
    ),
)
_RECIPES = {HEALTH_RECIPE.name: HEALTH_RECIPE}


@dataclass(frozen=True)
class ExecutionResult:
    recipe_name: str
    method: str
    path: str
    target_identity: str
    expected_commit: str
    control_hub_commit: str
    service: str
    response_sha256: str
    raw_response: bytes
    capability_contract: dict[str, Any]


Transport = Callable[[str, str, bytes | None, float], bytes]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect denied", headers, fp)


def _urllib_transport(
    url: str, method: str, body: bytes | None, timeout: float
) -> bytes:
    request = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers={"Accept": "application/json", "Cache-Control": "no-store"},
    )
    opener = urllib.request.build_opener(_NoRedirect())
    with opener.open(request, timeout=timeout) as response:
        if response.geturl() != url:
            raise ControlHubContractError("redirected target rejected")
        raw = response.read(MAX_RESPONSE_BYTES + 1)
    if len(raw) > MAX_RESPONSE_BYTES:
        raise ControlHubContractError("health response exceeds fixed size limit")
    return raw


def _validate_base_url(base_url: str) -> None:
    parsed = urlsplit(base_url)
    if (
        base_url != BASE_URL
        or parsed.scheme != "http"
        or parsed.hostname != "100.70.25.8"
        or parsed.port != 8797
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path
        or parsed.query
        or parsed.fragment
    ):
        raise ControlHubContractError("base URL is not the fixed Control Hub target")


def _validate_recipe(recipe: Recipe) -> None:
    if recipe != HEALTH_RECIPE:
        raise ControlHubContractError(
            "recipe does not match the fixed registry contract"
        )
    parsed = urlsplit(recipe.path)
    if (
        recipe.method != "GET"
        or recipe.path != "/health"
        or recipe.body is not None
        or parsed.scheme
        or parsed.netloc
        or parsed.query
        or parsed.fragment
    ):
        raise ControlHubContractError("recipe method/path/body is not allowed")


def _canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")


def _attest_health(
    raw: bytes, expected_commit: str, recipe: Recipe
) -> tuple[dict[str, Any], dict[str, Any]]:
    if not _SHA40.fullmatch(expected_commit):
        raise ControlHubContractError(
            "expected commit must be an exact lowercase SHA-1"
        )
    if len(raw) > MAX_RESPONSE_BYTES:
        raise ControlHubContractError("health response exceeds fixed size limit")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CapabilityAttestationError(
            "health response is not valid UTF-8 JSON"
        ) from error
    if not isinstance(payload, dict):
        raise CapabilityAttestationError("health response must be an object")
    if payload.get("ok") is not True:
        raise CapabilityAttestationError("health ok attestation mismatch")
    if payload.get("service") != "AFZ-Agent-Control":
        raise CapabilityAttestationError("health service attestation mismatch")
    if payload.get("commit") != expected_commit:
        raise CapabilityAttestationError("health commit attestation mismatch")

    requirement = recipe.capability
    capability = payload.get(requirement.name)
    if not isinstance(capability, dict):
        raise CapabilityAttestationError(f"{requirement.name} capability is missing")
    actions = capability.get("actions")
    valid = (
        capability.get("typed") is True
        and capability.get("arbitraryShell") is False
        and capability.get("route") == requirement.route
        and isinstance(actions, list)
        and actions == [requirement.action]
        and capability.get("readOnly") is requirement.read_only
    )
    if not valid:
        raise CapabilityAttestationError(
            f"{requirement.name} typed capability mismatch"
        )
    contract = {
        "name": requirement.name,
        "typed": True,
        "arbitraryShell": False,
        "route": requirement.route,
        "actions": [requirement.action],
        "readOnly": requirement.read_only,
    }
    return payload, contract


class FixedControlHubClient:
    """Client whose only public operation executes a named immutable recipe."""

    def __init__(
        self, *, base_url: str = BASE_URL, transport: Transport | None = None
    ) -> None:
        _validate_base_url(base_url)
        self._base_url = base_url
        self._transport = transport or _urllib_transport

    def run_recipe(
        self,
        recipe_name: str,
        *,
        expected_commit: str,
        timeout: float = 10.0,
    ) -> ExecutionResult:
        recipe = _RECIPES.get(recipe_name)
        if recipe is None:
            raise ControlHubContractError("unknown recipe")
        _validate_recipe(recipe)
        if (
            not isinstance(timeout, (int, float))
            or isinstance(timeout, bool)
            or not 0 < timeout <= 30
        ):
            raise ControlHubContractError(
                "timeout must be within the fixed 0-30 second bound"
            )
        url = self._base_url + recipe.path
        try:
            raw = self._transport(url, recipe.method, None, float(timeout))
        except TimeoutError as error:
            raise NetworkReadError("Control Hub read timed out") from error
        except urllib.error.URLError as error:
            if isinstance(error.reason, TimeoutError):
                raise NetworkReadError("Control Hub read timed out") from error
            raise NetworkReadError("Control Hub read unavailable") from error
        except ControlHubContractError:
            raise
        except Exception as error:
            raise NetworkReadError("Control Hub read unavailable") from error
        if not isinstance(raw, bytes):
            raise ControlHubContractError("transport must return response bytes")
        payload, capability = _attest_health(raw, expected_commit, recipe)
        return ExecutionResult(
            recipe_name=recipe.name,
            method=recipe.method,
            path=recipe.path,
            target_identity=TARGET_IDENTITY,
            expected_commit=expected_commit,
            control_hub_commit=str(payload["commit"]),
            service=str(payload["service"]),
            response_sha256=hashlib.sha256(raw).hexdigest(),
            raw_response=raw,
            capability_contract=capability,
        )


def write_execution_packet(
    path: str | Path,
    *,
    result: ExecutionResult,
    source_hash: str,
    observed_unix: float | None = None,
    worker_pid: int,
) -> str:
    if not _SHA64.fullmatch(source_hash):
        raise ControlHubContractError("source hash must be an exact lowercase SHA-256")
    observed = time.time() if observed_unix is None else float(observed_unix)
    packet = {
        "schema": "afz-control-health-execution-packet-v1",
        "recipe": result.recipe_name,
        "request": {"method": result.method, "path": result.path, "body": None},
        "target_identity": result.target_identity,
        "expected_commit": result.expected_commit,
        "control_hub_commit": result.control_hub_commit,
        "service": result.service,
        "capability_contract": result.capability_contract,
        "response_sha256": result.response_sha256,
        "response_body_base64": base64.b64encode(result.raw_response).decode("ascii"),
        "source_sha256": source_hash,
        "observed_unix": observed,
        "observed_utc": datetime.fromtimestamp(observed, UTC).isoformat(),
        "worker_pid": int(worker_pid),
        "production_enforced": False,
        "cross_host_enabled": False,
    }
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_bytes(_canonical_json_bytes(packet) + b"\n")
    temporary.replace(destination)
    return hashlib.sha256(destination.read_bytes()).hexdigest()


def verify_packet(
    packet_path: str | Path,
    *,
    expected_packet_hash: str,
    expected_commit: str,
    expected_source_hash: str,
    client: FixedControlHubClient,
    now_unix: float | None = None,
    verifier_pid: int,
) -> dict[str, Any]:
    if not _SHA64.fullmatch(expected_packet_hash):
        raise PacketVerificationError("expected packet hash is malformed")
    raw_packet = Path(packet_path).read_bytes()
    if hashlib.sha256(raw_packet).hexdigest() != expected_packet_hash:
        raise PacketVerificationError("packet hash mismatch")
    try:
        packet = json.loads(raw_packet)
    except json.JSONDecodeError as error:
        raise PacketVerificationError("packet JSON is invalid") from error
    if (
        not isinstance(packet, dict)
        or packet.get("schema") != "afz-control-health-execution-packet-v1"
    ):
        raise PacketVerificationError("packet schema mismatch")
    if packet.get("source_sha256") != expected_source_hash:
        raise PacketVerificationError("packet source hash mismatch")
    if packet.get("worker_pid") == int(verifier_pid):
        raise PacketVerificationError("verifier must run in a separate process")
    observed = packet.get("observed_unix")
    if not isinstance(observed, (int, float)) or isinstance(observed, bool):
        raise PacketVerificationError("packet observation time is invalid")
    now = time.time() if now_unix is None else float(now_unix)
    age = now - float(observed)
    if age < -5 or age > PACKET_MAX_AGE_SECONDS:
        raise PacketVerificationError("packet is stale or from the future")
    if (
        packet.get("recipe") != HEALTH_RECIPE.name
        or packet.get("request") != {"method": "GET", "path": "/health", "body": None}
        or packet.get("target_identity") != TARGET_IDENTITY
        or packet.get("expected_commit") != expected_commit
        or packet.get("control_hub_commit") != expected_commit
        or packet.get("service") != "AFZ-Agent-Control"
        or packet.get("production_enforced") is not False
        or packet.get("cross_host_enabled") is not False
    ):
        raise PacketVerificationError("packet target or response contract mismatch")
    try:
        packet_response = base64.b64decode(
            packet["response_body_base64"], validate=True
        )
    except (KeyError, ValueError) as error:
        raise PacketVerificationError(
            "packet response body encoding is invalid"
        ) from error
    packet_response_hash = hashlib.sha256(packet_response).hexdigest()
    if packet_response_hash != packet.get("response_sha256"):
        raise PacketVerificationError("packet response hash mismatch")
    _, packet_capability = _attest_health(
        packet_response, expected_commit, HEALTH_RECIPE
    )
    if packet.get("capability_contract") != packet_capability:
        raise PacketVerificationError("packet capability contract mismatch")

    fresh = client.run_recipe(HEALTH_RECIPE.name, expected_commit=expected_commit)
    if (
        fresh.target_identity != packet["target_identity"]
        or fresh.method != packet["request"]["method"]
        or fresh.path != packet["request"]["path"]
        or fresh.control_hub_commit != packet["control_hub_commit"]
        or fresh.capability_contract != packet["capability_contract"]
    ):
        raise PacketVerificationError("fresh target read-back contract mismatch")
    return {
        "schema": "afz-control-health-verifier-receipt-v1",
        "verifier": "control-health-verifier-process",
        "authenticated": False,
        "integrity_verified": True,
        "authentication_scope": "immutable-packet-hash-only",
        "os_identity_boundary": False,
        "target_readback": True,
        "target_identity": TARGET_IDENTITY,
        "control_hub_commit": fresh.control_hub_commit,
        "capability_contract": fresh.capability_contract,
        "packet_sha256": expected_packet_hash,
        "packet_response_sha256": packet_response_hash,
        "fresh_response_sha256": fresh.response_sha256,
        "source_sha256": expected_source_hash,
        "worker_pid": int(packet["worker_pid"]),
        "verifier_pid": int(verifier_pid),
        "verified_unix": now,
        "verified_utc": datetime.fromtimestamp(now, UTC).isoformat(),
        "production_enforced": False,
        "cross_host_enabled": False,
    }


class AdmissionGuard:
    """Durably binds one explicit authorization digest to one source task/recipe."""

    def __init__(
        self, ledger_path: str | Path, *, clock: Callable[[], float] = time.time
    ) -> None:
        self.ledger_path = Path(ledger_path)
        self.ledger_path.parent.mkdir(parents=True, exist_ok=True)
        self.clock = clock
        with sqlite3.connect(self.ledger_path) as db:
            db.execute(
                """CREATE TABLE IF NOT EXISTS authorization_admissions (
                    authorization_sha256 TEXT PRIMARY KEY,
                    source_task_id TEXT NOT NULL,
                    recipe_name TEXT NOT NULL,
                    mission_id TEXT NOT NULL,
                    admitted_at REAL NOT NULL
                )"""
            )

    def admit_recipe(
        self,
        engine: MissionEngine,
        *,
        source_task_id: str,
        source_task_status: str,
        authorization_key: str,
        recipe_name: str,
    ) -> str:
        if recipe_name not in _RECIPES:
            raise AdmissionDenied("authorization references an unknown recipe")
        if not source_task_id.strip():
            raise AdmissionDenied("source task id is required")
        if not authorization_key.strip():
            if source_task_status.lower() in {"triage", "blocked"}:
                raise AdmissionDenied(
                    "held history requires a new explicit authorization key"
                )
            raise AdmissionDenied("explicit authorization key is required")
        digest = hashlib.sha256(authorization_key.encode("utf-8")).hexdigest()
        binding = (source_task_id, recipe_name)
        with sqlite3.connect(self.ledger_path, timeout=30) as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(
                """SELECT source_task_id,recipe_name,mission_id
                   FROM authorization_admissions WHERE authorization_sha256=?""",
                (digest,),
            ).fetchone()
            if row:
                if (str(row[0]), str(row[1])) != binding:
                    raise AdmissionDenied(
                        "authorization key is already bound to another task or recipe"
                    )
                return str(row[2])
            mission_id = engine.admit(
                f"typed-control-authorization:{digest}",
                scope=["execute"],
                max_attempts=1,
                max_turns=1,
            )
            db.execute(
                """INSERT INTO authorization_admissions(
                    authorization_sha256,source_task_id,recipe_name,mission_id,admitted_at
                ) VALUES(?,?,?,?,?)""",
                (digest, source_task_id, recipe_name, mission_id, float(self.clock())),
            )
            return mission_id
