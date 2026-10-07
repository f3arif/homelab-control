"""Durable isolated AFZ admission, continuation, verification, and recovery core.

This module is a candidate adapter around existing Hermes/AFZ control planes.  It
intentionally does not start gateways, dispatch fleet work, enable cross-host
execution, or claim an OS/process security boundary.
"""
from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import uuid
from collections.abc import Callable, Iterable, Sequence
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class Policy:
    """Immutable policy supplied by an authority outside an executor callback."""

    allowed_actions: frozenset[str] = frozenset(
        {"execute", "upload", "notify", "safe-repair"}
    )
    approved_routes: frozenset[str] = frozenset(
        {"default", "coding", "complex", "local"}
    )
    required_reviewer: str = "independent-reviewer"
    required_approval: str = "original-approval"
    production_enforced: bool = False


@dataclass(frozen=True)
class ChildResult:
    exit_code: int
    tests_executed: int
    tests_skipped: int
    source_hash: str
    artifact_hashes: dict[str, str]
    narrative: str = ""
    target_readback: bool = False


@dataclass(frozen=True)
class ReviewReceipt:
    verifier: str
    authenticated: bool
    source_hash: str
    artifact_hashes: dict[str, str]
    approval_id: str
    target_readback: bool


class RetryableError(RuntimeError):
    def __init__(self, kind: str, *, retry_after: float = 0.0):
        super().__init__(kind)
        self.kind = kind
        self.retry_after = max(float(retry_after), 0.0)


class CrashError(RuntimeError):
    def __init__(self, checkpoint: str):
        super().__init__(checkpoint)
        self.checkpoint = checkpoint


class UncertainEffect(RuntimeError):
    def __init__(self, target_key: str):
        super().__init__(target_key)
        self.target_key = target_key


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class MissionEngine:
    """SQLite-backed prototype controller with fail-closed completion gates."""

    def __init__(
        self,
        db_path: str | Path,
        *,
        policy: Policy,
        clock: Callable[[], float],
    ) -> None:
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.policy = policy
        self.clock = clock
        self.production_restart_count = 0
        self.cross_host_enabled = False
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.db_path)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("PRAGMA journal_mode=WAL")
        return connection

    def _init_db(self) -> None:
        with self._connect() as db:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS missions (
                    id TEXT PRIMARY KEY,
                    ingress_key TEXT NOT NULL UNIQUE,
                    scope_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    expires_at REAL,
                    max_attempts INTEGER NOT NULL,
                    max_turns INTEGER NOT NULL,
                    turns_used INTEGER NOT NULL DEFAULT 0,
                    paused INTEGER NOT NULL DEFAULT 0,
                    cancelled INTEGER NOT NULL DEFAULT 0,
                    external_process_alive INTEGER NOT NULL DEFAULT 0,
                    live_provider_proof INTEGER NOT NULL DEFAULT 0,
                    production_enforced INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS steps (
                    mission_id TEXT NOT NULL,
                    key TEXT NOT NULL,
                    depends_json TEXT NOT NULL,
                    action TEXT NOT NULL,
                    source_path TEXT NOT NULL,
                    artifacts_json TEXT NOT NULL,
                    required_tests INTEGER NOT NULL,
                    side_effect_key TEXT,
                    status TEXT NOT NULL DEFAULT 'pending',
                    reason TEXT NOT NULL DEFAULT '',
                    attempts INTEGER NOT NULL DEFAULT 0,
                    checkpoint TEXT NOT NULL DEFAULT '',
                    owner TEXT,
                    claim_epoch INTEGER NOT NULL DEFAULT 0,
                    child_json TEXT,
                    review_json TEXT,
                    next_eligible_at REAL NOT NULL DEFAULT 0,
                    PRIMARY KEY (mission_id, key),
                    FOREIGN KEY (mission_id) REFERENCES missions(id)
                );
                CREATE TABLE IF NOT EXISTS receipts (
                    kind TEXT NOT NULL,
                    key TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (kind, key)
                );
                CREATE TABLE IF NOT EXISTS operation_state (
                    kind TEXT NOT NULL,
                    key TEXT NOT NULL,
                    binding_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    owner TEXT,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    next_eligible_at REAL NOT NULL DEFAULT 0,
                    payload_json TEXT NOT NULL DEFAULT '{}',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (kind, key)
                );
                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    mission_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                """
            )
            columns = {
                str(row["name"])
                for row in db.execute("PRAGMA table_info(steps)").fetchall()
            }
            if "next_eligible_at" not in columns:
                db.execute(
                    "ALTER TABLE steps ADD COLUMN "
                    "next_eligible_at REAL NOT NULL DEFAULT 0"
                )

    @staticmethod
    def _json(value: Any) -> str:
        return json.dumps(value, sort_keys=True, separators=(",", ":"))

    @staticmethod
    def _sanitize_error(error: BaseException) -> str:
        message = re.sub(
            r"(?i)(secret|token|password)=([^\s,;]+)",
            r"\1=[REDACTED]",
            str(error),
        )
        return message[:500]

    def _event(self, db: sqlite3.Connection, mission_id: str, kind: str, payload: Any) -> None:
        db.execute(
            "INSERT INTO events(mission_id,kind,payload_json,created_at) VALUES(?,?,?,?)",
            (mission_id, kind, self._json(payload), self.clock()),
        )

    def admit(
        self,
        ingress_key: str,
        *,
        scope: Sequence[str],
        expires_at: float | None = None,
        max_attempts: int = 3,
        max_turns: int = 20,
    ) -> str:
        """Idempotently admit a mission; duplicate ingress cannot widen its scope/budget."""
        if not ingress_key:
            raise ValueError("ingress_key is required")
        if max_attempts < 1 or max_turns < 1:
            raise ValueError("budgets must be positive")
        normalized_scope = sorted(set(scope))
        with self._connect() as db:
            row = db.execute(
                "SELECT id FROM missions WHERE ingress_key=?", (ingress_key,)
            ).fetchone()
            if row:
                return str(row["id"])
            mission_id = "m_" + uuid.uuid4().hex[:16]
            now = self.clock()
            db.execute(
                """INSERT INTO missions(
                    id,ingress_key,scope_json,status,expires_at,max_attempts,max_turns,
                    production_enforced,created_at,updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?)""",
                (
                    mission_id,
                    ingress_key,
                    self._json(normalized_scope),
                    "admitted",
                    expires_at,
                    int(max_attempts),
                    int(max_turns),
                    int(self.policy.production_enforced),
                    now,
                    now,
                ),
            )
            self._event(db, mission_id, "admitted", {"ingress_key": ingress_key})
            return mission_id

    def add_step(
        self,
        mission_id: str,
        key: str,
        *,
        depends_on: Sequence[str] = (),
        action: str,
        source_path: str | Path,
        expected_artifacts: Sequence[str | Path],
        required_tests: int,
        side_effect_key: str | None = None,
    ) -> None:
        if required_tests < 1:
            raise ValueError("required_tests must be positive")
        with self._connect() as db:
            db.execute(
                """INSERT INTO steps(
                    mission_id,key,depends_json,action,source_path,artifacts_json,
                    required_tests,side_effect_key
                ) VALUES(?,?,?,?,?,?,?,?)""",
                (
                    mission_id,
                    key,
                    self._json(list(depends_on)),
                    action,
                    str(Path(source_path)),
                    self._json([str(Path(p)) for p in expected_artifacts]),
                    int(required_tests),
                    side_effect_key,
                ),
            )
            self._event(db, mission_id, "step_added", {"key": key, "action": action})

    def mission(self, mission_id: str) -> dict[str, Any]:
        with self._connect() as db:
            row = db.execute("SELECT * FROM missions WHERE id=?", (mission_id,)).fetchone()
        if row is None:
            raise KeyError(mission_id)
        data = dict(row)
        data["scope"] = json.loads(data.pop("scope_json"))
        for key in ("paused", "cancelled", "external_process_alive", "live_provider_proof", "production_enforced"):
            data[key] = bool(data[key])
        return data

    def _decode_step(self, row: sqlite3.Row | dict[str, Any]) -> dict[str, Any]:
        data = dict(row)
        data["depends_on"] = json.loads(data.pop("depends_json"))
        data["expected_artifacts"] = json.loads(data.pop("artifacts_json"))
        data["child"] = json.loads(data.pop("child_json")) if data.get("child_json") else None
        data["review"] = json.loads(data.pop("review_json")) if data.get("review_json") else None
        return data

    def step(self, mission_id: str, key: str) -> dict[str, Any]:
        with self._connect() as db:
            row = db.execute(
                "SELECT * FROM steps WHERE mission_id=? AND key=?", (mission_id, key)
            ).fetchone()
        if row is None:
            raise KeyError((mission_id, key))
        return self._decode_step(row)

    def _steps(self, mission_id: str) -> list[dict[str, Any]]:
        with self._connect() as db:
            rows = db.execute(
                "SELECT * FROM steps WHERE mission_id=? ORDER BY rowid", (mission_id,)
            ).fetchall()
        return [self._decode_step(row) for row in rows]

    def mission_count(self) -> int:
        with self._connect() as db:
            return int(db.execute("SELECT COUNT(*) FROM missions").fetchone()[0])

    def claim(self, mission_id: str, key: str, *, owner: str) -> int | None:
        with self._connect() as db:
            row = db.execute(
                "SELECT owner,claim_epoch,status FROM steps WHERE mission_id=? AND key=?",
                (mission_id, key),
            ).fetchone()
            if row is None:
                raise KeyError((mission_id, key))
            if row["owner"]:
                return None
            epoch = int(row["claim_epoch"]) + 1
            changed = db.execute(
                """UPDATE steps SET owner=?,claim_epoch=?
                   WHERE mission_id=? AND key=? AND owner IS NULL""",
                (owner, epoch, mission_id, key),
            ).rowcount
            if not changed:
                return None
            self._event(db, mission_id, "claimed", {"key": key, "owner": owner, "epoch": epoch})
            return epoch

    def commit_claim(self, mission_id: str, key: str, owner: str, epoch: int) -> bool:
        with self._connect() as db:
            row = db.execute(
                "SELECT owner,claim_epoch FROM steps WHERE mission_id=? AND key=?",
                (mission_id, key),
            ).fetchone()
            return bool(row and row["owner"] == owner and int(row["claim_epoch"]) == int(epoch))

    def recover_stale_claim(
        self,
        mission_id: str,
        key: str,
        *,
        heartbeat_stale: bool,
        process_alive: bool,
        owner: str,
    ) -> bool:
        if not heartbeat_stale or process_alive:
            return False
        with self._connect() as db:
            row = db.execute(
                "SELECT owner,claim_epoch FROM steps WHERE mission_id=? AND key=?",
                (mission_id, key),
            ).fetchone()
            if row is None or row["owner"] != owner:
                return False
            epoch = int(row["claim_epoch"]) + 1
            db.execute(
                """UPDATE steps SET owner=NULL,claim_epoch=?,status='pending',
                   reason='old owner fenced after process absence proof'
                   WHERE mission_id=? AND key=?""",
                (epoch, mission_id, key),
            )
            db.execute(
                """UPDATE operation_state
                   SET status='uncertain',owner=NULL,updated_at=?
                   WHERE kind='effect' AND owner=? AND status='reserved'""",
                (self.clock(), owner),
            )
            self._event(db, mission_id, "owner_fenced", {"key": key, "owner": owner, "epoch": epoch})
            return True

    def _deps_verified(self, mission_id: str, deps: Iterable[str]) -> bool:
        return all(self.revalidate(mission_id, dep) for dep in deps)

    def _control_status(self, mission_id: str) -> str | None:
        mission = self.mission(mission_id)
        if mission["paused"]:
            return "paused"
        if mission["cancelled"]:
            return "cancelled"
        if mission["expires_at"] is not None and self.clock() > mission["expires_at"]:
            with self._connect() as db:
                self._set_mission_status(db, mission_id, "authorization_expired")
            return "authorization_expired"
        return None

    def _effect_binding(self, step: dict[str, Any]) -> str:
        source = Path(step["source_path"])
        return self._json(
            {
                "action": step["action"],
                "source_path": str(source),
                "source_hash": hash_file(source) if source.is_file() else "",
                "artifacts": step["expected_artifacts"],
            }
        )

    def _reserve_effect(
        self,
        key: str,
        binding: str,
        owner: str,
        *,
        allow_reconcile: bool = False,
    ) -> tuple[str, dict[str, Any]]:
        now = self.clock()
        with self._connect() as db:
            inserted = db.execute(
                """INSERT OR IGNORE INTO operation_state(
                       kind,key,binding_json,status,owner,created_at,updated_at
                   ) VALUES('effect',?,?, 'reserved',?,?,?)""",
                (key, binding, owner, now, now),
            ).rowcount
            if inserted:
                return "reserved", {}
            row = db.execute(
                "SELECT * FROM operation_state WHERE kind='effect' AND key=?",
                (key,),
            ).fetchone()
            if row is None:
                return "busy", {}
            if row["binding_json"] != binding:
                return "conflict", {}
            if row["status"] == "committed":
                return "committed", json.loads(row["payload_json"])
            if row["status"] == "uncertain" and allow_reconcile:
                changed = db.execute(
                    """UPDATE operation_state
                       SET status='reserved',owner=?,updated_at=?
                       WHERE kind='effect' AND key=? AND binding_json=?
                         AND status='uncertain' AND owner IS NULL""",
                    (owner, now, key, binding),
                ).rowcount
                if changed:
                    return "reconcile", json.loads(row["payload_json"])
            if (
                row["status"] == "retry_scheduled"
                and float(row["next_eligible_at"]) <= now
            ):
                changed = db.execute(
                    """UPDATE operation_state
                       SET status='reserved',owner=?,updated_at=?
                       WHERE kind='effect' AND key=? AND binding_json=?
                         AND status='retry_scheduled' AND next_eligible_at<=?""",
                    (owner, now, key, binding, now),
                ).rowcount
                if changed:
                    return "reserved", {}
            return "busy", {}

    def _release_effect_for_retry(
        self,
        key: str,
        owner: str,
        next_eligible_at: float,
    ) -> None:
        with self._connect() as db:
            db.execute(
                """UPDATE operation_state
                   SET status='retry_scheduled',owner=NULL,next_eligible_at=?,updated_at=?
                   WHERE kind='effect' AND key=? AND owner=? AND status='reserved'""",
                (next_eligible_at, self.clock(), key, owner),
            )

    def _release_unused_effect(self, key: str, owner: str) -> None:
        with self._connect() as db:
            db.execute(
                """DELETE FROM operation_state
                   WHERE kind='effect' AND key=? AND owner=? AND status='reserved'""",
                (key, owner),
            )

    def _restore_uncertain_effect(self, key: str, owner: str) -> None:
        """Release a read-only reconciliation lease without enabling replay."""
        with self._connect() as db:
            db.execute(
                """UPDATE operation_state
                   SET status='uncertain',owner=NULL,updated_at=?
                   WHERE kind='effect' AND key=? AND owner=? AND status='reserved'""",
                (self.clock(), key, owner),
            )

    def _set_mission_status(self, db: sqlite3.Connection, mission_id: str, status: str) -> None:
        db.execute(
            "UPDATE missions SET status=?,updated_at=? WHERE id=?",
            (status, self.clock(), mission_id),
        )

    def _reserve_attempt(
        self,
        mission_id: str,
        key: str,
        action: str,
        owner: str,
        epoch: int,
    ) -> tuple[str, int]:
        """Atomically admit one fenced attempt and consume one mission turn."""
        with self._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            mission = db.execute(
                "SELECT * FROM missions WHERE id=?", (mission_id,)
            ).fetchone()
            if mission is None:
                raise KeyError(mission_id)
            scope = json.loads(mission["scope_json"])
            if bool(mission["paused"]) or bool(mission["cancelled"]):
                return "controlled", 0
            if (
                mission["expires_at"] is not None
                and self.clock() > float(mission["expires_at"])
            ):
                self._set_mission_status(db, mission_id, "authorization_expired")
                return "controlled", 0
            if action not in self.policy.allowed_actions or action not in scope:
                return "policy_denied", 0

            step = db.execute(
                """SELECT attempts,owner,claim_epoch FROM steps
                   WHERE mission_id=? AND key=?""",
                (mission_id, key),
            ).fetchone()
            if (
                step is None
                or step["owner"] != owner
                or int(step["claim_epoch"]) != int(epoch)
            ):
                return "fenced", 0
            if int(mission["turns_used"]) >= int(mission["max_turns"]):
                return "turn_exhausted", 0
            if int(step["attempts"]) >= int(mission["max_attempts"]):
                db.execute(
                    """UPDATE steps SET status='budget_exhausted',
                           reason='cumulative attempt ceiling reached',owner=NULL
                       WHERE mission_id=? AND key=? AND owner=? AND claim_epoch=?""",
                    (mission_id, key, owner, epoch),
                )
                self._set_mission_status(db, mission_id, "budget_exhausted")
                return "budget_exhausted", int(step["attempts"])

            attempt = int(step["attempts"]) + 1
            changed = db.execute(
                """UPDATE steps SET attempts=?,status='running',reason='',
                       next_eligible_at=0
                   WHERE mission_id=? AND key=? AND owner=? AND claim_epoch=?""",
                (attempt, mission_id, key, owner, epoch),
            ).rowcount
            if not changed:
                return "fenced", 0
            db.execute(
                "UPDATE missions SET turns_used=turns_used+1,updated_at=? WHERE id=?",
                (self.clock(), mission_id),
            )
            self._event(
                db,
                mission_id,
                "attempt",
                {"key": key, "attempt": attempt, "epoch": epoch},
            )
            return "admitted", attempt

    def _release_claim(self, mission_id: str, key: str, owner: str, epoch: int) -> None:
        with self._connect() as db:
            db.execute(
                """UPDATE steps SET owner=NULL,status='pending'
                   WHERE mission_id=? AND key=? AND owner=? AND claim_epoch=?""",
                (mission_id, key, owner, epoch),
            )

    def _park_uncertain_effect(
        self,
        mission_id: str,
        key: str,
        owner: str,
        epoch: int,
        attempt: int,
        effect_key: str | None,
        target_key: str,
        reason: str,
    ) -> str:
        with self._connect() as db:
            changed = db.execute(
                """UPDATE steps SET status='uncertain',reason=?,owner=NULL
                   WHERE mission_id=? AND key=? AND owner=? AND claim_epoch=?
                     AND attempts=?""",
                (reason, mission_id, key, owner, epoch, attempt),
            ).rowcount
            if not changed:
                return "fenced"
            if effect_key:
                db.execute(
                    """UPDATE operation_state
                       SET status='uncertain',owner=NULL,payload_json=?,updated_at=?
                       WHERE kind='effect' AND key=? AND owner=? AND status='reserved'""",
                    (
                        self._json({"target_key": target_key}),
                        self.clock(),
                        effect_key,
                        owner,
                    ),
                )
        return "uncertain"

    def _park_callback_exception(
        self,
        mission_id: str,
        key: str,
        owner: str,
        epoch: int,
        attempt: int,
        effect_key: str | None,
        site: str,
        error: BaseException,
    ) -> str:
        status = "uncertain" if effect_key else "failed"
        message = self._sanitize_error(error)
        with self._connect() as db:
            changed = db.execute(
                """UPDATE steps SET status=?,reason=?,owner=NULL
                   WHERE mission_id=? AND key=? AND owner=? AND claim_epoch=?
                     AND attempts=?""",
                (
                    status,
                    f"unexpected {site} exception: {message}",
                    mission_id,
                    key,
                    owner,
                    epoch,
                    attempt,
                ),
            ).rowcount
            if not changed:
                return "fenced"
            if effect_key:
                db.execute(
                    """UPDATE operation_state
                       SET status='uncertain',owner=NULL,payload_json=?,updated_at=?
                       WHERE kind='effect' AND key=? AND owner=? AND status='reserved'""",
                    (
                        self._json({"target_key": effect_key}),
                        self.clock(),
                        effect_key,
                        owner,
                    ),
                )
            self._event(
                db,
                mission_id,
                "callback_exception",
                {"key": key, "site": site, "type": type(error).__name__, "message": message},
            )
        return status

    def _validate(
        self,
        step: dict[str, Any],
        child: ChildResult,
        review: ReviewReceipt,
    ) -> list[str]:
        reasons: list[str] = []
        if child.exit_code != 0:
            reasons.append(f"child exit {child.exit_code}")
        if child.tests_executed < step["required_tests"]:
            reasons.append(f"executed {child.tests_executed}/{step['required_tests']} mandatory tests")
        if child.tests_skipped:
            reasons.append(f"skipped {child.tests_skipped} mandatory tests")

        source = Path(step["source_path"])
        current_source_hash = hash_file(source) if source.is_file() else ""
        if not current_source_hash or child.source_hash != current_source_hash:
            reasons.append("source hash missing or stale")

        expected = step["expected_artifacts"]
        for artifact_name in expected:
            artifact = Path(artifact_name)
            if not artifact.is_file() or artifact.stat().st_size == 0:
                reasons.append(f"artifact missing or empty: {artifact_name}")
                continue
            current_hash = hash_file(artifact)
            if child.artifact_hashes.get(str(artifact)) != current_hash:
                reasons.append(f"artifact hash missing or stale: {artifact_name}")

        if not review.authenticated or review.verifier != self.policy.required_reviewer:
            reasons.append("authenticated reviewer identity mismatch")
        if review.approval_id != self.policy.required_approval:
            reasons.append("original approval mismatch")
        if review.source_hash != current_source_hash or review.source_hash != child.source_hash:
            reasons.append("review source hash stale")
        if review.artifact_hashes != child.artifact_hashes:
            reasons.append("review artifact hashes stale")
        if not child.target_readback or not review.target_readback:
            reasons.append("target read-back missing")
        return reasons

    def _record_receipt(
        self, db: sqlite3.Connection, kind: str, key: str, payload: Any
    ) -> None:
        db.execute(
            "INSERT OR IGNORE INTO receipts(kind,key,payload_json,created_at) VALUES(?,?,?,?)",
            (kind, key, self._json(payload), self.clock()),
        )

    def _attempt_step(
        self,
        mission_id: str,
        step: dict[str, Any],
        runner: Callable[[dict[str, Any], int], ChildResult],
        verifier: Callable[[dict[str, Any], ChildResult], ReviewReceipt],
        reconcile_effect: Callable[[dict[str, Any], UncertainEffect], ChildResult] | None,
    ) -> str:
        if self._control_status(mission_id) is not None:
            return "controlled"
        mission = self.mission(mission_id)
        if (
            step["action"] not in self.policy.allowed_actions
            or step["action"] not in mission["scope"]
        ):
            return "policy_denied"

        owner = "engine:" + uuid.uuid4().hex
        epoch = self.claim(mission_id, step["key"], owner=owner)
        if epoch is None:
            return "busy"
        current = self.step(mission_id, step["key"])
        effect_key = current.get("side_effect_key")
        effect_binding = self._effect_binding(current) if effect_key else None
        if effect_key and effect_binding:
            effect_status, payload = self._reserve_effect(
                effect_key,
                effect_binding,
                owner,
                allow_reconcile=reconcile_effect is not None,
            )
            if effect_status == "conflict":
                with self._connect() as db:
                    db.execute(
                        """UPDATE steps
                           SET status='effect_conflict',
                               reason='effect key reused with different payload or target',
                               owner=NULL
                           WHERE mission_id=? AND key=? AND owner=? AND claim_epoch=?""",
                        (mission_id, step["key"], owner, epoch),
                    )
                return "effect_conflict"
            if effect_status == "committed":
                child_data = payload.get("child")
                review_data = payload.get("review")
                if not child_data or not review_data:
                    return "busy"
                child = ChildResult(**child_data)
                review = ReviewReceipt(**review_data)
                reasons = self._validate(current, child, review)
                status = "failed" if reasons else "verified"
                reason = "; ".join(reasons) or "deduplicated committed effect"
                with self._connect() as db:
                    db.execute(
                        """UPDATE steps
                           SET status=?,reason=?,owner=NULL,child_json=?,review_json=?
                           WHERE mission_id=? AND key=? AND owner=? AND claim_epoch=?""",
                        (
                            status,
                            reason,
                            self._json(child_data),
                            self._json(review_data),
                            mission_id,
                            step["key"],
                            owner,
                            epoch,
                        ),
                    )
                return status
            if effect_status not in {"reserved", "reconcile"}:
                with self._connect() as db:
                    db.execute(
                        """UPDATE steps SET owner=NULL,status='pending',
                               reason='effect operation already owned or uncertain'
                           WHERE mission_id=? AND key=? AND owner=? AND claim_epoch=?""",
                        (mission_id, step["key"], owner, epoch),
                    )
                return "busy"

        reconcile_only = bool(effect_key and effect_status == "reconcile")
        if reconcile_only:
            attempt = int(current["attempts"])
            with self._connect() as db:
                changed = db.execute(
                    """UPDATE steps SET status='running',
                           reason='fenced read-only effect reconciliation'
                       WHERE mission_id=? AND key=? AND owner=? AND claim_epoch=?
                         AND status IN ('uncertain','pending')""",
                    (mission_id, step["key"], owner, epoch),
                ).rowcount
            if not changed:
                if effect_key:
                    self._restore_uncertain_effect(effect_key, owner)
                self._release_claim(mission_id, step["key"], owner, epoch)
                return "fenced"
            target_key = str(payload.get("target_key") or effect_key)
            try:
                child = reconcile_effect(
                    self.step(mission_id, step["key"]),
                    UncertainEffect(target_key),
                )
            except UncertainEffect as error:
                return self._park_uncertain_effect(
                    mission_id,
                    step["key"],
                    owner,
                    epoch,
                    attempt,
                    effect_key,
                    error.target_key,
                    "external effect remains uncertain after read-only reconciliation",
                )
            except Exception as error:  # noqa: BLE001 - isolate callback failure
                return self._park_callback_exception(
                    mission_id,
                    step["key"],
                    owner,
                    epoch,
                    attempt,
                    effect_key,
                    "reconciler",
                    error,
                )
            except BaseException as error:
                self._park_callback_exception(
                    mission_id,
                    step["key"],
                    owner,
                    epoch,
                    attempt,
                    effect_key,
                    "reconciler",
                    error,
                )
                raise
            with self._connect() as db:
                self._event(
                    db,
                    mission_id,
                    "effect_reconciled",
                    {"key": step["key"], "target_key": target_key},
                )
        else:
            # Preserve the explicit pre-admission control read while the actual
            # control, scope, claim and turn checks commit atomically below.
            if self._control_status(mission_id) is not None:
                if effect_key:
                    self._release_unused_effect(effect_key, owner)
                self._release_claim(mission_id, step["key"], owner, epoch)
                return "controlled"
            admission, attempt = self._reserve_attempt(
                mission_id,
                step["key"],
                step["action"],
                owner,
                epoch,
            )
            if admission != "admitted":
                if effect_key:
                    self._release_unused_effect(effect_key, owner)
                self._release_claim(mission_id, step["key"], owner, epoch)
                return admission

        mission = self.mission(mission_id)
        try:
            if not reconcile_only:
                child = runner(self.step(mission_id, step["key"]), attempt)
        except RetryableError as error:
            next_eligible_at = self.clock() + error.retry_after
            exhausted = attempt >= mission["max_attempts"]
            with self._connect() as db:
                db.execute(
                    """UPDATE steps SET status=?,reason=?,owner=NULL,
                           next_eligible_at=?
                       WHERE mission_id=? AND key=? AND owner=? AND claim_epoch=?
                         AND attempts=?""",
                    (
                        "budget_exhausted" if exhausted else "delayed",
                        (
                            "cumulative attempt ceiling reached"
                            if exhausted
                            else "retry scheduled after backoff"
                        ),
                        next_eligible_at,
                        mission_id,
                        step["key"],
                        owner,
                        epoch,
                        attempt,
                    ),
                )
                self._event(
                    db,
                    mission_id,
                    "backoff",
                    {
                        "key": step["key"],
                        "kind": error.kind,
                        "seconds": error.retry_after,
                        "next_eligible_at": next_eligible_at,
                    },
                )
                if exhausted:
                    self._set_mission_status(db, mission_id, "budget_exhausted")
            if effect_key:
                self._release_effect_for_retry(
                    effect_key, owner, next_eligible_at
                )
            return "budget_exhausted" if exhausted else "delayed"
        except CrashError as error:
            with self._connect() as db:
                db.execute(
                    """UPDATE steps SET status='crashed',checkpoint=?,
                           reason='owned fixture crashed'
                       WHERE mission_id=? AND key=? AND owner=? AND claim_epoch=?
                         AND attempts=?""",
                    (
                        error.checkpoint,
                        mission_id,
                        step["key"],
                        owner,
                        epoch,
                        attempt,
                    ),
                )
                self._set_mission_status(db, mission_id, "checkpointed")
            return "crashed"
        except UncertainEffect as error:
            if reconcile_effect is None:
                return self._park_uncertain_effect(
                    mission_id,
                    step["key"],
                    owner,
                    epoch,
                    attempt,
                    effect_key,
                    error.target_key,
                    "external effect requires reconciliation",
                )
            try:
                child = reconcile_effect(self.step(mission_id, step["key"]), error)
            except UncertainEffect as unresolved:
                return self._park_uncertain_effect(
                    mission_id,
                    step["key"],
                    owner,
                    epoch,
                    attempt,
                    effect_key,
                    unresolved.target_key,
                    "external effect remains uncertain after read-only reconciliation",
                )
            except Exception as reconcile_error:  # noqa: BLE001 - isolate callback failure
                return self._park_callback_exception(
                    mission_id,
                    step["key"],
                    owner,
                    epoch,
                    attempt,
                    effect_key,
                    "reconciler",
                    reconcile_error,
                )
            except BaseException as reconcile_error:
                self._park_callback_exception(
                    mission_id,
                    step["key"],
                    owner,
                    epoch,
                    attempt,
                    effect_key,
                    "reconciler",
                    reconcile_error,
                )
                raise
            with self._connect() as db:
                self._event(
                    db,
                    mission_id,
                    "effect_reconciled",
                    {"key": step["key"], "target_key": error.target_key},
                )
        except Exception as error:  # noqa: BLE001 - isolate callback failure
            return self._park_callback_exception(
                mission_id,
                step["key"],
                owner,
                epoch,
                attempt,
                effect_key,
                "runner",
                error,
            )
        except BaseException as error:
            self._park_callback_exception(
                mission_id,
                step["key"],
                owner,
                epoch,
                attempt,
                effect_key,
                "runner",
                error,
            )
            raise

        if not self.commit_claim(mission_id, step["key"], owner, epoch):
            if effect_key:
                with self._connect() as db:
                    db.execute(
                        """UPDATE operation_state
                           SET status='uncertain',owner=NULL,updated_at=?
                           WHERE kind='effect' AND key=? AND owner=?""",
                        (self.clock(), effect_key, owner),
                    )
            return "fenced"

        try:
            review = verifier(self.step(mission_id, step["key"]), child)
        except Exception as error:  # noqa: BLE001 - isolate callback failure
            return self._park_callback_exception(
                mission_id,
                step["key"],
                owner,
                epoch,
                attempt,
                effect_key,
                "verifier",
                error,
            )
        except BaseException as error:
            self._park_callback_exception(
                mission_id,
                step["key"],
                owner,
                epoch,
                attempt,
                effect_key,
                "verifier",
                error,
            )
            raise
        refreshed = self.step(mission_id, step["key"])
        reasons = self._validate(refreshed, child, review)
        status = "failed" if reasons else "verified"
        reason = "; ".join(reasons)
        payload = {"child": asdict(child), "review": asdict(review)}
        with self._connect() as db:
            changed = db.execute(
                """UPDATE steps SET status=?,reason=?,owner=NULL,child_json=?,
                       review_json=?
                   WHERE mission_id=? AND key=? AND owner=? AND claim_epoch=?
                     AND attempts=?""",
                (
                    status,
                    reason,
                    self._json(payload["child"]),
                    self._json(payload["review"]),
                    mission_id,
                    step["key"],
                    owner,
                    epoch,
                    attempt,
                ),
            ).rowcount
            if not changed:
                if effect_key:
                    db.execute(
                        """UPDATE operation_state
                           SET status='uncertain',owner=NULL,updated_at=?
                           WHERE kind='effect' AND key=? AND owner=?""",
                        (self.clock(), effect_key, owner),
                    )
                return "fenced"
            if effect_key:
                effect_status = "committed" if status == "verified" else "uncertain"
                db.execute(
                    """UPDATE operation_state SET status=?,owner=NULL,
                           payload_json=?,updated_at=?
                       WHERE kind='effect' AND key=? AND binding_json=?
                         AND owner=? AND status='reserved'""",
                    (
                        effect_status,
                        self._json(payload),
                        self.clock(),
                        effect_key,
                        effect_binding,
                        owner,
                    ),
                )
                if status == "verified":
                    self._record_receipt(db, "effect", effect_key, payload)
            self._event(
                db,
                mission_id,
                "step_result",
                {"key": step["key"], "status": status, "reason": reason},
            )
        return status

    def run_until_parked(
        self,
        mission_id: str,
        runner: Callable[[dict[str, Any], int], ChildResult],
        verifier: Callable[[dict[str, Any], ChildResult], ReviewReceipt],
        *,
        reconcile_effect: Callable[[dict[str, Any], UncertainEffect], ChildResult] | None = None,
        capacity_ok: bool = True,
        max_steps: int | None = None,
    ) -> None:
        executed = 0
        visited: set[str] = set()
        while True:
            if self._control_status(mission_id) is not None:
                return
            mission = self.mission(mission_id)
            steps = self._steps(mission_id)
            if steps and all(step["status"] == "verified" for step in steps):
                with self._connect() as db:
                    status = "verified" if self.final_gate(mission_id) else "evidence_stale"
                    self._set_mission_status(db, mission_id, status)
                return
            reconciliation_pending = bool(
                reconcile_effect
                and any(
                    step["status"] == "uncertain" and step.get("side_effect_key")
                    for step in steps
                )
            )
            if (
                mission["turns_used"] >= mission["max_turns"]
                and not reconciliation_pending
            ):
                with self._connect() as db:
                    self._set_mission_status(db, mission_id, "checkpointed")
                return
            if max_steps is not None and executed >= max_steps:
                with self._connect() as db:
                    self._set_mission_status(db, mission_id, "checkpointed")
                return

            selected = False
            for step in steps:
                if step["key"] in visited:
                    continue
                if step["status"] == "uncertain" and not (
                    reconcile_effect and step.get("side_effect_key")
                ):
                    continue
                if step["status"] in {
                    "verified",
                    "failed",
                    "policy_denied",
                    "budget_exhausted",
                    "effect_conflict",
                    "running",
                    "crashed",
                }:
                    continue
                if (
                    step["status"] == "delayed"
                    and float(step["next_eligible_at"]) > self.clock()
                ):
                    visited.add(step["key"])
                    continue
                if not self._deps_verified(mission_id, step["depends_on"]):
                    continue
                if (
                    step["action"] not in self.policy.allowed_actions
                    or step["action"] not in mission["scope"]
                ):
                    with self._connect() as db:
                        db.execute(
                            "UPDATE steps SET status='policy_denied',reason='action outside immutable policy/scope' WHERE mission_id=? AND key=?",
                            (mission_id, step["key"]),
                        )
                        self._event(db, mission_id, "policy_denied", {"key": step["key"], "action": step["action"]})
                    visited.add(step["key"])
                    continue
                is_reconciliation = bool(
                    step["status"] == "uncertain"
                    and reconcile_effect
                    and step.get("side_effect_key")
                )
                if not capacity_ok and not is_reconciliation:
                    with self._connect() as db:
                        db.execute(
                            "UPDATE steps SET status='delayed',reason='capacity pressure' WHERE mission_id=? AND key=?",
                            (mission_id, step["key"]),
                        )
                        self._set_mission_status(db, mission_id, "delayed")
                    return
                if self._control_status(mission_id) is not None:
                    return
                mission = self.mission(mission_id)
                if (
                    mission["turns_used"] >= mission["max_turns"]
                    and not is_reconciliation
                ):
                    with self._connect() as db:
                        self._set_mission_status(db, mission_id, "checkpointed")
                    return
                visited.add(step["key"])
                result = self._attempt_step(
                    mission_id, step, runner, verifier, reconcile_effect
                )
                if result not in {"busy", "controlled", "turn_exhausted"}:
                    executed += 1
                selected = True
                if self._control_status(mission_id) is not None:
                    return
                break
            if selected:
                continue

            remaining = [
                step
                for step in self._steps(mission_id)
                if step["status"] not in {"verified", "policy_denied"}
            ]
            with self._connect() as db:
                if any(
                    step["status"] == "budget_exhausted" for step in remaining
                ):
                    self._set_mission_status(db, mission_id, "budget_exhausted")
                elif any(step["status"] == "failed" for step in remaining):
                    self._set_mission_status(db, mission_id, "failed")
                elif any(
                    step["status"] == "effect_conflict" for step in remaining
                ):
                    self._set_mission_status(db, mission_id, "effect_conflict")
                elif any(
                    step["status"] == "delayed"
                    and float(step["next_eligible_at"]) > self.clock()
                    for step in remaining
                ):
                    self._set_mission_status(db, mission_id, "delayed")
                elif any(
                    step["status"] == "verified"
                    and not self.revalidate(mission_id, step["key"])
                    for step in self._steps(mission_id)
                ):
                    self._set_mission_status(db, mission_id, "evidence_stale")
                elif remaining:
                    self._set_mission_status(db, mission_id, "checkpointed")
                else:
                    self._set_mission_status(db, mission_id, "partial_blocked")
            return

    def run_all(
        self,
        work: Sequence[tuple[str, Callable[[dict[str, Any], int], ChildResult]]],
        verifier: Callable[[dict[str, Any], ChildResult], ReviewReceipt],
    ) -> None:
        for mission_id, runner in work:
            self.run_until_parked(mission_id, runner, verifier)

    def revalidate(self, mission_id: str, key: str) -> bool:
        step = self.step(mission_id, key)
        if step["status"] != "verified" or not step["child"] or not step["review"]:
            return False
        child = ChildResult(**step["child"])
        review = ReviewReceipt(**step["review"])
        return not self._validate(step, child, review)

    def final_gate(self, mission_id: str) -> bool:
        if self._control_status(mission_id) is not None:
            return False
        steps = self._steps(mission_id)
        return bool(steps) and all(
            step["status"] == "verified" and self.revalidate(mission_id, step["key"])
            for step in steps
        )

    def receipt_count(self, kind: str, key: str) -> int:
        with self._connect() as db:
            return int(
                db.execute(
                    "SELECT COUNT(*) FROM receipts WHERE kind=? AND key=?", (kind, key)
                ).fetchone()[0]
            )

    def recorded_backoffs(self, mission_id: str) -> list[float]:
        with self._connect() as db:
            rows = db.execute(
                "SELECT payload_json FROM events WHERE mission_id=? AND kind='backoff' ORDER BY id",
                (mission_id,),
            ).fetchall()
        return [float(json.loads(row[0])["seconds"]) for row in rows]

    def select_route(
        self, candidates: Sequence[tuple[str, bool]], *, capacity_ok: bool
    ) -> str | None:
        if not capacity_ok:
            return None
        for route, compatible in candidates:
            if compatible and route in self.policy.approved_routes:
                return route
        return None

    def choose_provider_route(self, primary: str, fallback: str, attempt: int) -> str | None:
        route = primary if attempt <= 1 else fallback
        return route if route in self.policy.approved_routes else None

    def pause(self, mission_id: str) -> None:
        with self._connect() as db:
            db.execute(
                "UPDATE missions SET paused=1,status='paused',updated_at=? WHERE id=?",
                (self.clock(), mission_id),
            )
            self._event(db, mission_id, "paused", {})

    def resume(self, mission_id: str, *, authorized: bool) -> bool:
        """Resume only through an explicit authorized operator action."""
        if not authorized:
            return False
        mission = self.mission(mission_id)
        if mission["cancelled"]:
            return False
        if mission["expires_at"] is not None and self.clock() > mission["expires_at"]:
            with self._connect() as db:
                self._set_mission_status(db, mission_id, "authorization_expired")
            return False
        with self._connect() as db:
            changed = db.execute(
                """UPDATE missions SET paused=0,status='admitted',updated_at=?
                   WHERE id=? AND paused=1 AND cancelled=0""",
                (self.clock(), mission_id),
            ).rowcount
            if changed:
                self._event(db, mission_id, "resumed", {"authorized": True})
        return bool(changed)

    def watchdog_tick(self, mission_id: str, *, external_process_alive: bool) -> None:
        with self._connect() as db:
            db.execute(
                "UPDATE missions SET external_process_alive=?,updated_at=? WHERE id=?",
                (int(external_process_alive), self.clock(), mission_id),
            )
            self._event(
                db,
                mission_id,
                "watchdog_observation",
                {"external_process_alive": bool(external_process_alive)},
            )

    def commit_action_then_notify(
        self,
        mission_id: str,
        action_key: str,
        incident_key: str,
        action: Callable[[], Any],
        notify: Callable[[], Any],
    ) -> None:
        """Commit one legacy execute/notify-scoped callback, then its notice.

        Historical callers used ``notify`` for the pair while the immutable
        external compatibility suite used ``execute``.  Supporting those two
        local prototype scopes does not grant arbitrary typed action authority
        and is not a production authorization boundary.
        """
        owner = "operation:" + uuid.uuid4().hex
        action_binding = self._json({"action_key": action_key})
        now = self.clock()
        with self._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            mission = db.execute(
                "SELECT * FROM missions WHERE id=?", (mission_id,)
            ).fetchone()
            if mission is None:
                raise KeyError(mission_id)
            scope = json.loads(mission["scope_json"])
            if bool(mission["paused"]) or bool(mission["cancelled"]):
                return
            if (
                mission["expires_at"] is not None
                and self.clock() > float(mission["expires_at"])
            ):
                self._set_mission_status(db, mission_id, "authorization_expired")
                return
            helper_scope = "notify" if "notify" in scope else "execute" if "execute" in scope else None
            if helper_scope is None or helper_scope not in self.policy.allowed_actions:
                return
            action_state = db.execute(
                "SELECT * FROM operation_state WHERE kind='action' AND key=?",
                (action_key,),
            ).fetchone()
            if action_state is not None:
                if action_state["binding_json"] != action_binding:
                    raise ValueError("action key reused with a different binding")
                inserted = False
                if action_state["status"] != "committed":
                    return
            else:
                if int(mission["turns_used"]) >= int(mission["max_turns"]):
                    return
                db.execute(
                    """INSERT INTO operation_state(
                           kind,key,binding_json,status,owner,created_at,updated_at
                       ) VALUES('action',?,?,'reserved',?,?,?)""",
                    (action_key, action_binding, owner, now, now),
                )
                db.execute(
                    """UPDATE missions SET turns_used=turns_used+1,updated_at=?
                       WHERE id=?""",
                    (now, mission_id),
                )
                inserted = True
        if inserted:
            try:
                result = action()
            except BaseException:
                with self._connect() as db:
                    db.execute(
                        """UPDATE operation_state
                           SET status='uncertain',owner=NULL,updated_at=?
                           WHERE kind='action' AND key=? AND owner=?""",
                        (self.clock(), action_key, owner),
                    )
                raise
            with self._connect() as db:
                changed = db.execute(
                    """UPDATE operation_state SET status='committed',owner=NULL,
                           payload_json=?,updated_at=?
                       WHERE kind='action' AND key=? AND owner=?
                         AND status='reserved'""",
                    (
                        self._json({"result": str(result)}),
                        self.clock(),
                        action_key,
                        owner,
                    ),
                ).rowcount
                if not changed:
                    return
                self._record_receipt(
                    db, "action", action_key, {"result": str(result)}
                )

        if self._control_status(mission_id) is not None:
            return
        mission_state = self.mission(mission_id)
        if helper_scope not in self.policy.allowed_actions or helper_scope not in mission_state["scope"]:
            return
        with self._connect() as db:
            self._record_receipt(db, "incident", incident_key, {"mission_id": mission_id})

        delivery_binding = self._json(
            {"incident_key": incident_key, "mission_id": mission_id}
        )
        while True:
            if self._control_status(mission_id) is not None:
                return
            delivery_owner = "notification:" + uuid.uuid4().hex
            now = self.clock()
            with self._connect() as db:
                inserted = db.execute(
                    """INSERT OR IGNORE INTO operation_state(
                           kind,key,binding_json,status,owner,created_at,updated_at
                       ) VALUES('notification',?,?,'reserved',?,?,?)""",
                    (incident_key, delivery_binding, delivery_owner, now, now),
                ).rowcount
                state = db.execute(
                    """SELECT * FROM operation_state
                       WHERE kind='notification' AND key=?""",
                    (incident_key,),
                ).fetchone()
                if state is None or state["binding_json"] != delivery_binding:
                    raise ValueError(
                        "incident key reused with a different mission binding"
                    )
                if not inserted and state["status"] == "committed":
                    return
                if (
                    not inserted
                    and state["status"] == "retry_scheduled"
                    and float(state["next_eligible_at"]) <= now
                ):
                    inserted = db.execute(
                        """UPDATE operation_state
                           SET status='reserved',owner=?,updated_at=?
                           WHERE kind='notification' AND key=?
                             AND status='retry_scheduled'
                             AND next_eligible_at<=?""",
                        (delivery_owner, now, incident_key, now),
                    ).rowcount
                if not inserted:
                    return
                attempt = int(state["attempts"]) + 1
            if self._control_status(mission_id) is not None:
                with self._connect() as db:
                    db.execute(
                        """DELETE FROM operation_state
                           WHERE kind='notification' AND key=? AND owner=?
                             AND status='reserved' AND attempts=0""",
                        (incident_key, delivery_owner),
                    )
                    db.execute(
                        """UPDATE operation_state
                           SET status='retry_scheduled',owner=NULL,updated_at=?
                           WHERE kind='notification' AND key=? AND owner=?
                             AND status='reserved'""",
                        (self.clock(), incident_key, delivery_owner),
                    )
                return
            try:
                notify()
                with self._connect() as db:
                    changed = db.execute(
                        """UPDATE operation_state SET status='committed',owner=NULL,
                               attempts=?,payload_json=?,updated_at=?
                           WHERE kind='notification' AND key=? AND owner=?
                             AND status='reserved'""",
                        (
                            attempt,
                            self._json({"attempt": attempt}),
                            self.clock(),
                            incident_key,
                            delivery_owner,
                        ),
                    ).rowcount
                    if changed:
                        self._record_receipt(
                            db,
                            "notification",
                            incident_key,
                            {"attempt": attempt},
                        )
                return
            except RetryableError as error:
                exhausted = attempt >= 2
                next_eligible_at = self.clock() + error.retry_after
                with self._connect() as db:
                    db.execute(
                        """UPDATE operation_state SET status=?,owner=NULL,
                               attempts=?,next_eligible_at=?,updated_at=?
                           WHERE kind='notification' AND key=? AND owner=?
                             AND status='reserved'""",
                        (
                            "failed" if exhausted else "retry_scheduled",
                            attempt,
                            next_eligible_at,
                            self.clock(),
                            incident_key,
                            delivery_owner,
                        ),
                    )
                if exhausted:
                    raise
                if error.retry_after > 0:
                    return

    def idle_tick(self) -> dict[str, Any]:
        with self._connect() as db:
            eligible = int(
                db.execute(
                    """SELECT COUNT(*) FROM steps s JOIN missions m ON m.id=s.mission_id
                       WHERE s.status IN ('pending','delayed') AND m.paused=0 AND m.cancelled=0"""
                ).fetchone()[0]
            )
        return {"eligible": eligible, "inference_calls": 0, "script_only": True}

    def save_checkpoint(self, mission_id: str, key: str, checkpoint: str) -> None:
        with self._connect() as db:
            db.execute(
                "UPDATE steps SET checkpoint=? WHERE mission_id=? AND key=?",
                (checkpoint, mission_id, key),
            )
            self._event(db, mission_id, "checkpoint", {"key": key, "checkpoint": checkpoint})

    def sanitized_events(self, mission_id: str) -> str:
        with self._connect() as db:
            rows = db.execute(
                "SELECT kind,payload_json FROM events WHERE mission_id=? ORDER BY id",
                (mission_id,),
            ).fetchall()
        text = self._json([{"kind": row[0], "payload": json.loads(row[1])} for row in rows])
        return re.sub(r"(?i)(secret|token|password)=([^\s,;]+)", r"\1=[REDACTED]", text)
