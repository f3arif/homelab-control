#!/usr/bin/env python3
"""Read-only Facebook Marketplace inventory collector for AFZ Marketplace Manager.

Safety properties:
- connects only to an already-running user-authorized Chromium session over CDP;
- never submits, edits, renews, deletes, relists, or reprices a listing;
- stops on login, 2FA, CAPTCHA, checkpoint, or identity-verification screens;
- does not read Marketplace message contents;
- locks every collected listing until message state and age are separately verified.

The output is intentionally conservative: listing URL/title/visible price only. Unknown
posted date and buyer-message state are marked in notes and `locked=1`, so importing
this CSV cannot cause the manager to queue listing changes.
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import time
from pathlib import Path
from urllib.parse import urljoin, urlsplit, urlunsplit

from playwright.sync_api import Page, sync_playwright

SELLING_URL = "https://www.facebook.com/marketplace/you/selling"
BLOCK_TEXT = (
    "captcha",
    "security check",
    "confirm your identity",
    "checkpoint",
    "two-factor authentication",
    "two factor authentication",
    "enter login code",
    "log in to facebook",
)
ITEM_RE = re.compile(r"/marketplace/item/(\d+)")
PRICE_RE = re.compile(r"(?:CA\$|C\$|\$)\s*([0-9][0-9,]*(?:\.\d{1,2})?)", re.I)


def protection_block(page: Page) -> str | None:
    url = (page.url or "").lower()
    if "login" in url or "checkpoint" in url:
        return f"protected Facebook page: {page.url}"
    try:
        text = page.locator("body").inner_text(timeout=5000).lower()
    except Exception:
        text = ""
    for needle in BLOCK_TEXT:
        if needle in text:
            return f"account-protection screen detected: {needle}"
    return None


def canonical_item_url(href: str) -> tuple[str, str] | None:
    if not href:
        return None
    absolute = urljoin("https://www.facebook.com", href)
    match = ITEM_RE.search(absolute)
    if not match:
        return None
    parts = urlsplit(absolute)
    clean = urlunsplit((parts.scheme or "https", parts.netloc or "www.facebook.com", parts.path, "", ""))
    return clean.rstrip("/"), match.group(1)


def parse_card_text(text: str) -> tuple[str, str]:
    lines = [re.sub(r"\s+", " ", line).strip() for line in (text or "").splitlines()]
    lines = [line for line in lines if line]
    price = ""
    for line in lines:
        m = PRICE_RE.search(line)
        if m:
            price = m.group(1).replace(",", "")
            break
    title = ""
    for line in lines:
        if PRICE_RE.search(line):
            continue
        low = line.lower()
        if low in {"sold", "pending", "available", "boost listing", "edit listing"}:
            continue
        if len(line) >= 2:
            title = line[:240]
            break
    return title, price


def collect(page: Page, max_items: int, scrolls: int) -> list[dict[str, str]]:
    page.goto(SELLING_URL, wait_until="domcontentloaded", timeout=30000)
    page.wait_for_timeout(1500)
    blocker = protection_block(page)
    if blocker:
        raise RuntimeError(blocker)

    seen: dict[str, dict[str, str]] = {}
    stable_rounds = 0
    for _ in range(scrolls + 1):
        blocker = protection_block(page)
        if blocker:
            raise RuntimeError(blocker)

        before = len(seen)
        anchors = page.locator('a[href*="/marketplace/item/"]')
        count = min(anchors.count(), max_items * 4)
        for i in range(count):
            try:
                anchor = anchors.nth(i)
                href = anchor.get_attribute("href") or ""
                parsed = canonical_item_url(href)
                if not parsed:
                    continue
                url, external_id = parsed
                text = anchor.inner_text(timeout=1000)
                title, price = parse_card_text(text)
                current = seen.get(url, {})
                if title or not current.get("title"):
                    current["title"] = title or current.get("title") or f"Marketplace item {external_id}"
                if price:
                    current["price"] = price
                current["url"] = url
                current["external_id"] = external_id
                seen[url] = current
                if len(seen) >= max_items:
                    break
            except Exception:
                continue

        if len(seen) >= max_items:
            break
        if len(seen) == before:
            stable_rounds += 1
        else:
            stable_rounds = 0
        if stable_rounds >= 3:
            break
        page.evaluate("window.scrollBy(0, Math.max(window.innerHeight * 2, 1200))")
        page.wait_for_timeout(1000)

    rows: list[dict[str, str]] = []
    for item in list(seen.values())[:max_items]:
        rows.append({
            "external_id": item["external_id"],
            "url": item["url"],
            "title": item.get("title") or f"Marketplace item {item['external_id']}",
            "description": "",
            "price": item.get("price") or "0",
            "posted_at": "",
            "refreshed_at": "",
            "status": "active",
            "messages_count": "0",
            "locked": "1",
            "notes": "read_only_browser_collection;message_state_unverified;posted_at_unverified",
        })
    return rows


def write_csv(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = [
        "external_id", "url", "title", "description", "price", "posted_at",
        "refreshed_at", "status", "messages_count", "locked", "notes",
    ]
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description="Read-only Facebook Marketplace inventory collector")
    parser.add_argument("--cdp", default="http://127.0.0.1:9222")
    parser.add_argument("--out", type=Path, default=Path(r"C:\ProgramData\AFZ\MarketplaceManager\imports\marketplace-browser.csv"))
    parser.add_argument("--max-items", type=int, default=100)
    parser.add_argument("--scrolls", type=int, default=20)
    args = parser.parse_args()

    max_items = max(1, min(args.max_items, 500))
    scrolls = max(0, min(args.scrolls, 100))
    with sync_playwright() as p:
        browser = p.chromium.connect_over_cdp(args.cdp)
        if not browser.contexts:
            raise RuntimeError("No Chromium browser context found on the CDP endpoint")
        context = browser.contexts[0]
        page = context.pages[0] if context.pages else context.new_page()
        blocker = protection_block(page)
        if blocker:
            raise RuntimeError(blocker)
        rows = collect(page, max_items, scrolls)

    write_csv(args.out, rows)
    result = {
        "ok": True,
        "mode": "read-only",
        "listings_collected": len(rows),
        "output": str(args.out),
        "all_locked": True,
        "facebook_writes": 0,
    }
    sys.stdout.write(json.dumps(result, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        sys.stderr.write(json.dumps({"ok": False, "error": str(exc), "facebook_writes": 0}) + "\n")
        raise SystemExit(1)
