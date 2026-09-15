"""Independent local-only review of task t_834aebec; no network or production actions."""
from pathlib import Path
from afz_autopilot.core import MissionEngine, Policy, ChildResult, ReviewReceipt, RetryableError, UncertainEffect, hash_file

def setup(tmp_path, **admission):
    now = [1000.0]
    engine = MissionEngine(tmp_path / 'review.sqlite3', policy=Policy(), clock=lambda: now[0])
    mission = engine.admit('review-fixture', scope=['execute', 'upload'], **admission)
    return engine, mission, now

def add(engine, mission, root, key, deps=(), effect=None, shared=None):
    source, artifact = root / ((shared or key) + '.src'), root / ((shared or key) + '.artifact')
    source.write_text('fixed fixture source', encoding='utf-8')
    engine.add_step(mission, key, action='execute', source_path=source, expected_artifacts=[artifact], required_tests=1, depends_on=deps, side_effect_key=effect)
    return source, artifact

def good(step, attempt):
    artifact = Path(step['expected_artifacts'][0])
    artifact.write_text('fixed fixture result', encoding='utf-8')
    return ChildResult(0, 1, 0, hash_file(Path(step['source_path'])), {str(artifact): hash_file(artifact)}, 'fixture', True)

def verify(step, child):
    return ReviewReceipt('independent-reviewer', True, child.source_hash, child.artifact_hashes, 'original-approval', True)

def test_retry_after_prevents_early_retry(tmp_path):
    e, m, now = setup(tmp_path); add(e, m, tmp_path, 'retry'); calls = []
    def run(s, a):
        calls.append(now[0])
        if a == 1: raise RetryableError('rate_limit', retry_after=60)
        return good(s, a)
    e.run_until_parked(m, run, verify)
    assert calls == [1000.0], 'Retry-After must defer another attempt until clock advances'

def test_pause_during_step_stops_next_dispatch(tmp_path):
    e, m, _ = setup(tmp_path); add(e, m, tmp_path, 'one'); add(e, m, tmp_path, 'two', deps=['one']); seen = []
    def run(s, a):
        seen.append(s['key'])
        if s['key'] == 'one': e.pause(m)
        return good(s, a)
    e.run_until_parked(m, run, verify)
    assert seen == ['one'], 'Operator pause must prevent subsequent dispatch'
    assert e.mission(m)['status'] == 'paused'

def test_existing_live_owner_is_not_adopted(tmp_path):
    e, m, _ = setup(tmp_path); add(e, m, tmp_path, 'owned'); e.claim(m, 'owned', owner='external-live-owner'); seen = []
    def run(s, a):
        seen.append(s['key']); return good(s, a)
    e.run_until_parked(m, run, verify)
    assert seen == [], 'Controller must not run another owners claimed step'
    assert e.step(m, 'owned')['owner'] == 'external-live-owner'

def test_stale_parent_receipt_blocks_dependent(tmp_path):
    e, m, _ = setup(tmp_path); source, _ = add(e, m, tmp_path, 'parent'); add(e, m, tmp_path, 'child', deps=['parent'])
    e.run_until_parked(m, good, verify, max_steps=1); source.write_text('changed after verification', encoding='utf-8'); seen = []
    def run(s, a):
        seen.append(s['key']); return good(s, a)
    e.run_until_parked(m, run, verify)
    assert 'child' not in seen, 'Dependency eligibility must revalidate parent evidence'

def test_effect_receipt_prevents_repeated_operation(tmp_path):
    e, m, _ = setup(tmp_path)
    add(e, m, tmp_path, 'first', effect='same-operation', shared='shared')
    add(e, m, tmp_path, 'second', effect='same-operation', shared='shared'); seen = []
    def run(s, a):
        seen.append(s['key']); return good(s, a)
    e.run_until_parked(m, run, verify)
    assert len(seen) == 1, 'Durable effect key must be checked before repeating operation'

def test_notification_is_not_resent_after_delivery_receipt(tmp_path):
    e, m, _ = setup(tmp_path); actions = []; notices = []
    for _ in range(2):
        e.commit_action_then_notify(m, 'one-action', 'one-incident', lambda: actions.append('action'), lambda: notices.append('notice'))
    assert len(actions) == 1
    assert len(notices) == 1, 'Successful notification receipt must prevent repeat delivery'

def test_fenced_attempt_cannot_commit_old_results(tmp_path):
    e, m, _ = setup(tmp_path); add(e, m, tmp_path, 'fenced')
    def run(s, a):
        child = good(s, a)
        assert e.recover_stale_claim(m, 'fenced', heartbeat_stale=True, process_alive=False, owner=s['owner'])
        assert e.claim(m, 'fenced', owner='replacement-owner') is not None
        return child
    e.run_until_parked(m, run, verify)
    assert e.step(m, 'fenced')['status'] != 'verified', 'Actual result commit must enforce original owner epoch'
    assert e.step(m, 'fenced')['owner'] == 'replacement-owner'

def test_authorization_expiry_is_checked_between_steps(tmp_path):
    e, m, now = setup(tmp_path, expires_at=1001.0)
    add(e, m, tmp_path, 'one'); add(e, m, tmp_path, 'two', deps=['one']); seen = []
    def run(s, a):
        seen.append(s['key'])
        if s['key'] == 'one': now[0] = 1002.0
        return good(s, a)
    e.run_until_parked(m, run, verify)
    assert seen == ['one'], 'Expired mission authorization must prevent next dispatch'

def test_uncertain_branch_does_not_stop_independent_safe_work(tmp_path):
    e, m, _ = setup(tmp_path); add(e, m, tmp_path, 'uncertain'); add(e, m, tmp_path, 'safe'); seen = []
    def run(s, a):
        seen.append(s['key'])
        if s['key'] == 'uncertain': raise UncertainEffect('do-not-repeat')
        return good(s, a)
    e.run_until_parked(m, run, verify)
    assert seen == ['uncertain', 'safe'], 'Park uncertain side effects but continue independent authorized work'
    assert e.step(m, 'uncertain')['status'] == 'uncertain'
