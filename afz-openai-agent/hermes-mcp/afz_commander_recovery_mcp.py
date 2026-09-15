#!/usr/bin/env python3
"""One-purpose Hermes recovery bridge for Commander alternate-account pairing.

This MCP server exposes exactly one state-changing AFZ operation:
launch the already-active guarded Commander pairing contract on windows-main.
It exposes no arbitrary shell, URL, filesystem, credential, or device-code access.
"""
from __future__ import annotations

import json
import logging
import sys
from ipaddress import ip_address, ip_network
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

BASE_URL = "http://100.70.25.8:8797"
ALLOWED_NET = ip_network("100.64.0.0/10")
ALLOWED_HOST = "100.70.25.8"
ALLOWED_PORT = 8797
USER_AGENT = "AFZ-Hermes-Commander-Recovery/1.0"

logger = logging.getLogger("afz_commander_recovery_mcp")


def _validated_base_url() -> str:
    parsed = urlparse(BASE_URL)
    if parsed.scheme != "http" or parsed.hostname != ALLOWED_HOST or parsed.port != ALLOWED_PORT:
        raise ValueError("Commander recovery endpoint drift")
    if ip_address(parsed.hostname) not in ALLOWED_NET:
        raise ValueError("Commander recovery endpoint outside Tailscale CGNAT")
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment or parsed.username or parsed.password:
        raise ValueError("Commander recovery endpoint contains unsupported URL components")
    return BASE_URL


def _http_json(method: str, path: str, payload: dict[str, Any] | None = None, timeout: int = 20) -> dict[str, Any]:
    if path not in {"/health", "/api/commander-alternate-account-pair"}:
        raise ValueError(f"Commander recovery path is not allowlisted: {path}")
    body = None if payload is None else json.dumps(payload, separators=(",", ":")).encode("utf-8")
    req = Request(
        _validated_base_url() + path,
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


def afz_commander_pair_active_request() -> str:
    """Launch only the active guarded Commander pairing contract on windows-main."""
    health = _http_json("GET", "/health", timeout=12)
    commit = ((health.get("data") or {}).get("commit") if health.get("ok") else None)
    if not isinstance(commit, str) or len(commit) != 40 or any(c not in "0123456789abcdefABCDEF" for c in commit):
        return json.dumps(
            {"ok": False, "error": "afz_control_commit_unavailable", "health": health},
            separators=(",", ":"),
            default=str,
        )
    payload = {
        "action": "launch-active-request",
        "repository": "f3arif/homelab-control",
        "ref": "refs/heads/main",
        "sha": commit.lower(),
    }
    return json.dumps(
        _http_json("POST", "/api/commander-alternate-account-pair", payload, timeout=45),
        separators=(",", ":"),
        default=str,
    )


def _build_server():
    try:
        from mcp.server import MCPServer
    except ImportError as exc:
        raise RuntimeError(f"Hermes MCP runtime unavailable: {exc}") from exc
    server = MCPServer(
        "afz-commander-recovery",
        instructions=(
            "One-purpose AFZ recovery bridge. The only tool launches the already-active "
            "Commander alternate-account pairing contract. It never returns device codes "
            "or credential material and exposes no arbitrary shell or URL capability."
        ),
    )
    server.add_tool(
        afz_commander_pair_active_request,
        name="afz_commander_pair_active_request",
        description=(
            "Launch the currently active guarded Commander alternate-account pairing request "
            "on windows-main. No parameters, arbitrary commands, device codes, or credentials are exposed."
        ),
    )
    return server


def self_test() -> dict[str, Any]:
    assert _validated_base_url() == BASE_URL
    return {
        "ok": True,
        "classification": "AFZ_HERMES_COMMANDER_RECOVERY_SELFTEST_PASS",
        "baseUrl": BASE_URL,
        "tools": ["afz_commander_pair_active_request"],
        "stateChanging": True,
        "arbitraryShell": False,
        "arbitraryUrl": False,
        "credentialAccess": False,
        "deviceCodeReturned": False,
    }


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    logging.basicConfig(level=logging.INFO if "--verbose" in argv else logging.WARNING, stream=sys.stderr)
    if "--self-test" in argv:
        print(json.dumps(self_test(), separators=(",", ":")))
        return 0
    try:
        _build_server().run()
        return 0
    except KeyboardInterrupt:
        return 0
    except Exception as exc:
        logger.exception("AFZ Commander recovery MCP failed")
        print(f"AFZ Commander recovery MCP failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
