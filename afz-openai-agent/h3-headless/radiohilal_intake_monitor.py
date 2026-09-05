import json
import os
import tempfile
import urllib.request
from datetime import datetime
from pathlib import Path

ADMIN = "http://192.168.50.94:3002"
API = "http://192.168.50.94:5149"
REVIEW_LIMIT = 500
TIMEOUT_SECONDS = 8
TERMINAL = {"approved", "rejected"}
STATES = ("pending", "downloading", "transcribing", "readyforreview")
ACTIVE = set(STATES) | {"reviewing"}
REVIEW_BACKLOG_LIMIT = 8
INTAKE_START_MINUTE = 30
INTAKE_END_MINUTE = 7 * 60

LOCAL_HERMES = Path(os.environ.get("LOCALAPPDATA", "C:/Users/Faiz/AppData/Local")) / "hermes"
STATE_FILE = LOCAL_HERMES / "radiohilal-monitor-state.json"
INTAKE_SUCCESS_FILE = LOCAL_HERMES / "radiohilal-intake-success.json"


def get_json(base, path):
    request = urllib.request.Request(
        base + path,
        headers={"Accept": "application/json", "Connection": "close"},
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return json.load(response)


def rows_from(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in ("items", "data", "results", "reviews"):
            if isinstance(value.get(key), list):
                return value[key]
    return []


def text(value):
    return str(value or "").strip().lower()


def status(row):
    return text(row.get("status", row.get("Status", "")))


def content_type(row):
    return text(row.get("contentType", row.get("ContentType", "")))


def number(value):
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return 0


def healthy(value):
    if isinstance(value, bool):
        return value
    return text(value) in {"ok", "healthy", "true", "ready", "up", "running"}


def first(mapping, *keys):
    if not isinstance(mapping, dict):
        return None
    for key in keys:
        if key in mapping:
            return mapping[key]
    return None


def running(queue, health):
    for source in (queue, health):
        value = first(source, "intakeRunning", "isIntakeRunning", "discoveryRunning")
        if isinstance(value, bool):
            return value
        if text(value) in {"running", "active", "processing", "busy"}:
            return True
    workflow = text(first(queue, "workflow", "state", "status"))
    return workflow in {"running", "active", "processing", "busy", "intake", "discovering"}


def local_now():
    override = os.environ.get("AFZ_RADIOHILAL_NOW_LOCAL", "").strip()
    if override:
        return datetime.fromisoformat(override)
    return datetime.now().astimezone()


def intake_window_open(now):
    minute_of_day = now.hour * 60 + now.minute
    return INTAKE_START_MINUTE <= minute_of_day < INTAKE_END_MINUTE


def intake_succeeded_today(now):
    try:
        value = json.loads(INTAKE_SUCCESS_FILE.read_text(encoding="utf-8"))
        return str(value.get("date", "")) == now.date().isoformat()
    except (OSError, ValueError, TypeError, AttributeError):
        return False


def load_previous():
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return None


def save_current(snapshot):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix="radiohilal-monitor-", suffix=".json", dir=STATE_FILE.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(snapshot, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
        os.replace(name, STATE_FILE)
    finally:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass


def main():
    now = local_now()
    window_open = intake_window_open(now)
    success_today = intake_succeeded_today(now)

    try:
        health = get_json(API, "/api/system/health")
        queue = get_json(API, "/api/queue/summary")
        rows = rows_from(get_json(ADMIN, f"/api/content-reviews?limit={REVIEW_LIMIT}"))

        api_ok = all(
            healthy(first(health, key, key.capitalize()))
            for key in ("api", "library", "providers")
            if first(health, key, key.capitalize()) is not None
        )
        state_rows = [row for row in rows if isinstance(row, dict)]
        nonterminal = [row for row in state_rows if status(row) not in TERMINAL]
        lectures = [row for row in state_rows if content_type(row) == "lecture"]
        counts = {state: sum(status(row) == state for row in lectures) for state in STATES}
        active = sum(status(row) in ACTIVE for row in lectures)
        pending = number(first(queue, "pending", "Pending"))
        downloading = number(first(queue, "downloading", "Downloading"))
        transcribing = number(first(queue, "transcribing", "Transcribing"))
        intake_running = running(queue, health)
        workflow = text(first(queue, "workflow", "state", "status"))
        queue_idle = workflow in {"", "idle", "ready", "none", "completed"}
        allowed = bool(
            api_ok
            and window_open
            and not success_today
            and queue_idle
            and not intake_running
            and active < REVIEW_BACKLOG_LIMIT
            and pending == 0
            and downloading == 0
        )
        snapshot = {
            "api_healthy": api_ok,
            "intake_running": intake_running,
            "active_lecture_count": active,
            "total_nonterminal_count": len(nonterminal),
            "pending_count": counts["pending"],
            "downloading_count": counts["downloading"],
            "transcribing_count": counts["transcribing"],
            "ready_count": counts["readyforreview"],
            "queue_pending_count": pending,
            "queue_downloading_count": downloading,
            "intake_window_open": window_open,
            "intake_succeeded_today": success_today,
            "review_backlog_limit": REVIEW_BACKLOG_LIMIT,
            "intake_allowed": allowed,
        }
    except Exception:
        snapshot = {
            "api_healthy": False,
            "intake_running": False,
            "active_lecture_count": 0,
            "total_nonterminal_count": 0,
            "pending_count": 0,
            "downloading_count": 0,
            "transcribing_count": 0,
            "ready_count": 0,
            "queue_pending_count": 0,
            "queue_downloading_count": 0,
            "intake_window_open": window_open,
            "intake_succeeded_today": success_today,
            "review_backlog_limit": REVIEW_BACKLOG_LIMIT,
            "intake_allowed": False,
        }

    previous = load_previous()
    changed = previous != snapshot

    if not snapshot["api_healthy"]:
        action = "bounded_recovery" if changed else "no_change"
    elif snapshot["ready_count"] >= REVIEW_BACKLOG_LIMIT and changed:
        action = "reconcile_ready"
    elif snapshot["intake_allowed"] and changed:
        action = "consider_intake"
    elif snapshot["ready_count"] > 0 and changed:
        action = "reconcile_ready"
    elif changed:
        action = "reconcile_change"
    else:
        action = "no_change"

    output = dict(snapshot)
    output["changed_since_previous_run"] = changed
    output["next_action"] = action

    if os.environ.get("AFZ_RADIOHILAL_MONITOR_NO_COMMIT") != "1":
        save_current(snapshot)

    print(json.dumps(output, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()