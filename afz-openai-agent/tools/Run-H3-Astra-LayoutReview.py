import argparse
import asyncio
import base64
import json
import os
import platform
import sys
import urllib.request
from pathlib import Path

EXPECTED_HOST = "DESKTOP-H3R6CQN"
EXPECTED_PROVIDER = "openai-codex"
EXPECTED_MODEL = "gpt-6-astra"
HERMES_ROOT = Path(r"C:\Users\Faiz\AppData\Local\hermes\hermes-agent")
DEFAULT_IMAGE_BASE = "http://100.70.25.8:3017"
DESKTOP = [
    "desktop-1440-slice-1.jpg",
    "desktop-1440-slice-2.jpg",
    "desktop-1440-slice-3.jpg",
]
MOBILE = [
    "mobile-390-slice-1.jpg",
    "mobile-390-slice-2.jpg",
    "mobile-390-slice-3.jpg",
]

def fail(message: str, code: int = 20):
    print(json.dumps({"ok": False, "error": message}, separators=(",", ":")))
    raise SystemExit(code)

def fetch_image(base: str, name: str) -> bytes:
    url = base.rstrip("/") + "/" + name
    req = urllib.request.Request(url, headers={"User-Agent": "AFZ-H3-Astra-LayoutReview/1"})
    with urllib.request.urlopen(req, timeout=30) as response:
        data = response.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024:
            raise RuntimeError(f"Image too large: {name}")
        ctype = str(response.headers.get("Content-Type") or "")
        if not ctype.lower().startswith("image/"):
            raise RuntimeError(f"Unexpected content type for {name}: {ctype}")
        return data

def image_block(data: bytes):
    uri = "data:image/jpeg;base64," + base64.b64encode(data).decode("ascii")
    return {"type": "image_url", "image_url": {"url": uri, "detail": "high"}}

def extract_text(response):
    choices = getattr(response, "choices", None)
    if not choices:
        raise RuntimeError("Vision response has no choices.")
    message = getattr(choices[0], "message", None)
    content = getattr(message, "content", None)
    if not isinstance(content, str) or not content.strip():
        raise RuntimeError("Vision response has no text content.")
    return content.strip()

def parse_strict_json(text: str):
    try:
        value = json.loads(text)
    except Exception as exc:
        raise RuntimeError(f"Astra returned invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise RuntimeError("Astra output is not a JSON object.")
    return value

def review_prompt(viewport: str) -> str:
    viewport_note = (
        "Desktop viewport is 1440 px wide; the three images are consecutive vertical slices from one full-page render."
        if viewport == "desktop"
        else "Mobile viewport is 390 px wide; the three images are consecutive vertical slices from one full-page render."
    )
    return f"""You are the final independent visual QA reviewer for a professional mechanical-engineering article page.
Review ONLY what is visibly present in these current screenshots. Do not infer hidden HTML/CSS, and do not reuse a prior score.
{viewport_note}

Evaluate:
- visual hierarchy, spacing, typography, line length, rhythm, and scanability
- header/hero balance and whether the title/metadata dominate appropriately
- figures/photos/schematics: loading, sizing, cropping, captions, relevance, and visual support
- source/reference presentation and technical-document credibility
- CTA placement and whether it feels professional rather than promotional
- broken, blank, duplicated, stretched, clipped, overlapping, or awkward elements
- for mobile: text size, margins, horizontal overflow, image fit, long URLs/source blocks, and tap/readability concerns
- for desktop: content width, empty space, image/text balance, and overall premium/professional feel

Use a 0-100 score where:
90-100 = publication-quality visual layout; only trivial polish remains
80-89 = strong; minor revisions recommended
70-79 = meaningful revision still needed
below 70 = substantial visual problems

Return ONE JSON object only, with exactly:
{{
  "viewport": "{viewport}",
  "canSeeAllThreeSlices": true|false,
  "score": integer,
  "verdict": "PASS"|"PASS_WITH_MINOR_REVISIONS"|"REVISE"|"BLOCK",
  "strengths": [string],
  "issues": [
    {{
      "severity": "BLOCKER"|"MAJOR"|"MINOR",
      "location": string,
      "finding": string,
      "recommendation": string
    }}
  ],
  "publicationBlockingIssues": [string],
  "summary": string
}}

Do not call something broken merely because a screenshot slice begins or ends mid-section. Judge slice boundaries as capture boundaries, not layout boundaries.
"""

async def do_review(async_call_llm, viewport: str, images: list[bytes]):
    route = {}
    content = [{"type": "text", "text": review_prompt(viewport)}]
    content.extend(image_block(x) for x in images)
    response = await async_call_llm(
        task="vision",
        provider=EXPECTED_PROVIDER,
        model=EXPECTED_MODEL,
        messages=[{"role": "user", "content": content}],
        max_tokens=2600,
        timeout=240,
        reasoning_config={"effort": "high"},
        route_info=route,
    )
    routed_provider = str(route.get("provider") or route.get("resolved_provider") or "")
    routed_model = str(route.get("model") or route.get("resolved_model") or "")
    if EXPECTED_PROVIDER not in routed_provider.lower():
        raise RuntimeError(f"Unexpected vision provider route: {route}")
    if routed_model != EXPECTED_MODEL:
        raise RuntimeError(f"Unexpected vision model route: {route}")
    parsed = parse_strict_json(extract_text(response))
    if parsed.get("viewport") != viewport:
        raise RuntimeError(f"Astra viewport mismatch: {parsed.get('viewport')!r}")
    if not isinstance(parsed.get("score"), int) or not (0 <= parsed["score"] <= 100):
        raise RuntimeError("Astra score is invalid.")
    if parsed.get("verdict") not in {"PASS", "PASS_WITH_MINOR_REVISIONS", "REVISE", "BLOCK"}:
        raise RuntimeError("Astra verdict is invalid.")
    return {
        "review": parsed,
        "route": route,
        "providerVerified": EXPECTED_PROVIDER in routed_provider.lower(),
        "modelVerified": routed_model == EXPECTED_MODEL,
    }

async def main_async(image_base: str):
    actual_host = (os.environ.get("COMPUTERNAME") or platform.node() or "").upper()
    if actual_host != EXPECTED_HOST:
        fail(f"H3-only runner; host={actual_host!r}")
    if not HERMES_ROOT.is_dir():
        fail(f"Hermes root missing: {HERMES_ROOT}")
    os.chdir(HERMES_ROOT)
    sys.path.insert(0, str(HERMES_ROOT))
    try:
        from agent.auxiliary_client import async_call_llm
    except Exception as exc:
        fail(f"Could not import Hermes auxiliary client: {type(exc).__name__}: {exc}")

    try:
        desktop_images = [fetch_image(image_base, name) for name in DESKTOP]
        mobile_images = [fetch_image(image_base, name) for name in MOBILE]
        desktop = await do_review(async_call_llm, "desktop", desktop_images)
        mobile = await do_review(async_call_llm, "mobile", mobile_images)
    except Exception as exc:
        fail(f"{type(exc).__name__}: {exc}")

    result = {
        "ok": True,
        "schema": 1,
        "host": EXPECTED_HOST,
        "provider": EXPECTED_PROVIDER,
        "model": EXPECTED_MODEL,
        "imageBase": image_base,
        "imageNames": DESKTOP + MOBILE,
        "desktop": desktop,
        "mobile": mobile,
        "publicationMutation": False,
        "databaseMutation": False,
        "liveSiteMutation": False,
    }
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image-base", default=DEFAULT_IMAGE_BASE)
    args = parser.parse_args()
    asyncio.run(main_async(args.image_base))

if __name__ == "__main__":
    main()
