"""Positive, restart, exception, and process-contention coverage for R3."""
from __future__ import annotations

import multiprocessing
import time
from pathlib import Path

import pytest

from afz_autopilot.core import (
    ChildResult,
    MissionEngine,
    Policy,
    ReviewReceipt,
    UncertainEffect,
    hash_file,
)


def _add(engine: MissionEngine, mission: str, root: Path, key: str, *, effect: str | None = None) -> None:
    source = root / f"{key}.src"
    artifact = root / f"{key}.artifact"
    source.write_text("r3 fixture source", encoding="utf-8")
    engine.add_step(
        mission,
        key,
        action="execute",
        source_path=source,
        expected_artifacts=[artifact],
        required_tests=1,
        side_effect_key=effect,
    )


def _good(step: dict, attempt: int) -> ChildResult:
    artifact = Path(step["expected_artifacts"][0])
    artifact.write_text(f"artifact:{attempt}", encoding="utf-8")
    return ChildResult(
        0,
        1,
        0,
        hash_file(Path(step["source_path"])),
        {str(artifact): hash_file(artifact)},
        "r3 fixture",
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


def _process_contender(
    db_path: str,
    mission: str,
    gate: multiprocessing.synchronize.Event,
    audit_path: str,
) -> None:
    engine = MissionEngine(db_path, policy=Policy(), clock=time.time)
    if not gate.wait(10):
        raise RuntimeError("contention gate timed out")

    def run(step: dict, attempt: int) -> ChildResult:
        with Path(audit_path).open("a", encoding="utf-8") as handle:
            handle.write(f"{multiprocessing.current_process().pid}:{step['key']}\n")
        time.sleep(0.2)
        return _good(step, attempt)

    engine.run_until_parked(mission, run, _verify)


class _FenceAfterReconcileReservation(MissionEngine):
    def __init__(self, *args, mission: str, step_key: str, **kwargs) -> None:
        self._fixture_mission = mission
        self._fixture_step_key = step_key
        self.fresh_release_calls = 0
        super().__init__(*args, **kwargs)

    def _reserve_effect(self, key: str, binding: str, owner: str, **kwargs):
        status, payload = super()._reserve_effect(key, binding, owner, **kwargs)
        if status == "reconcile":
            assert self.recover_stale_claim(
                self._fixture_mission,
                self._fixture_step_key,
                heartbeat_stale=True,
                process_alive=False,
                owner=owner,
            )
        return status, payload

    def _release_unused_effect(self, key: str, owner: str) -> None:
        self.fresh_release_calls += 1
        super()._release_unused_effect(key, owner)


def test_action_helper_allows_active_notification_scope_once(tmp_path: Path) -> None:
    engine = MissionEngine(tmp_path / "state.sqlite3", policy=Policy(), clock=lambda: 1000.0)
    mission = engine.admit("r3-action-positive", scope=["notify"])
    actions: list[str] = []
    notices: list[str] = []

    for _ in range(2):
        engine.commit_action_then_notify(
            mission,
            "action-key",
            "incident-key",
            lambda: actions.append("action"),
            lambda: notices.append("notice"),
        )

    assert actions == ["action"]
    assert notices == ["notice"]
    assert engine.mission(mission)["turns_used"] == 1


@pytest.mark.parametrize("scope,max_turns", [(["upload"], 2), (["notify"], 1)])
def test_action_helper_denies_missing_scope_or_exhausted_budget(
    tmp_path: Path, scope: list[str], max_turns: int
) -> None:
    engine = MissionEngine(tmp_path / "state.sqlite3", policy=Policy(), clock=lambda: 1000.0)
    mission = engine.admit("r3-action-denied", scope=scope, max_turns=max_turns)
    if scope == ["notify"]:
        engine.commit_action_then_notify(
            mission,
            "used-action",
            "used-incident",
            lambda: None,
            lambda: None,
        )
    callbacks: list[str] = []

    engine.commit_action_then_notify(
        mission,
        "denied-action",
        "denied-incident",
        lambda: callbacks.append("action"),
        lambda: callbacks.append("notice"),
    )

    assert callbacks == []


def test_unknown_restart_reconciliation_stays_parked_without_replay(tmp_path: Path) -> None:
    db_path = tmp_path / "state.sqlite3"
    engine = MissionEngine(db_path, policy=Policy(), clock=lambda: 1000.0)
    mission = engine.admit("r3-unknown-reconcile", scope=["execute"])
    _add(engine, mission, tmp_path, "uncertain", effect="target-1")
    _add(engine, mission, tmp_path, "independent")
    effects: list[str] = []

    def first_run(step: dict, attempt: int) -> ChildResult:
        effects.append(step["key"])
        if step["key"] == "uncertain":
            _good(step, attempt)
            raise UncertainEffect("target-1")
        return _good(step, attempt)

    engine.run_until_parked(mission, first_run, _verify, max_steps=1)
    restarted = MissionEngine(db_path, policy=Policy(), clock=lambda: 1000.0)
    reconciliations: list[str] = []

    def unknown(step: dict, error: UncertainEffect) -> ChildResult:
        reconciliations.append(error.target_key)
        raise UncertainEffect(error.target_key)

    def continue_without_replay(step: dict, attempt: int) -> ChildResult:
        assert step["key"] != "uncertain", "uncertain effect was replayed"
        effects.append(step["key"])
        return _good(step, attempt)

    restarted.run_until_parked(
        mission,
        continue_without_replay,
        _verify,
        reconcile_effect=unknown,
    )

    assert effects == ["uncertain", "independent"]
    assert reconciliations == ["target-1"]
    assert restarted.step(mission, "uncertain")["status"] == "uncertain"
    assert restarted.step(mission, "uncertain")["owner"] is None


def test_fenced_reconciliation_never_uses_fresh_reservation_release(tmp_path: Path) -> None:
    db_path = tmp_path / "state.sqlite3"
    engine = MissionEngine(db_path, policy=Policy(), clock=lambda: 1000.0)
    mission = engine.admit("r3-reconcile-fence", scope=["execute"])
    _add(engine, mission, tmp_path, "uncertain", effect="durable-target")
    effects: list[str] = []

    def lose_response(step: dict, attempt: int) -> ChildResult:
        effects.append(step["key"])
        _good(step, attempt)
        raise UncertainEffect("durable-target")

    engine.run_until_parked(mission, lose_response, _verify)
    fenced = _FenceAfterReconcileReservation(
        db_path,
        policy=Policy(),
        clock=lambda: 1000.0,
        mission=mission,
        step_key="uncertain",
    )
    fenced.run_until_parked(
        mission,
        lambda step, attempt: pytest.fail("uncertain effect was replayed"),
        _verify,
        reconcile_effect=lambda step, error: pytest.fail("fenced callback ran"),
    )

    assert fenced.fresh_release_calls == 0
    assert fenced.step(mission, "uncertain")["status"] == "pending"

    restarted = MissionEngine(db_path, policy=Policy(), clock=lambda: 1000.0)
    reconciled: list[str] = []

    def read_back(step: dict, error: UncertainEffect) -> ChildResult:
        reconciled.append(error.target_key)
        return _good(step, 1)

    restarted.run_until_parked(
        mission,
        lambda step, attempt: pytest.fail("uncertain effect was replayed"),
        _verify,
        reconcile_effect=read_back,
    )
    assert effects == ["uncertain"]
    assert reconciled == ["durable-target"]
    assert restarted.final_gate(mission)


def test_unexpected_exception_is_sanitized_and_releases_matching_claim(tmp_path: Path) -> None:
    engine = MissionEngine(tmp_path / "state.sqlite3", policy=Policy(), clock=lambda: 1000.0)
    mission = engine.admit("r3-exception-evidence", scope=["execute"])
    _add(engine, mission, tmp_path, "broken")
    _add(engine, mission, tmp_path, "safe")

    def run(step: dict, attempt: int) -> ChildResult:
        if step["key"] == "broken":
            raise ValueError("token=should-not-survive")
        return _good(step, attempt)

    engine.run_until_parked(mission, run, _verify)

    assert engine.step(mission, "broken")["owner"] is None
    assert engine.step(mission, "safe")["status"] == "verified"
    evidence = engine.sanitized_events(mission)
    assert "should-not-survive" not in evidence
    assert "token=[REDACTED]" in evidence


def test_disposable_processes_share_one_remaining_turn(tmp_path: Path) -> None:
    db_path = tmp_path / "state.sqlite3"
    audit_path = tmp_path / "executions.txt"
    engine = MissionEngine(db_path, policy=Policy(), clock=time.time)
    mission = engine.admit("r3-process-budget", scope=["execute"], max_turns=1)
    _add(engine, mission, tmp_path, "one")
    _add(engine, mission, tmp_path, "two")

    context = multiprocessing.get_context("spawn")
    gate = context.Event()
    processes = [
        context.Process(
            target=_process_contender,
            args=(str(db_path), mission, gate, str(audit_path)),
        )
        for _ in range(2)
    ]
    try:
        for process in processes:
            process.start()
        gate.set()
        for process in processes:
            process.join(15)
    finally:
        for process in processes:
            if process.is_alive():
                process.terminate()
        for process in processes:
            process.join(5)

    assert [process.exitcode for process in processes] == [0, 0]
    executions = audit_path.read_text(encoding="utf-8").splitlines()
    assert len(executions) == 1
    assert engine.mission(mission)["turns_used"] == 1
