"""AFZ device-aware Stremio stream list ordering sidecar.

Only intercepts JSON stream list retrievals. Every returned media URL is still
handled by the original AFZ production backend. No playback, account, media
storage or Tailscale production config is modified by this process.
"""
from __future__ import annotations
import ipaddress
import json
import logging
import os
import re
import subprocess
import threading
import time
from pathlib import Path
from urllib.parse import urlsplit

import requests
from fastapi import FastAPI, Request
from fastapi.responses import Response

UPSTREAM = "http://127.0.0.1:18774"
POLICY = Path(__file__).with_name("device-policy.json")
STALE_DEVICE_REFRESH_SECONDS = 180
ADDON_PREFIX = "AFZ "
MB = 1024 ** 2
GB = 1024 ** 3
PHONE_WORDS = ("oneplus", "pixel", "iphone", "galaxy", "samsung", "phone", "ipad", "tablet")
TV_WORDS = ("onn", "fire-tv", "firestick", "chromecast", "androidtv", "android-tv", "apple-tv", "shield", "google-tv", "roku", "television")
STREAM_RX = re.compile(r"^/stream/movie/(tt\d+|afzlib:[^/]{1,100})\.json$", re.I)
SIZE_RX = re.compile(r"(?<![a-z0-9])(\d+(?:\.\d+)?)\s*(GiB|GB|MiB|MB|TiB|TB)\b", re.I)
TNET = ipaddress.ip_network("100.64.0.0/10")
LAN = ipaddress.ip_network("192.168.50.0/24")

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
_lock = threading.Lock()
_latest = {"when": 0.0, "classes": {}}
_log = logging.getLogger("device_source_order")

def device_name_category(name: str) -> str:
    """TV tokens take priority over smartphone-looking model names."""
    n = str(name or "").strip().lower().replace("_", "-")
    if any(word in n for word in TV_WORDS):
        return "tv"
    if any(word in n for word in PHONE_WORDS):
        return "phone"
    return "unknown"

def _valid_ip(s: str) -> str | None:
    try:
        value = str(ipaddress.ip_address(s.strip()))
        return value if ipaddress.ip_address(value) in TNET or ipaddress.ip_address(value) in LAN else None
    except ValueError:
        return None

def _peer_classes() -> dict[str, str]:
    now = time.monotonic()
    with _lock:
        if now - _latest["when"] < STALE_DEVICE_REFRESH_SECONDS:
            return dict(_latest["classes"])
        # Single-process request serialization of a slow local command. If it
        # times out, keep last-known classes; an unknown client always passes
        # through without changes.
        found = dict(_latest["classes"])
        try:
            raw = subprocess.run(
                ["tailscale.exe", "status", "--json"],
                capture_output=True, text=True, timeout=3, check=True
            )
            body = json.loads(raw.stdout)
            fresh = {}
            for peer in (body.get("Peer") or {}).values():
                category = device_name_category(peer.get("HostName"))
                if category == "unknown":
                    category = device_name_category(peer.get("DNSName"))
                if category == "unknown":
                    continue
                for address in peer.get("TailscaleIPs", []):
                    ip = _valid_ip(str(address))
                    if ip:
                        fresh[ip] = category
            found.update(fresh)
        except (OSError, subprocess.SubprocessError, ValueError, TypeError, json.JSONDecodeError):
            pass
        _latest["classes"] = found
        _latest["when"] = time.monotonic()
        return dict(found)

def source_class(request: Request) -> str:
    client = request.client.host if request.client else ""
    # X-Forwarded-For is accepted only from a local Tailscale Serve proxy,
    # never from a direct remote connection.
    xff = request.headers.get("x-forwarded-for", "")
    if client in ("127.0.0.1", "::1") and xff:
        requested = _valid_ip(xff.split(",")[0])
        if requested:
            client = requested
    client = _valid_ip(client) or ""
    with _lock:
        try:
            overrides = json.loads(POLICY.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, ValueError):
            overrides = {}
    for category in ("phone", "tv"):
        if client and client in overrides.get(category, []):
            return category
    return _peer_classes().get(client, "unknown")

def size_bytes(row: dict) -> int:
    hints = row.get("behaviorHints")
    if isinstance(hints, dict):
        size = hints.get("videoSize")
        if isinstance(size, (float, int)) and size > 0:
            return int(size)
    # The server writes size as the first "3.3 GB" component of the title.
    title = str(row.get("title") or "")[:220]
    hit = SIZE_RX.search(title)
    if not hit:
        return 0
    n = float(hit.group(1))
    unit = hit.group(2).lower()
    multiplier = {
        "gib": GB, "gb": GB, "mb": MB, "mib": MB,
        "tb": 1024 * GB, "tib": 1024 * GB
    }
    return round(n * multiplier[unit])

def _is_action(row: dict) -> bool:
    name = str(row.get("name") or "").lower()
    url = str(row.get("url") or "")
    return (
        bool(row.get("externalUrl")) or not url or
        any(x in name for x in ("auto-save", "last auto source", "status", "remove", "delete", "download", "request")) or
        "request-confirmation.mp4" in url
    )

def _is_4k(row: dict) -> bool:
    name = str(row.get("name") or "").lower()
    title = str(row.get("title") or "").lower()
    return ("4k" in name or "2160p" in title or
            (name == "afz play best" and "1080p" not in title))

def _manual_small(row: dict) -> bool:
    if "/external-stream/" not in str(row.get("url") or ""):
        return False
    if "1080p" not in (str(row.get("title") or "") + str(row.get("name") or "")).lower():
        return False
    gib = size_bytes(row) / GB
    return 1.2 <= gib <= 9 and "cached" in str(row.get("title") or "").lower()

def _manual_rank(row: dict) -> tuple[int,int,float]:
    g = size_bytes(row) / GB
    src = (str(row.get("title") or "") + str(row.get("name") or "")).lower()
    # Exact range fit, Comet and reasonable file size. Never fabricate a URL.
    bucket = 0 if 2 <= g <= 5 else (1 if g <= 8 else 2)
    provider = 0 if "comet" in src else 1
    return bucket, provider, abs(g - 3.5)

def sort_phone(rows: list[dict]) -> list[dict]:
    if not rows:
        return rows
    original = [dict(x) for x in rows]
    if not any(str(x.get("name") or "").startswith(ADDON_PREFIX) for x in original):
        return original

    playable = [x for x in original if not _is_action(x)]
    control = [x for x in original if _is_action(x)]
    def byname(value: str):
        return next((x for x in playable if str(x.get("name") or "").lower() == value), None)

    saver = byname("afz auto data saver")
    mobile = byname("afz auto mobile")
    auto1080 = byname("afz auto 1080p")
    manual = [x for x in playable if "/external-stream/" in str(x.get("url") or "")]
    small = sorted((x for x in manual if _manual_small(x)), key=_manual_rank)

    recommended = None
    for candidate in (saver, mobile):
        if candidate:
            sz = size_bytes(candidate) / GB
            cached = "cached" in str(candidate.get("title") or "").lower()
            if 1.2 <= sz <= 8 and cached:
                recommended = candidate
                break
    if recommended is None and small:
        recommended = small[0]
    if recommended is None:
        recommended = saver or mobile or auto1080 or (small[0] if small else None)

    ordered = []
    used = set()
    def add(row: dict | None):
        if row is not None and id(row) not in used:
            ordered.append(row)
            used.add(id(row))
    if recommended:
        # Some Nuvio clients pin 'AFZ Play Best' above every other entry.
        # Reuse that well-known identity with a genuinely mobile-size URL
        # rather than adding a new recommendation while leaving 4K pinned.
        pinned=byname("afz play best")
        role = "Data Saver" if recommended is saver or recommended.get("name")=="AFZ Auto Data Saver" else "1080p"
        if pinned:
            row=dict(pinned)
            row["name"]="AFZ Play Best"
            row["title"]=f"Phone optimized ({role}) | "+str(recommended.get("title") or "")
            chosen_url=str(recommended.get("url") or "")
            parsed=urlsplit(chosen_url)
            # Preserve the original chosen stream while making this alias
            # distinct from the lower Auto Saver/Manual entry.
            if parsed.hostname=="desktop-h3r6cqn.tailc9bb62.ts.net" and parsed.path.startswith(("/auto-stream/","/external-stream/")):
                chosen_url+=("&" if "?" in chosen_url else "?")+"afz_phone_best=1"
            row["url"]=chosen_url
            hints=recommended.get("behaviorHints")
            if isinstance(hints,dict):
                row["behaviorHints"]=dict(hints)
            ordered.append(row)
            used.add(id(pinned))
        else:
            row=dict(recommended)
            row["name"]="AFZ Recommended for Phone"
            row["title"]=f"Phone optimized ({role}) | "+str(recommended.get("title") or "")
            ordered.append(row)
            used.add(id(recommended))
    # Put smaller cached manual 1080p files before larger Auto Mobile.
    for row in small:
        add(row)
    for row in (saver, mobile):
        add(row)
    add(auto1080)
    others_1080 = [
        x for x in playable if not _is_4k(x) and id(x) not in used
    ]
    for row in sorted(others_1080, key=lambda x: (size_bytes(x) <= 0, size_bytes(x))):
        add(row)
    for row in playable:
        add(row)
    for row in control:
        add(row)
    return ordered

@app.get("/health")
def health():
    return {"ok": True, "type": "AFZ device-aware stream order",
            "upstream": "local H3 catalog", "policy": "phone-best-v2"}

@app.api_route("/stream/movie/{video_id}.json", methods=["GET","HEAD"])
@app.api_route("/{video_id}.json", methods=["GET","HEAD"])
def stream_movie(video_id: str, request: Request):
    # Tailscale Serve --set-path strips /stream/movie before forwarding.
    # Both the full private path and path-stripped Serve endpoint must work.
    path = f"/stream/movie/{video_id}.json"
    if not STREAM_RX.fullmatch(path):
        return Response("Not Found", status_code=404)
    try:
        result = requests.get(UPSTREAM + path, timeout=(2, 14),
                              headers={"Accept": "application/json"})
    except requests.RequestException:
        return Response("AFZ catalog temporarily unavailable", status_code=503)
    raw = result.content
    if len(raw) > 3_000_000:
        return Response("Stream listing too large", status_code=502)
    klass = source_class(request)
    headers = {"Cache-Control":"no-store", "X-AFZ-Device-Class":klass,
               "X-AFZ-Sort-Policy":"phone-best-v2",
               "Access-Control-Allow-Origin":"*"}
    if result.status_code != 200 or klass != "phone" or request.method == "HEAD":
        return Response(content=b"" if request.method == "HEAD" else raw,
                        status_code=result.status_code,media_type="application/json",
                        headers=headers)
    try:
        data = json.loads(raw)
        streams = data.get("streams")
        if isinstance(streams, list) and all(isinstance(x, dict) for x in streams):
            data["streams"] = sort_phone(streams)
            raw = json.dumps(data,ensure_ascii=False,separators=(",",":")).encode("utf-8")
    except (ValueError, TypeError, KeyError):
        pass
    return Response(content=raw, status_code=result.status_code,
                    media_type="application/json",headers=headers)
