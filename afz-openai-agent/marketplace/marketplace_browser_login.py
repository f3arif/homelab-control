#!/usr/bin/env python3
"""Authentication-only helper for the AFZ Marketplace browser profile.

Credentials are accepted only over stdin from the local PowerShell SSH wrapper.
They are never accepted as command-line arguments, written to disk, or emitted in
stdout/stderr. This helper may interact only with Facebook authentication fields.
It must stop on 2FA, CAPTCHA, checkpoint, or identity-verification flows.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Any

from playwright.sync_api import Page, TimeoutError as PlaywrightTimeoutError, sync_playwright

LOGIN_URL = "https://www.facebook.com/login"
SELLING_URL = "https://www.facebook.com/marketplace/you/selling"
PROTECTION_TEXT = (
    "captcha",
    "security check",
    "confirm your identity",
    "checkpoint",
    "two-factor authentication",
    "two factor authentication",
    "enter login code",
    "authentication code",
    "approve from another device",
)


def body_text(page: Page) -> str:
    try:
        return page.locator("body").inner_text(timeout=5000).lower()
    except Exception:
        return ""


def protection_state(page: Page) -> str | None:
    url = (page.url or "").lower()
    if "checkpoint" in url:
        return "checkpoint"
    text = body_text(page)
    for needle in PROTECTION_TEXT:
        if needle in text:
            return needle
    return None


def first_visible(page: Page, selectors: tuple[str, ...]):
    for selector in selectors:
        locator = page.locator(selector).first
        try:
            if locator.count() and locator.is_visible(timeout=1000):
                return locator
        except Exception:
            continue
    return None


def authenticate(page: Page, username: str, password: str) -> dict[str, Any]:
    page.goto(LOGIN_URL, wait_until="domcontentloaded", timeout=30000)

    email = first_visible(page, ('input[name="email"]', '#email', 'input[type="text"]'))
    passwd = first_visible(page, ('input[name="pass"]', '#pass', 'input[type="password"]'))
    if email is None or passwd is None:
        state = protection_state(page)
        if state:
            return {"ok": False, "authenticated": False, "status": "protected", "reason": state}
        raise RuntimeError("Facebook login fields were not found")

    email.fill(username)
    passwd.fill(password)

    button = first_visible(page, ('button[name="login"]', 'button[type="submit"]'))
    if button is None:
        raise RuntimeError("Facebook login submit button was not found")
    button.click()

    try:
        page.wait_for_load_state("domcontentloaded", timeout=15000)
    except PlaywrightTimeoutError:
        pass
    page.wait_for_timeout(2500)

    state = protection_state(page)
    if state:
        return {
            "ok": False,
            "authenticated": False,
            "status": "needs_interactive_verification",
            "reason": state,
            "facebook_writes": 0,
        }

    url = (page.url or "").lower()
    if "login" in url:
        # Keep this intentionally generic so credential validity is not logged in detail.
        return {
            "ok": False,
            "authenticated": False,
            "status": "login_not_completed",
            "reason": "Facebook remained on the login flow",
            "facebook_writes": 0,
        }

    page.goto(SELLING_URL, wait_until="domcontentloaded", timeout=30000)
    page.wait_for_timeout(1500)
    state = protection_state(page)
    if state:
        return {
            "ok": False,
            "authenticated": False,
            "status": "needs_interactive_verification",
            "reason": state,
            "facebook_writes": 0,
        }
    if "login" in (page.url or "").lower():
        return {
            "ok": False,
            "authenticated": False,
            "status": "login_not_completed",
            "reason": "Marketplace redirected to Facebook login",
            "facebook_writes": 0,
        }

    return {
        "ok": True,
        "authenticated": True,
        "status": "session_ready",
        "profile_scope": "dedicated-marketplace-browser",
        "facebook_writes": 0,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Authenticate dedicated AFZ Marketplace browser profile")
    parser.add_argument("--cdp", default="http://127.0.0.1:9222")
    args = parser.parse_args()

    raw = sys.stdin.readline()
    if not raw:
        raise RuntimeError("Credential payload was not provided on stdin")
    try:
        payload = json.loads(raw)
    finally:
        raw = ""
    username = str(payload.get("username") or "").strip()
    password = str(payload.get("password") or "")
    payload.clear()
    if not username or not password:
        raise RuntimeError("Username/email and password are required")

    try:
        with sync_playwright() as p:
            browser = p.chromium.connect_over_cdp(args.cdp)
            if not browser.contexts:
                raise RuntimeError("No Chromium context found on local Marketplace CDP endpoint")
            context = browser.contexts[0]
            page = context.pages[0] if context.pages else context.new_page()
            result = authenticate(page, username, password)
    finally:
        username = ""
        password = ""

    sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
    return 0 if result.get("ok") else 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        # Never include credential payloads or browser HTML in errors.
        sys.stderr.write(json.dumps({"ok": False, "authenticated": False, "status": "error", "error": str(exc), "facebook_writes": 0}) + "\n")
        raise SystemExit(1)
