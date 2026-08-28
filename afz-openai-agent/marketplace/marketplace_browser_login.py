#!/usr/bin/env python3
"""Authentication-only helper for the AFZ Marketplace browser profile.

Credentials and one-time verification codes are accepted only over stdin from the
local PowerShell SSH wrapper. They are never accepted as command-line values,
written to disk, or emitted in stdout/stderr. This helper may interact only with
Facebook authentication/verification fields. CAPTCHA, identity review, checkpoints
without a normal one-time-code field, and approval-from-another-device flows remain
manual and are never bypassed.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
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
OTP_SELECTORS = (
    'input[name="approvals_code"]',
    'input[name="code"]',
    'input[autocomplete="one-time-code"]',
    'input[inputmode="numeric"]',
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


def otp_field(page: Page):
    field = first_visible(page, OTP_SELECTORS)
    if field is None:
        return None
    text = body_text(page)
    hints = (
        "code",
        "two-factor",
        "two factor",
        "authentication",
        "security code",
        "login code",
    )
    if not any(h in text for h in hints):
        return None
    return field


def submit_login(page: Page, passwd) -> str:
    """Submit only the Facebook authentication form, using bounded fallbacks."""
    button = first_visible(
        page,
        (
            'button[name="login"]',
            'button[type="submit"]',
            'input[name="login"]',
            'input[type="submit"]',
            'form[action*="login"] button',
            'form[action*="login"] input[type="submit"]',
        ),
    )
    if button is not None:
        button.click()
        return "selector"

    try:
        semantic = page.get_by_role("button", name=re.compile(r"^\s*log\s*in\s*$", re.I)).first
        if semantic.count() and semantic.is_visible(timeout=1000):
            semantic.click()
            return "semantic-button"
    except Exception:
        pass

    try:
        passwd.press("Enter")
        return "password-enter"
    except Exception as exc:
        raise RuntimeError("Facebook login form could not be submitted") from exc


def wait_after_submit(page: Page) -> None:
    try:
        page.wait_for_load_state("domcontentloaded", timeout=15000)
    except PlaywrightTimeoutError:
        pass
    page.wait_for_timeout(2500)


def verification_result(page: Page) -> dict[str, Any] | None:
    if otp_field(page) is not None:
        return {
            "ok": False,
            "authenticated": False,
            "status": "otp_required",
            "reason": "facebook_one_time_code",
            "facebook_writes": 0,
        }
    state = protection_state(page)
    if state:
        return {
            "ok": False,
            "authenticated": False,
            "status": "needs_interactive_verification",
            "reason": state,
            "facebook_writes": 0,
        }
    return None


def session_ready(page: Page) -> dict[str, Any]:
    return {
        "ok": True,
        "authenticated": True,
        "status": "session_ready",
        "profile_scope": "dedicated-marketplace-browser",
        "facebook_writes": 0,
    }


def authenticate(page: Page, username: str, password: str) -> dict[str, Any]:
    page.goto(LOGIN_URL, wait_until="domcontentloaded", timeout=30000)

    email = first_visible(page, ('input[name="email"]', '#email', 'input[type="text"]'))
    passwd = first_visible(page, ('input[name="pass"]', '#pass', 'input[type="password"]'))
    if email is None or passwd is None:
        challenge = verification_result(page)
        if challenge:
            return challenge
        page.goto(SELLING_URL, wait_until="domcontentloaded", timeout=30000)
        page.wait_for_timeout(1200)
        challenge = verification_result(page)
        if challenge:
            return challenge
        if "login" not in (page.url or "").lower():
            return session_ready(page)
        raise RuntimeError("Facebook login fields were not found")

    email.fill(username)
    passwd.fill(password)
    submit_login(page, passwd)
    wait_after_submit(page)

    challenge = verification_result(page)
    if challenge:
        return challenge

    url = (page.url or "").lower()
    if "login" in url:
        return {
            "ok": False,
            "authenticated": False,
            "status": "login_not_completed",
            "reason": "Facebook remained on the login flow",
            "facebook_writes": 0,
        }

    page.goto(SELLING_URL, wait_until="domcontentloaded", timeout=30000)
    page.wait_for_timeout(1500)
    challenge = verification_result(page)
    if challenge:
        return challenge
    if "login" in (page.url or "").lower():
        return {
            "ok": False,
            "authenticated": False,
            "status": "login_not_completed",
            "reason": "Marketplace redirected to Facebook login",
            "facebook_writes": 0,
        }
    return session_ready(page)


def submit_verification_code(page: Page, code: str) -> dict[str, Any]:
    field = otp_field(page)
    if field is None:
        return {
            "ok": False,
            "authenticated": False,
            "status": "needs_interactive_verification",
            "reason": protection_state(page) or "one_time_code_field_not_available",
            "facebook_writes": 0,
        }

    field.fill(code)
    submit = first_visible(
        page,
        (
            'button[type="submit"]',
            'input[type="submit"]',
            'button[name*="submit"]',
            'form button[type="submit"]',
        ),
    )
    if submit is not None:
        submit.click()
    else:
        semantic = None
        for label in ("Continue", "Submit", "Confirm", "Next"):
            try:
                candidate = page.get_by_role("button", name=re.compile(rf"^\s*{re.escape(label)}\s*$", re.I)).first
                if candidate.count() and candidate.is_visible(timeout=700):
                    semantic = candidate
                    break
            except Exception:
                continue
        if semantic is not None:
            semantic.click()
        else:
            field.press("Enter")

    wait_after_submit(page)
    challenge = verification_result(page)
    if challenge:
        return challenge

    page.goto(SELLING_URL, wait_until="domcontentloaded", timeout=30000)
    page.wait_for_timeout(1500)
    challenge = verification_result(page)
    if challenge:
        return challenge
    if "login" in (page.url or "").lower():
        return {
            "ok": False,
            "authenticated": False,
            "status": "verification_not_completed",
            "reason": "Facebook returned to the login flow after code submission",
            "facebook_writes": 0,
        }
    return session_ready(page)


def read_stdin_payload() -> dict[str, Any]:
    raw = sys.stdin.readline()
    if not raw:
        raise RuntimeError("Authentication payload was not provided on stdin")
    try:
        payload = json.loads(raw)
    finally:
        raw = ""
    if not isinstance(payload, dict):
        raise RuntimeError("Authentication payload must be a JSON object")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description="Authenticate dedicated AFZ Marketplace browser profile")
    parser.add_argument("--cdp", default="http://127.0.0.1:9222")
    parser.add_argument("--verify-code", action="store_true")
    args = parser.parse_args()

    payload = read_stdin_payload()
    username = ""
    password = ""
    code = ""
    try:
        if args.verify_code:
            code = str(payload.get("code") or "").strip()
            if not re.fullmatch(r"[0-9A-Za-z -]{4,16}", code):
                raise RuntimeError("Facebook verification code format was not accepted")
        else:
            username = str(payload.get("username") or "").strip()
            password = str(payload.get("password") or "")
            if not username or not password:
                raise RuntimeError("Username/email and password are required")
        payload.clear()

        with sync_playwright() as p:
            browser = p.chromium.connect_over_cdp(args.cdp)
            if not browser.contexts:
                raise RuntimeError("No Chromium context found on local Marketplace CDP endpoint")
            context = browser.contexts[0]
            page = context.pages[0] if context.pages else context.new_page()
            result = submit_verification_code(page, code) if args.verify_code else authenticate(page, username, password)
    finally:
        payload.clear()
        username = ""
        password = ""
        code = ""

    sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
    return 0 if result.get("ok") else 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        sys.stderr.write(json.dumps({"ok": False, "authenticated": False, "status": "error", "error": str(exc), "facebook_writes": 0}) + "\n")
        raise SystemExit(1)
