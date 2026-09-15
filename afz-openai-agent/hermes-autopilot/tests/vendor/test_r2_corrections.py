"""Positive, restart, migration, and process-concurrency coverage for R2."""
from __future__ import annotations

import multiprocessing
import sqlite3
import time
from pathlib import Path

from afz_autopilot.core import (
    ChildResult,
    MissionEngine,
    Policy,
    RetryableError,
    ReviewReceipt,
    hash_file,
)


def _good(step: dict, attempt: int) -> ChildResult:
    artifact = Path(step["expected_artifacts"][0])
    artifact.write_text(f"artifact:{attempt}", encoding="utf-8")
    return ChildResult(
        0,
        step["required_tests"],
        0,
        hash_file(Path(step["source_path"])),
        {str(artifact): hash_file(artifact)},
        "positive fixture",
        True,
    )


def _verify(step: dict, child: ChildResult) -> ReviewReceipt:
    return ReviewReceipt(
        "independent-reviewer",
        True,
        child.source_hash,
        child.artifact_hashes,
        "original-approval",
        True,
    )


def _contend(
    db_path: str,
    mission_id: str,
    gate: multiprocessing.synchronize.Event,
    audit_path: str,
) -> None:
    engine = MissionEngine(db_path, policy=Policy(), clock=time.time)
    if not gate.wait(10):
        raise RuntimeError("contention gate timed out")

    def runner(step: dict, attempt: int) -> ChildResult:
        with Path(audit_path).open("a", encoding="utf-8") as handle:
            handle.write(f"{multiprocessing.current_process().pid}:{step['key']}\n")
        time.sleep(0.2)
        return _good(step, attempt)

    engine.run_until_parked(mission_id, runner, _verify)


def _add(
    engine: MissionEngine,
    mission_id: str,
    root: Path,
    key: str,
    *,
    depends_on: tuple[str, ...] = (),
    effect: str | None = None,
    shared: str | None = None,
) -> tuple[Path, Path]:
    stem = shared or key
    source = root / f"{stem}.src"
    artifact = root / f"{stem}.artifact"
    source.write_text("r2 fixture source", encoding="utf-8")
    engine.add_step(
        mission_id,
        key,
        depends_on=depends_on,
        action="execute",
        source_path=source,
        expected_artifacts=[artifact],
        required_tests=1,
        side_effect_key=effect,
    )
    return source, artifact


def test_retry_deadline_survives_restart_and_eventually_progresses(tmp_path: Path):
    db_path = tmp_path / "state.sqlite3"
    now = [1000.0]
    engine = MissionEngine(db_path, policy=Policy(), clock=lambda: now[0])
    mission = engine.admit("r2-restart", scope=["execute"])
    _add(engine, mission, tmp_path, "retry")
    calls: list[float] = []

    def runner(step: dict, attempt: int) -> ChildResult:
        calls.append(now[0])
        if attempt == 1:
            raise RetryableError("rate_limit", retry_after=60)
        return _good(step, attempt)

    engine.run_until_parked(mission, runner, _verify)
    assert calls == [1000.0]
    assert engine.step(mission, "retry")["next_eligible_at"] == 1060.0

    now[0] = 1059.0
    restarted = MissionEngine(db_path, policy=Policy(), clock=lambda: now[0])
    restarted.run_until_parked(mission, runner, _verify)
    assert calls == [1000.0]

    now[0] = 1060.0
    restarted.run_until_parked(mission, runner, _verify)
    assert calls == [1000.0, 1060.0]
    assert restarted.step(mission, "retry")["status"] == "verified"
    assert restarted.step(mission, "retry")["attempts"] == 2


def test_pause_requires_explicit_authorized_resume(tmp_path: Path):
    engine = MissionEngine(tmp_path / "state.sqlite3", policy=Policy(), clock=lambda: 1.0)
    mission = engine.admit("r2-resume", scope=["execute"])
    _add(engine, mission, tmp_path, "one")
    _add(engine, mission, tmp_path, "two", depends_on=("one",))
    seen: list[str] = []

    def runner(step: dict, attempt: int) -> ChildResult:
        seen.append(step["key"])
        if step["key"] == "one":
            engine.pause(mission)
        return _good(step, attempt)

    engine.run_until_parked(mission, runner, _verify)
    engine.watchdog_tick(mission, external_process_alive=False)
    assert not engine.resume(mission, authorized=False)
    engine.run_until_parked(mission, runner, _verify)
    assert seen == ["one"]
    assert engine.resume(mission, authorized=True)
    engine.run_until_parked(mission, runner, _verify)
    assert seen == ["one", "two"]
    assert engine.final_gate(mission)


def test_effect_key_rejects_different_payload_or_target(tmp_path: Path):
    engine = MissionEngine(tmp_path / "state.sqlite3", policy=Policy(), clock=lambda: 1.0)
    mission = engine.admit("r2-effect-conflict", scope=["execute"])
    _add(engine, mission, tmp_path, "first", effect="shared-key")
    _add(engine, mission, tmp_path, "second", effect="shared-key")
    seen: list[str] = []

    def runner(step: dict, attempt: int) -> ChildResult:
        seen.append(step["key"])
        return _good(step, attempt)

    engine.run_until_parked(mission, runner, _verify)
    assert seen == ["first"]
    assert engine.step(mission, "second")["status"] == "effect_conflict"


def test_notification_retry_is_scheduled_and_delivery_stays_deduplicated(tmp_path: Path):
    now = [1000.0]
    engine = MissionEngine(
        tmp_path / "state.sqlite3", policy=Policy(), clock=lambda: now[0]
    )
    mission = engine.admit("r2-notification", scope=["notify"])
    actions: list[str] = []
    notices: list[float] = []

    def notify() -> None:
        notices.append(now[0])
        if len(notices) == 1:
            raise RetryableError("notification", retry_after=10)

    engine.commit_action_then_notify(
        mission,
        "action",
        "incident",
        lambda: actions.append("done"),
        notify,
    )
    engine.commit_action_then_notify(
        mission,
        "action",
        "incident",
        lambda: actions.append("duplicate"),
        notify,
    )
    assert actions == ["done"]
    assert notices == [1000.0]

    now[0] = 1010.0
    engine.commit_action_then_notify(
        mission,
        "action",
        "incident",
        lambda: actions.append("duplicate"),
        notify,
    )
    engine.commit_action_then_notify(
        mission,
        "action",
        "incident",
        lambda: actions.append("duplicate"),
        notify,
    )
    assert actions == ["done"]
    assert notices == [1000.0, 1010.0]
    assert engine.receipt_count("notification", "incident") == 1


def test_two_processes_execute_one_claim_and_one_effect(tmp_path: Path):
    db_path = tmp_path / "state.sqlite3"
    audit_path = tmp_path / "executions.txt"
    engine = MissionEngine(db_path, policy=Policy(), clock=time.time)
    mission = engine.admit("r2-process-contention", scope=["execute"])
    _add(engine, mission, tmp_path, "first", effect="one-effect", shared="shared")
    _add(engine, mission, tmp_path, "second", effect="one-effect", shared="shared")

    context = multiprocessing.get_context("spawn")
    gate = context.Event()
    processes = [
        context.Process(
            target=_contend,
            args=(str(db_path), mission, gate, str(audit_path)),
        )
        for _ in range(2)
    ]
    for process in processes:
        process.start()
    gate.set()
    for process in processes:
        process.join(15)

    assert [process.exitcode for process in processes] == [0, 0]
    assert len(audit_path.read_text(encoding="utf-8").splitlines()) == 1
    assert engine.step(mission, "first")["status"] == "verified"
    assert engine.step(mission, "second")["status"] == "verified"
    assert engine.receipt_count("effect", "one-effect") == 1


def test_existing_database_receives_additive_retry_deadline_migration(tmp_path: Path):
    db_path = tmp_path / "legacy.sqlite3"
    with sqlite3.connect(db_path) as db:
        db.execute(
            """CREATE TABLE steps (
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
                PRIMARY KEY (mission_id, key)
            )"""
        )

    MissionEngine(db_path, policy=Policy(), clock=lambda: 1.0)
    with sqlite3.connect(db_path) as db:
        columns = {row[1] for row in db.execute("PRAGMA table_info(steps)")}
    assert "next_eligible_at" in columns
