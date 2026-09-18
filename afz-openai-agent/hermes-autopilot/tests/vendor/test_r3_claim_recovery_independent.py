"""Owned local fixture only: preserve uncertainty when reclaiming a dead claimant."""
import json
from afz_autopilot.core import MissionEngine, Policy, ChildResult, ReviewReceipt, UncertainEffect, hash_file

def test_reclaim_before_reconciliation_must_never_replay_the_effect(tmp_path):
    engine = MissionEngine(tmp_path/'state.sqlite3', policy=Policy(), clock=lambda:1000.0)
    mission = engine.admit('claim-recovery-fixture', scope=['execute'])
    source, artifact = tmp_path/'source.txt', tmp_path/'artifact.txt'
    source.write_text('fixed source', encoding='utf-8')
    engine.add_step(mission,'upload',action='execute',source_path=source,expected_artifacts=[artifact],required_tests=1,side_effect_key='upload-once')
    effects, reconciliations = [], []
    def child():
        return ChildResult(0,1,0,hash_file(source),{str(artifact):hash_file(artifact)},'fixture target readback',True)
    def execute(step, attempt):
        effects.append('performed')
        artifact.write_text('performed '+str(len(effects)),encoding='utf-8')
        if len(effects)==1:
            raise UncertainEffect('upload-target')
        return child()
    def verify(step, result):
        return ReviewReceipt('independent-reviewer',True,result.source_hash,result.artifact_hashes,'original-approval',True)
    engine.run_until_parked(mission,execute,verify)
    assert engine.step(mission,'upload')['status']=='uncertain'
    # Simulate an owned coordinator claiming recovery and stopping before reconciliation.
    assert engine.claim(mission,'upload',owner='stopped-fixture-claimer') is not None
    assert engine.recover_stale_claim(mission,'upload',heartbeat_stale=True,process_alive=False,owner='stopped-fixture-claimer')
    def reconcile(step, error):
        reconciliations.append(error.target_key)
        return child()
    restarted = MissionEngine(engine.db_path,policy=Policy(),clock=lambda:1000.0)
    restarted.run_until_parked(mission,execute,verify,reconcile_effect=reconcile)
    first_status = restarted.step(mission,'upload')['status']
    # A second ordinary continuation must not turn lost uncertainty into fresh execution.
    restarted.run_until_parked(mission,execute,verify,reconcile_effect=reconcile)
    observation = {'effects':effects,'reconciliations':reconciliations,'first_status':first_status,'final_status':restarted.step(mission,'upload')['status'],'final_gate':restarted.final_gate(mission)}
    (tmp_path/'claim-recovery-observation.json').write_text(json.dumps(observation,indent=2),encoding='utf-8')
    assert effects==['performed'], f'Previously committed effect replayed after claim recovery: {observation}'
    assert reconciliations and all(k=='upload-target' for k in reconciliations), f'No matching target reconciliation: {observation}'
    assert restarted.final_gate(mission), f'Reconciled original action did not finish: {observation}'
