#!/usr/bin/env python3
"""Minimal typed AFZ execution bridge for Hermes Agent.

This MCP server intentionally exposes no shell, terminal, filesystem write,
or arbitrary URL tool. It talks only to the existing windows-main AFZ typed
control API over Tailscale and starts with read-only operations.
"""
from __future__ import annotations

import json
import logging
import os
import re
import sys
from ipaddress import ip_address, ip_network
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

DEFAULT_BASE_URL = "http://100.70.25.8:8797"
ALLOWED_NET = ip_network("100.64.0.0/10")
ALLOWED_PORT = 8797
ALLOWED_HOST = "100.70.25.8"
USER_AGENT = "AFZ-Hermes-MCP/1.0"

logger = logging.getLogger("afz_hermes_mcp")


def _validated_base_url() -> str:
    raw = os.environ.get("AFZ_CONTROL_BASE_URL", DEFAULT_BASE_URL).strip().rstrip("/")
    parsed = urlparse(raw)
    if parsed.scheme != "http" or parsed.hostname != ALLOWED_HOST or parsed.port != ALLOWED_PORT:
        raise ValueError("AFZ control URL must remain the fixed windows-main Tailscale endpoint")
    addr = ip_address(parsed.hostname)
    if addr not in ALLOWED_NET:
        raise ValueError("AFZ control URL is outside the Tailscale CGNAT range")
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment or parsed.username or parsed.password:
        raise ValueError("AFZ control URL must not contain path, credentials, query, or fragment")
    return raw


def _http_json(method: str, path: str, payload: dict[str, Any] | None = None, timeout: int = 20) -> dict[str, Any]:
    if path not in {
        "/health",
        "/api/windows-wsl-memory-audit",
        "/api/h3-qwen27b-benchmark",
        "/api/queue-orphan-remediation",
        "/api/jellyfin-visibility-repair",
        "/api/movierecommender-catalog",
        "/api/stremio-organize",
        "/api/hermes-radiohilal-cron",
    }:
        raise ValueError(f"AFZ MCP path is not allowlisted: {path}")
    base = _validated_base_url()
    body = None if payload is None else json.dumps(payload, separators=(",", ":")).encode("utf-8")
    req = Request(
        base + path,
        data=body,
        method=method,
        headers={"Accept": "application/json", "Content-Type": "application/json", "User-Agent": USER_AGENT},
    )
    try:
        with urlopen(req, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
            data = json.loads(raw) if raw.strip() else {}
            return {"ok": 200 <= response.status < 300, "status": response.status, "data": data}
    except HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            detail: Any = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError:
            detail = raw[:1000]
        return {"ok": False, "status": exc.code, "error": "afz_control_http_error", "detail": detail}
    except (URLError, TimeoutError, OSError) as exc:
        return {"ok": False, "status": 0, "error": "afz_control_unreachable", "detail": str(exc)}


def afz_control_health() -> str:
    """Read the windows-main AFZ Control health/status document."""
    return json.dumps(_http_json("GET", "/health", timeout=12), separators=(",", ":"), default=str)


def afz_windows_wsl_memory_audit() -> str:
    """Run the existing typed READ-ONLY Windows/WSL memory audit on windows-main."""
    health = _http_json("GET", "/health", timeout=12)
    commit = ((health.get("data") or {}).get("commit") if health.get("ok") else None)
    if not isinstance(commit, str) or len(commit) != 40 or any(c not in "0123456789abcdefABCDEF" for c in commit):
        return json.dumps({"ok": False, "error": "afz_control_commit_unavailable", "health": health}, separators=(",", ":"), default=str)
    payload = {
        "action": "audit",
        "repository": "f3arif/homelab-control",
        "ref": "refs/heads/main",
        "sha": commit.lower(),
    }
    return json.dumps(_http_json("POST", "/api/windows-wsl-memory-audit", payload, timeout=90), separators=(",", ":"), default=str)


_TASK_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,180}$")


def _typed_source_call(path: str, action: str, timeout: int = 90, **extra: Any) -> str:
    health = _http_json("GET", "/health", timeout=12)
    commit = ((health.get("data") or {}).get("commit") if health.get("ok") else None)
    if not isinstance(commit, str) or len(commit) != 40 or any(c not in "0123456789abcdefABCDEF" for c in commit):
        return json.dumps(
            {"ok": False, "error": "afz_control_commit_unavailable", "health": health},
            separators=(",", ":"),
            default=str,
        )
    payload: dict[str, Any] = {
        "action": action,
        "repository": "f3arif/homelab-control",
        "ref": "refs/heads/main",
        "sha": commit.lower(),
    }
    payload.update(extra)
    return json.dumps(_http_json("POST", path, payload, timeout=timeout), separators=(",", ":"), default=str)


def afz_h3_benchmark_status() -> str:
    """Read the existing H3 Qwen benchmark status on windows-main."""
    return json.dumps(
        _http_json("POST", "/api/h3-qwen27b-benchmark", {"action": "status"}, timeout=30),
        separators=(",", ":"),
        default=str,
    )


def afz_stremio_organize_audit() -> str:
    """Audit the existing typed Stremio organizer without changing media state."""
    return _typed_source_call("/api/stremio-organize", "audit", timeout=90)


def afz_stremio_organize_apply() -> str:
    """Apply the existing bounded Stremio organizer on windows-main."""
    return _typed_source_call("/api/stremio-organize", "apply", timeout=180)


def afz_queue_orphan_audit(task_id: str) -> str:
    """Audit one exact AFZ queue task for orphan/remediation state."""
    task_id = str(task_id or "").strip()
    if not _TASK_ID_RE.fullmatch(task_id):
        return json.dumps({"ok": False, "error": "invalid_task_id"}, separators=(",", ":"))
    return _typed_source_call("/api/queue-orphan-remediation", "audit", timeout=90, taskId=task_id)


def afz_queue_orphan_apply(task_id: str) -> str:
    """Apply the existing bounded orphan remediation to one exact AFZ queue task."""
    task_id = str(task_id or "").strip()
    if not _TASK_ID_RE.fullmatch(task_id):
        return json.dumps({"ok": False, "error": "invalid_task_id"}, separators=(",", ":"))
    return _typed_source_call("/api/queue-orphan-remediation", "apply", timeout=120, taskId=task_id)


def afz_jellyfin_visibility_audit() -> str:
    """Run the existing read-only Jellyfin visibility audit on windows-main."""
    return _typed_source_call("/api/jellyfin-visibility-repair", "audit", timeout=120)


def afz_movierecommender_catalog_audit() -> str:
    """Run the existing read-only MovieRecommender catalog audit on windows-main."""
    return _typed_source_call("/api/movierecommender-catalog", "audit", timeout=120)


def afz_radiohilal_cron_audit() -> str:
    """Audit the fixed Radio Hilal Hermes cron job without modifying it."""
    return _typed_source_call("/api/hermes-radiohilal-cron", "audit", timeout=120)


def _build_server():
    try:
        from mcp.server import MCPServer
    except ImportError as exc:
        raise RuntimeError(f"Hermes MCP runtime unavailable: {exc}") from exc

    server = MCPServer(
        "afz-fabric",
        instructions=(
            "Typed AFZ homelab control bridge. This server exposes only explicitly "
            "allowlisted AFZ operations; it has no arbitrary shell or URL capability."
        ),
    )
    server.add_tool(
        afz_control_health,
        name="afz_control_health",
        description="Read windows-main AFZ Control health and current source state.",
    )
    server.add_tool(
        afz_windows_wsl_memory_audit,
        name="afz_windows_wsl_memory_audit",
        description="Run the existing typed read-only Windows/WSL memory audit on windows-main.",
    )
    server.add_tool(afz_h3_benchmark_status, name="afz_h3_benchmark_status", description="Read the current H3 benchmark status from windows-main.")
    server.add_tool(afz_stremio_organize_audit, name="afz_stremio_organize_audit", description="Audit Stremio organizer state without applying changes.")
    server.add_tool(afz_stremio_organize_apply, name="afz_stremio_organize_apply", description="Apply the existing bounded Stremio organizer.")
    server.add_tool(afz_queue_orphan_audit, name="afz_queue_orphan_audit", description="Audit one exact AFZ queue task by task_id.")
    server.add_tool(afz_queue_orphan_apply, name="afz_queue_orphan_apply", description="Apply bounded orphan remediation to one exact AFZ queue task by task_id.")
    server.add_tool(afz_jellyfin_visibility_audit, name="afz_jellyfin_visibility_audit", description="Run the read-only Jellyfin visibility audit.")
    server.add_tool(afz_movierecommender_catalog_audit, name="afz_movierecommender_catalog_audit", description="Run the read-only MovieRecommender catalog audit.")
    server.add_tool(afz_radiohilal_cron_audit, name="afz_radiohilal_cron_audit", description="Audit the fixed Radio Hilal Hermes cron job.")
    return server


def self_test() -> dict[str, Any]:
    base = _validated_base_url()
    assert base == DEFAULT_BASE_URL
    expected_paths = {
        "/health",
        "/api/windows-wsl-memory-audit",
        "/api/h3-qwen27b-benchmark",
        "/api/queue-orphan-remediation",
        "/api/jellyfin-visibility-repair",
        "/api/movierecommender-catalog",
        "/api/stremio-organize",
        "/api/hermes-radiohilal-cron",
    }
    assert "/api/stremio-organize" in expected_paths
    return {
        "ok": True,
        "classification": "AFZ_HERMES_MCP_SELFTEST_PASS",
        "baseUrl": base,
        "tools": [
            "afz_control_health",
            "afz_windows_wsl_memory_audit",
            "afz_h3_benchmark_status",
            "afz_stremio_organize_audit",
            "afz_stremio_organize_apply",
            "afz_queue_orphan_audit",
            "afz_queue_orphan_apply",
            "afz_jellyfin_visibility_audit",
            "afz_movierecommender_catalog_audit",
            "afz_radiohilal_cron_audit",
        ],
        "arbitraryShell": False,
        "arbitraryUrl": False,
    }


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    logging.basicConfig(level=logging.INFO if "--verbose" in argv else logging.WARNING, stream=sys.stderr)
    if "--self-test" in argv:
        print(json.dumps(self_test(), separators=(",", ":")))
        return 0
    try:
        _build_server().run()  # MCPServer defaults to stdio transport.
        return 0
    except KeyboardInterrupt:
        return 0
    except Exception as exc:
        logger.exception("AFZ Hermes MCP server failed")
        print(f"AFZ Hermes MCP server failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
