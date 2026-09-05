import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

HERMES_HOME = Path(r"C:\Users\Faiz\AppData\Local\hermes")
HERMES = HERMES_HOME / "bin" / "hermes.exe"
MONITOR = HERMES_HOME / "scripts" / "radiohilal_intake_monitor.py"
STATE_FILE = HERMES_HOME / "radiohilal-monitor-state.json"
INTAKE_SUCCESS_FILE = HERMES_HOME / "radiohilal-intake-success.json"
WORKDIR = Path(r"C:\Users\Faiz")
PROVIDER = "openai-codex"
MODEL = "gpt-5.6-luna"

def clean(text):
    return " ".join((text or "").replace("\r", " ").replace("\n", " ").split())

def capture_monitor_state():
    try:
        return True, STATE_FILE.read_bytes()
    except FileNotFoundError:
        return False, None

def restore_monitor_state(existed, payload):
    try:
        if existed:
            tmp = STATE_FILE.with_name(STATE_FILE.name + f".rollback-{os.getpid()}.tmp")
            tmp.write_bytes(payload or b"")
            os.replace(tmp, STATE_FILE)
        else:
            try:
                STATE_FILE.unlink()
            except FileNotFoundError:
                pass
    except OSError:
        pass

def mark_intake_success(answer):
    now = datetime.now().astimezone()
    payload = {
        "date": now.date().isoformat(),
        "recorded_at": now.isoformat(),
        "result": answer[:500],
    }
    tmp = INTAKE_SUCCESS_FILE.with_name(
        INTAKE_SUCCESS_FILE.name + f".tmp-{os.getpid()}"
    )
    tmp.write_text(
        json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    os.replace(tmp, INTAKE_SUCCESS_FILE)


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
monitor_touched = False
prior_state_existed = False
prior_state_payload = None

if override:
    raw = override
else:
    prior_state_existed, prior_state_payload = capture_monitor_state()
    monitor_touched = True
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
        restore_monitor_state(prior_state_existed, prior_state_payload)
        print("FAILURE blocker=monitor-timeout next=next-cycle")
        sys.exit(0)
    if cp.returncode != 0:
        restore_monitor_state(prior_state_existed, prior_state_payload)
        print(f"FAILURE blocker=monitor-exit-{cp.returncode} next=next-cycle")
        sys.exit(0)
    lines = [line.strip() for line in cp.stdout.splitlines() if line.strip()]
    raw = lines[-1] if lines else ""

try:
    state = json.loads(raw)
except Exception:
    if monitor_touched:
        restore_monitor_state(prior_state_existed, prior_state_payload)
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
      "For intake: never add when intake_allowed=false; exact-URL dedupe first; "
      "at most one eligible recent standalone speaker-diverse lecture. Preserve source metadata and do not assert rights. "
      "For ReadyForReview: reconcile only one existing relevant ID, require source/media identity and integrity, "
      "deterministic local/lexical/promo gates, and explicit final OpenAI verification PASSED; otherwise HUMAN_HOLD. "
      "Return one compact result only: RADIOHILAL_NO_CHANGE, BLOCKED, SUBMITTED, TERMINAL, FAILURE, or CONTROLLER_TIMEOUT."
)

try:
    answer, err = run_agent(prompt, timeout=120)
except subprocess.TimeoutExpired:
    if monitor_touched:
        restore_monitor_state(prior_state_existed, prior_state_payload)
    print("CONTROLLER_TIMEOUT")
    sys.exit(0)

if err:
    if monitor_touched:
        restore_monitor_state(prior_state_existed, prior_state_payload)
    print("FAILURE blocker=" + err + " next=next-cycle")
    sys.exit(0)

valid_prefixes = (
    "RADIOHILAL_NO_CHANGE",
    "BLOCKED",
    "SUBMITTED",
    "TERMINAL",
    "FAILURE",
    "CONTROLLER_TIMEOUT",
)
if not any(answer == p or answer.startswith(p + " ") for p in valid_prefixes):
    if monitor_touched:
        restore_monitor_state(prior_state_existed, prior_state_payload)
    print("FAILURE blocker=agent-unexpected-response next=next-cycle")
    sys.exit(0)

if answer == "CONTROLLER_TIMEOUT" or answer.startswith("CONTROLLER_TIMEOUT ") or answer == "FAILURE" or answer.startswith("FAILURE "):
    if monitor_touched:
        restore_monitor_state(prior_state_existed, prior_state_payload)

if answer == "SUBMITTED" or answer.startswith("SUBMITTED "):
    try:
        mark_intake_success(answer)
    except OSError:
        print("FAILURE blocker=intake-marker-write-failed next=manual-check")
        sys.exit(0)

print(answer)
sys.exit(0)