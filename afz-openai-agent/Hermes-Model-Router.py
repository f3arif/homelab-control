import argparse
import json
import platform
import subprocess
import sys
import time
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(r"C:\Projects\HermesRouter")
RUNS = ROOT / "runs"
RUNS.mkdir(parents=True, exist_ok=True)

HOSTNAME = platform.node().upper()

if HOSTNAME == "DESKTOP-H3R6CQN":
    LOCAL_DIRECT = {
        "name": "local-h3-35b",
        "provider": "ollama-direct",
        "model": "qwen3.6:35b-a3b-hermes64k",
        "timeout": 180,
        "num_ctx": 65536,
        "num_predict": 2048,
    }
else:
    LOCAL_DIRECT = {
        "name": "local-asus-4b",
        "provider": "ollama-direct",
        "model": "qwen3.5:4b-hermes96k",
        "timeout": 90,
        "num_ctx": 32768,
        "num_predict": 2048,
    }

ROUTES = {
    "default": [
        {"name":"sol-oauth","provider":"openai-codex","model":"gpt-5.6-sol-900k","timeout":180},
        {"name":"astra-oauth","provider":"openai-codex","model":"gpt-6-astra","timeout":240},
        {"name":"glm-flash","provider":"openrouter","model":"z-ai/glm-5.3-flash","timeout":65},
        {"name":"glm-full","provider":"openrouter","model":"z-ai/glm-5.3","timeout":90},
        LOCAL_DIRECT,
    ],
    "cheap": [
        {"name":"sol-oauth","provider":"openai-codex","model":"gpt-5.6-sol-900k","timeout":180},
        {"name":"astra-oauth","provider":"openai-codex","model":"gpt-6-astra","timeout":240},
        {"name":"deepseek","provider":"openrouter","model":"deepseek/deepseek-v4-flash-0731","timeout":90},
        {"name":"glm-flash","provider":"openrouter","model":"z-ai/glm-5.3-flash","timeout":65},
        LOCAL_DIRECT,
    ],
    "coding": [
        {"name":"sol-oauth","provider":"openai-codex","model":"gpt-5.6-sol-900k","timeout":180},
        {"name":"astra-oauth","provider":"openai-codex","model":"gpt-6-astra","timeout":240},
        {"name":"glm-flash","provider":"openrouter","model":"z-ai/glm-5.3-flash","timeout":65},
        {"name":"glm-full","provider":"openrouter","model":"z-ai/glm-5.3","timeout":90},
        LOCAL_DIRECT,
    ],
    "complex": [
        {"name":"sol-oauth","provider":"openai-codex","model":"gpt-5.6-sol-900k","timeout":180},
        {"name":"astra-oauth","provider":"openai-codex","model":"gpt-6-astra","timeout":240},
        {"name":"glm-full","provider":"openrouter","model":"z-ai/glm-5.3","timeout":90},
        {"name":"glm-flash","provider":"openrouter","model":"z-ai/glm-5.3-flash","timeout":65},
        LOCAL_DIRECT,
    ],
    "qwen": [
        {"name":"qwen38","provider":"openrouter","model":"qwen/qwen3.8-flash","timeout":60},
        {"name":"glm-flash","provider":"openrouter","model":"z-ai/glm-5.3-flash","timeout":65},
        {"name":"glm-full","provider":"openrouter","model":"z-ai/glm-5.3","timeout":90},
        LOCAL_DIRECT,
    ],
    "sensitive": [
        {"name":"sol-oauth","provider":"openai-codex","model":"gpt-5.6-sol-900k","timeout":180},
        {"name":"astra-oauth","provider":"openai-codex","model":"gpt-6-astra","timeout":240},
        LOCAL_DIRECT,
    ],
    "local": [LOCAL_DIRECT],
}

PRIVATE_VALUES = {"private","sensitive","client"}

def validate(text, validator):
    if not validator or validator == "none":
        return True, ""
    s = text.strip()
    if validator == "json":
        try:
            json.loads(s)
            return True, ""
        except Exception as e:
            return False, f"invalid_json:{e}"
    if validator == "diff":
        if s.startswith("--- ") and "\n+++ " in s:
            return True, ""
        return False, "not_bare_unified_diff"
    if validator.startswith("lines:"):
        try:
            expected = int(validator.split(":", 1)[1])
        except ValueError:
            return False, "invalid_line_validator"
        lines = [x for x in s.splitlines() if x.strip()]
        return len(lines) == expected, f"line_count={len(lines)} expected={expected}"
    return False, f"unknown_validator:{validator}"

def run_ollama_direct(route, prompt, validator):
    started = time.perf_counter()
    payload = json.dumps({
        "model": route["model"],
        "prompt": prompt,
        "stream": False,
        "think": False,
        "keep_alive": "5m",
        "options": {
            "num_ctx": route.get("num_ctx", 32768),
            "num_predict": route.get("num_predict", 2048),
        },
    }).encode("utf-8")
    req = urllib.request.Request(
        "http://127.0.0.1:11434/api/generate",
        data=payload,
        headers={"Content-Type":"application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=route["timeout"]) as resp:
            data = json.load(resp)
        elapsed = round(time.perf_counter() - started, 3)
        text = (data.get("response") or "").strip()
        valid, validation_error = validate(text, validator)
        return {
            "name": route["name"],
            "provider": route["provider"],
            "model": route["model"],
            "timeout_s": route["timeout"],
            "elapsed_s": elapsed,
            "returncode": 0,
            "ok": bool(text) and valid,
            "validation_error": validation_error,
            "stdout": text,
            "stderr_tail": "",
            "usage": {
                "input_tokens": data.get("prompt_eval_count"),
                "output_tokens": data.get("eval_count"),
                "estimated_cost_usd": 0.0,
                "cost_status": "local",
                "api_calls": 1,
                "model": route["model"],
                "provider": "ollama-direct",
            },
        }
    except Exception as e:
        elapsed = round(time.perf_counter() - started, 3)
        return {
            "name": route["name"],
            "provider": route["provider"],
            "model": route["model"],
            "timeout_s": route["timeout"],
            "elapsed_s": elapsed,
            "returncode": -1,
            "ok": False,
            "validation_error": "timeout_or_local_error",
            "stdout": "",
            "stderr_tail": repr(e),
            "usage": {},
        }

def run_hermes(route, prompt, validator, attempt_no, run_id):
    usage_path = RUNS / f"{run_id}-{attempt_no}-{route['name']}-usage.json"
    cmd = [
        "hermes",
        "--provider", route["provider"],
        "--model", route["model"],
        "--ignore-rules",
        "--usage-file", str(usage_path),
        "-z", prompt,
    ]
    started = time.perf_counter()
    try:
        cp = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=route["timeout"],
        )
        elapsed = round(time.perf_counter() - started, 3)
        stdout = (cp.stdout or "").strip()
        stderr = (cp.stderr or "").strip()
        usage = {}
        if usage_path.exists():
            try:
                usage = json.loads(usage_path.read_text(encoding="utf-8"))
            except Exception:
                pass
        provider_error = (
            stdout.startswith("HTTP 4") or stdout.startswith("HTTP 5")
            or "HTTP 4" in stderr or "HTTP 5" in stderr
            or usage.get("failed") is True
        )
        valid, validation_error = validate(stdout, validator)
        return {
            "name": route["name"],
            "provider": route["provider"],
            "model": route["model"],
            "timeout_s": route["timeout"],
            "elapsed_s": elapsed,
            "returncode": cp.returncode,
            "ok": cp.returncode == 0 and not provider_error and bool(stdout) and valid,
            "validation_error": validation_error,
            "stdout": stdout,
            "stderr_tail": stderr[-2500:],
            "usage": usage,
        }
    except subprocess.TimeoutExpired:
        return {
            "name": route["name"],
            "provider": route["provider"],
            "model": route["model"],
            "timeout_s": route["timeout"],
            "elapsed_s": round(time.perf_counter() - started, 3),
            "returncode": -1,
            "ok": False,
            "validation_error": "timeout",
            "stdout": "",
            "stderr_tail": "TIMEOUT",
            "usage": {},
        }

def run_attempt(route, prompt, validator, attempt_no, run_id):
    if route["provider"] == "ollama-direct":
        return run_ollama_direct(route, prompt, validator)
    return run_hermes(route, prompt, validator, attempt_no, run_id)

def main():
    ap = argparse.ArgumentParser(description="AFZ benchmark-informed Hermes model router")
    ap.add_argument("--lane", choices=sorted(ROUTES), default="default")
    ap.add_argument("--privacy", choices=["normal","private","sensitive","client"], default="normal")
    ap.add_argument("--validator", default="none", help="none | json | diff | lines:N")
    ap.add_argument("--prompt")
    ap.add_argument("--prompt-file")
    ap.add_argument("--json-result", action="store_true")
    args = ap.parse_args()

    if bool(args.prompt) == bool(args.prompt_file):
        ap.error("provide exactly one of --prompt or --prompt-file")
    prompt = args.prompt if args.prompt is not None else Path(args.prompt_file).read_text(encoding="utf-8")

    effective_lane = "sensitive" if args.privacy in PRIVATE_VALUES else args.lane
    run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    attempts = []
    final = None

    for i, route in enumerate(ROUTES[effective_lane], 1):
        result = run_attempt(route, prompt, args.validator, i, run_id)
        attempts.append(result)
        if result["ok"]:
            final = result
            break

    audit = {
        "schema": 2,
        "run_id": run_id,
        "requested_lane": args.lane,
        "effective_lane": effective_lane,
        "privacy": args.privacy,
        "validator": args.validator,
        "ok": final is not None,
        "selected": None if final is None else {
            "name": final["name"],
            "provider": final["provider"],
            "model": final["model"],
            "elapsed_s": final["elapsed_s"],
        },
        "attempts": attempts,
        "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    audit_path = RUNS / f"{run_id}-audit.json"
    audit_path.write_text(json.dumps(audit, indent=2), encoding="utf-8")

    if args.json_result:
        print(json.dumps(audit, ensure_ascii=False))
    elif final is not None:
        print(final["stdout"])
    else:
        print(f"All route attempts failed. Audit: {audit_path}", file=sys.stderr)
        for a in attempts:
            detail = a["validation_error"] or a["stderr_tail"][:300]
            print(f"{a['name']}: {detail}", file=sys.stderr)
        return 2
    return 0

if __name__ == "__main__":
    raise SystemExit(main())