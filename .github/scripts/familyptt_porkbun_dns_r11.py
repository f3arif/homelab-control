#!/usr/bin/env python3
import json
import os
import sys
import urllib.error
import urllib.request

BASE = "https://api.porkbun.com/api/json/v3"
DOMAIN = "afzeng.ca"
TARGET = "99.235.82.12"
SUBDOMAINS = ("ptt-api", "ptt-livekit")
RESULT_PATH = "familyptt-dns-r11-result.json"

API_KEY = os.environ.get("PORKBUN_API_KEY", "")
SECRET = os.environ.get("PORKBUN_SECRET_API_KEY", "")

result = {
    "status": "ERROR",
    "classification": "PORKBUN_DNS_PROVISION_FAILED",
    "domain": DOMAIN,
    "targetIpv4": TARGET,
    "records": [],
    "secretValuesLogged": False,
    "scope": list(SUBDOMAINS),
}


def save_result():
    with open(RESULT_PATH, "w", encoding="utf-8") as handle:
        json.dump(result, handle, separators=(",", ":"))


def api_call(method, path, payload=None, idempotency_key=None):
    headers = {
        "Accept": "application/json",
        "X-API-Key": API_KEY,
        "X-Secret-API-Key": SECRET,
    }
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    if idempotency_key:
        headers["Idempotency-Key"] = idempotency_key

    request = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            body = json.loads(raw)
            code = body.get("code") or f"HTTP_{exc.code}"
        except Exception:
            code = f"HTTP_{exc.code}"
        raise RuntimeError(f"Porkbun API error: {code}") from None


def require_success(response, operation):
    if response.get("status") != "SUCCESS":
        raise RuntimeError(f"{operation} failed: {response.get('code', 'UNKNOWN')}")
    if response.get("wouldSucceed") is False:
        raise RuntimeError(f"{operation} dry-run rejected")


def provision_record(subdomain):
    lookup_path = f"/dns/retrieveByNameType/{DOMAIN}/A/{subdomain}"
    current = api_call("GET", lookup_path)
    require_success(current, f"retrieve {subdomain}")
    records = current.get("records") or []

    if len(records) > 1:
        raise RuntimeError(f"Duplicate A records require review for {subdomain}")

    action = "unchanged"
    if records and records[0].get("content") == TARGET:
        pass
    elif records:
        record_id = records[0].get("id")
        dry_payload = {
            "name": subdomain,
            "type": "A",
            "content": TARGET,
            "ttl": 600,
            "dryRun": True,
        }
        preview = api_call("POST", f"/dns/edit/{DOMAIN}/{record_id}", dry_payload)
        require_success(preview, f"dry-run edit {subdomain}")
        live_payload = dict(dry_payload)
        live_payload.pop("dryRun", None)
        changed = api_call(
            "POST",
            f"/dns/edit/{DOMAIN}/{record_id}",
            live_payload,
            f"familyptt-r11-edit-{subdomain}-{TARGET}",
        )
        require_success(changed, f"edit {subdomain}")
        action = "edited"
    else:
        dry_payload = {
            "name": subdomain,
            "type": "A",
            "content": TARGET,
            "ttl": 600,
            "dryRun": True,
        }
        preview = api_call("POST", f"/dns/create/{DOMAIN}", dry_payload)
        require_success(preview, f"dry-run create {subdomain}")
        live_payload = dict(dry_payload)
        live_payload.pop("dryRun", None)
        changed = api_call(
            "POST",
            f"/dns/create/{DOMAIN}",
            live_payload,
            f"familyptt-r11-create-{subdomain}-{TARGET}",
        )
        require_success(changed, f"create {subdomain}")
        action = "created"

    verified = api_call("GET", lookup_path)
    require_success(verified, f"verify {subdomain}")
    verified_records = verified.get("records") or []
    if len(verified_records) != 1 or verified_records[0].get("content") != TARGET:
        raise RuntimeError(f"Authoritative verification failed for {subdomain}")

    result["records"].append(
        {
            "host": f"{subdomain}.{DOMAIN}",
            "type": "A",
            "content": TARGET,
            "action": action,
            "verified": True,
        }
    )


def main():
    if not API_KEY or not SECRET:
        result["classification"] = "PORKBUN_CREDENTIALS_REQUIRED"
        result["error"] = "Required Porkbun GitHub secrets are not configured"
        save_result()
        return 20

    try:
        for subdomain in SUBDOMAINS:
            provision_record(subdomain)
        result["status"] = "SUCCESS"
        result["classification"] = "PORKBUN_DNS_PROVISIONED_VERIFIED"
        save_result()
        return 0
    except Exception as exc:
        result["error"] = str(exc)[:300]
        save_result()
        return 1


if __name__ == "__main__":
    sys.exit(main())
