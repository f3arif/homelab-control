import json
import os
import subprocess
import sys
from pathlib import Path

HERMES_HOME = Path(r"C:\Users\Faiz\AppData\Local\hermes")
HERMES = HERMES_HOME / "bin" / "hermes.exe"
MONITOR = HERMES_HOME / "scripts" / "radiohilal_intake_monitor.py"
WORKDIR = Path(r"C:\Users\Faiz")
PROVIDER = "openai-codex"
MODEL = "gpt-5.6-luna"

def clean(text):
    return " ".join((text or "").replace("\r", " ").replace("\n", " ").split())

def run_agent(prompt, timeout=120):
    cp = subprocess.run(
        [
            str(HERMES),
            "--provider", PROVIDER,
            "-m", MODEL,
            "--reasoning", "low",
            "--in", str(WORKDIR),
            "-z", prompt,
        ],
        cwd=str(WORKDIR),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        env={**os.environ, "HERMES_HOME": str(HERMES_HOME)},
    )
    if cp.returncode != 0:
        return None, f"agent-exit-{cp.returncode} {clean(cp.stderr)[:240]}"
    answer = clean(cp.stdout)
    if not answer:
        return None, "agent-empty-response"
    return answer, None

if os.environ.get("AFZ_RADIOHILAL_AGENT_SMOKE") == "1":
    try:
        answer, err = run_agent("Reply only RADIOHILAL_AGENT_OK", timeout=60)
    except subprocess.TimeoutExpired:
        print("AGENT_SMOKE_TIMEOUT")
        sys.exit(4)
    if err:
        print("AGENT_SMOKE_FAIL " + err)
        sys.exit(5)
    print(answer)
    sys.exit(0 if "RADIOHILAL_AGENT_OK" in answer else 6)

override = os.environ.get("AFZ_RADIOHILAL_MONITOR_JSON_OVERRIDE")
if override:
    raw = override
else:
    try:
        cp = subprocess.run(
            [sys.executable, str(MONITOR)],
            cwd=str(WORKDIR),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
            env={**os.environ, "HERMES_HOME": str(HERMES_HOME)},
        )
    except subprocess.TimeoutExpired:
        print("FAILURE blocker=monitor-timeout next=next-cycle")
        sys.exit(0)
    if cp.returncode != 0:
        print(f"FAILURE blocker=monitor-exit-{cp.returncode} next=next-cycle")
        sys.exit(0)
    lines = [line.strip() for line in cp.stdout.splitlines() if line.strip()]
    raw = lines[-1] if lines else ""

try:
    state = json.loads(raw)
except Exception:
    print("FAILURE blocker=monitor-json-invalid next=next-cycle")
    sys.exit(0)

active = int(state.get("active_lecture_count") or 0)
changed = bool(state.get("changed_since_previous_run"))
next_action = str(state.get("next_action") or "")

if (not changed) and next_action == "no_change":
    print(f"RADIOHILAL_NO_CHANGE active={active} next=next-cycle")
    sys.exit(0)

if os.environ.get("AFZ_RADIOHILAL_DRY_RUN") == "1":
    print("DRY_RUN_AGENT_REQUIRED next_action=" + (next_action or "unknown"))
    sys.exit(0)

monitor_json = json.dumps(state, separators=(",", ":"), ensure_ascii=True)
prompt = (
    "Run one bounded Radio Hilal controller action from this Stage-1 monitor JSON: "
    + monitor_json
    + ". Finish within 90 seconds. Do at most one action sequence. "
      "Never duplicate queued, processing, intake, or terminal reviews. "
      "Windows-main owns Radio Hilal API/database/local-media/service mutations. "
      "For intake: never add when intake_allowed=false or active_lecture_count>=2; exact-URL dedupe first; "
      "at most one eligible recent standalone speaker-diverse lecture. Preserve source metadata and do not assert rights. "
      "For ReadyForReview: reconcile only the same relevant ID, require source/media identity and integrity, "
      "deterministic local/lexical/promo gates, and explicit final OpenAI verification PASSED; otherwise HUMAN_HOLD. "
      "Return one compact result only: RADIOHILAL_NO_CHANGE, BLOCKED, SUBMITTED, TERMINAL, FAILURE, or CONTROLLER_TIMEOUT."
)

try:
    answer, err = run_agent(prompt, timeout=120)
except subprocess.TimeoutExpired:
    print("CONTROLLER_TIMEOUT")
    sys.exit(0)

if err:
    print("FAILURE blocker=" + err + " next=next-cycle")
    sys.exit(0)

print(answer)
sys.exit(0)
