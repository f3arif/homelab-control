"""External R2 behavioral checks; only disposable fixtures, no network/model calls."""
import inspect
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import pytest
from afz_autopilot.core import MissionEngine, Policy, ChildResult, ReviewReceipt, UncertainEffect, hash_file

def setup(root, **admission):
    now = [1000.0]
    engine = MissionEngine(root/'extended.sqlite3', policy=Policy(), clock=lambda: now[0])
    mission = engine.admit('extended-fixture', scope=['execute','upload','notify'], **admission)
    return engine, mission, now

def add(e, m, root, key, deps=(), effect=None):
    src, art = root/(key+'.src'), root/(key+'.artifact')
    src.write_text('immutable fixture source', encoding='utf-8')
    e.add_step(m, key, action='execute', source_path=src, expected_artifacts=[art], required_tests=1, depends_on=deps, side_effect_key=effect)
    return src, art

def good(s, a):
    art = Path(s['expected_artifacts'][0]); art.write_text('fixture result', encoding='utf-8')
    return ChildResult(0,1,0,hash_file(Path(s['source_path'])),{str(art):hash_file(art)},'fixture',True)

def verify(s, child):
    return ReviewReceipt('independent-reviewer',True,child.source_hash,child.artifact_hashes,'original-approval',True)

@pytest.mark.parametrize('control',['paused','expired'])
def test_action_helper_cannot_execute_after_control_stop(tmp_path, control):
    e,m,now = setup(tmp_path, expires_at=1001.0)
    if control == 'paused': e.pause(m)
    else: now[0] = 1002.0
    effects = []
    e.commit_action_then_notify(m,'protected-action','incident',lambda:effects.append('action'),lambda:effects.append('notice'))
    assert effects == [], f'{control} mission executed new callbacks: {effects}'

def test_uncertain_effect_reconciles_after_restart_without_reexecution(tmp_path):
    e,m,now = setup(tmp_path); add(e,m,tmp_path,'upload',effect='durable-upload'); effects=[]; reconciled=[]
    def lost_response(s,a):
        effects.append(s['key']); good(s,a)
        raise UncertainEffect('durable-upload')
    e.run_until_parked(m,lost_response,verify)
    assert e.step(m,'upload')['status'] == 'uncertain'
    restarted = MissionEngine(e.db_path,policy=Policy(),clock=lambda:now[0])
    def reconcile(s,error):
        reconciled.append(error.target_key)
        art=Path(s['expected_artifacts'][0])
        return ChildResult(0,1,0,hash_file(Path(s['source_path'])),{str(art):hash_file(art)},'target readback',True)
    def never_reexecute(s,a):
        effects.append('DUPLICATE'); return good(s,a)
    restarted.run_until_parked(m,never_reexecute,verify,reconcile_effect=reconcile)
    assert effects == ['upload'], 'Previously committed uncertain action must never replay'
    assert reconciled == ['durable-upload'], 'Durable uncertain state must invoke read-only reconciliation after restart'
    assert restarted.final_gate(m), 'Reconciled success must release the mission without manual database edits'

@pytest.mark.parametrize('failure_site',['runner','verifier'])
def test_unexpected_callback_exception_parks_only_affected_branch(tmp_path,failure_site):
    e,m,_=setup(tmp_path); add(e,m,tmp_path,'broken'); add(e,m,tmp_path,'independent'); effects=[]; escaped=[]
    def run(s,a):
        effects.append(s['key'])
        if s['key']=='broken' and failure_site=='runner': raise ValueError('fixture unexpected child failure')
        return good(s,a)
    def review(s,c):
        if s['key']=='broken' and failure_site=='verifier': raise ValueError('fixture unexpected verifier failure')
        return verify(s,c)
    try: e.run_until_parked(m,run,review)
    except ValueError as exc: escaped.append(str(exc))
    assert e.step(m,'independent')['status']=='verified', f'Independent work stopped; callbacks={effects}; escaped={escaped}'
    assert e.step(m,'broken')['status']!='running', 'Exception must not leave a non-running callback owning a running step'
    assert effects.count('broken')==1, 'Unknown outcome must not blindly replay the side effect'

def test_dependency_continuation_does_not_require_insertion_order(tmp_path):
    e,m,_=setup(tmp_path)
    add(e,m,tmp_path,'child',deps=['parent']); add(e,m,tmp_path,'parent'); seen=[]
    def run(s,a): seen.append(s['key']); return good(s,a)
    e.run_until_parked(m,run,verify)
    assert seen==['parent','child'], 'Ready child was skipped after its dependency completed in the same automatic run'
    assert e.final_gate(m)

class SnapshotBarrierEngine(MissionEngine):
    """Delay only a control read to deterministically expose a valid concurrent interleaving."""
    def __init__(self,*args,barrier,**kwargs):
        self.barrier=barrier; self.rendezvoused=False
        super().__init__(*args,**kwargs)
    def mission(self,mission_id):
        data=super().mission(mission_id)
        caller=inspect.currentframe().f_back
        parent=caller.f_back
        if (not self.rendezvoused and caller.f_code.co_name=='_control_status'
                and parent and parent.f_code.co_name=='_attempt_step' and 'current' in parent.f_locals):
            self.rendezvoused=True
            self.barrier.wait(timeout=8)
        return data

def test_concurrent_attempts_atomically_share_mission_turn_ceiling(tmp_path):
    e,m,_=setup(tmp_path,max_turns=1)
    add(e,m,tmp_path,'one'); add(e,m,tmp_path,'two'); barrier=threading.Barrier(2); seen=[]; lock=threading.Lock()
    engines=[SnapshotBarrierEngine(e.db_path,policy=Policy(),clock=lambda:1000.0,barrier=barrier) for _ in range(2)]
    def run(s,a):
        with lock: seen.append(s['key'])
        return good(s,a)
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures=[pool.submit(worker.run_until_parked,m,run,verify) for worker in engines]
        for future in futures: future.result(timeout=15)
    turns=e.mission(m)['turns_used']
    assert len(seen)<=1 and turns<=1, f'max_turns=1 admitted {len(seen)} callbacks and consumed {turns} turns: {seen}'
