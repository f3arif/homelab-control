import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('jobs', Path(__file__).with_name('afz_safe_job.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class SafeJobs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.script = self.root / 'test.sh'
        self.script.write_text('set -eu\nprintf "executed\\n" >> "$AFZ_JOB_DIR/count"\n')
    def submit(self, job='test-a', effect='read-only', timeout=10):
        return m.submit(self.root, job, 'test', self.script, timeout, effect, self.root, launch=False)
    def state(self, job='test-a'):
        return m.load(self.root / job / 'state.json')
    def test_identifier_rejects_traversal(self):
        for name in ('../x', '', 'A', 'x/y', 'a'*81):
            with self.assertRaises(ValueError): m.identifier(name)
    def test_atomic_private_and_valid(self):
        p = self.root / 'state.json'
        m.atomic(p, {'a':1}); m.atomic(p, {'a':2})
        self.assertEqual(m.load(p), {'a':2})
        self.assertEqual(p.stat().st_mode & 0o777, 0o600)
    def test_submit_duplicate_preserves_state(self):
        self.assertFalse(self.submit()['existing'])
        before = (self.root/'test-a/manifest.json').read_bytes()
        self.assertTrue(self.submit()['existing'])
        self.assertEqual(before, (self.root/'test-a/manifest.json').read_bytes())
    def test_duplicate_changed_payload_rejected(self):
        self.submit(); self.script.write_text('exit 1\n')
        with self.assertRaises(ValueError): self.submit()
    def test_completed_job_cannot_replay(self):
        self.submit(); self.assertEqual(m.worker(self.root,'test-a'),0)
        self.assertEqual(m.worker(self.root,'test-a'),0)
        self.assertTrue(self.submit()['existing'])
        self.assertEqual((self.root/'test-a/count').read_text(),'executed\n')
    def test_project_lock_blocks_second_job(self):
        self.submit()
        with m.locked(self.root/'.project-test.lock'):
            self.assertEqual(m.worker(self.root,'test-a'),3)
        self.assertEqual(self.state()['status'],'BLOCKED')
        self.assertFalse((self.root/'test-a/count').exists())
    def test_hash_mismatch_blocks(self):
        self.submit(); (self.root/'test-a/payload.sh').write_text('exit 0\n')
        self.assertEqual(m.worker(self.root,'test-a'),2)
        self.assertEqual(self.state()['status'],'BLOCKED')
    def test_running_state_never_replayed(self):
        self.submit()
        m.atomic(self.root/'test-a/state.json',{'status':'RUNNING'})
        self.assertEqual(m.worker(self.root,'test-a'),0)
        self.assertFalse((self.root/'test-a/count').exists())
    def test_failed_readonly_recorded(self):
        self.script.write_text('exit 7\n'); self.submit()
        self.assertEqual(m.worker(self.root,'test-a'),1)
        self.assertEqual(self.state()['status'],'FAILED')
        self.assertEqual(self.state()['exit_code'],7)
    def test_failed_change_requires_verification(self):
        self.script.write_text('exit 7\n'); self.submit(effect='local-change')
        m.worker(self.root,'test-a')
        self.assertEqual(self.state()['status'],'VERIFY_REQUIRED')
    def test_timeout_does_not_retry(self):
        self.script.write_text('sleep 30\n'); self.submit(timeout=1)
        self.assertEqual(m.worker(self.root,'test-a'),2)
        self.assertEqual(self.state()['status'],'VERIFY_REQUIRED')
        self.assertEqual(m.worker(self.root,'test-a'),0)
    def test_missing_unit_requires_verification(self):
        self.submit()
        with patch.object(m,'unit_state',return_value={'LoadState':'not-found','ActiveState':'inactive'}):
            self.assertEqual(m.status(self.root,'test-a')['effective_status'],'VERIFY_REQUIRED')
    def test_manager_unavailable_is_unknown(self):
        self.submit()
        with patch.object(m,'unit_state',return_value={'query':'unavailable'}):
            self.assertEqual(m.status(self.root,'test-a')['effective_status'],'UNKNOWN_VERIFY_FIRST')
    def test_status_does_not_change_checkpoint(self):
        self.submit()
        p=self.root/'test-a/checkpoint.json'; m.atomic(p,{'phase':'test-observed'})
        before=p.read_bytes(); s=m.status(self.root,'test-a',inspect_unit=False)
        self.assertEqual(s['checkpoint']['phase'],'test-observed')
        self.assertEqual(before,p.read_bytes())
    def test_invalid_timeout_rejected(self):
        with self.assertRaises(ValueError): self.submit(timeout=0)
    def test_original_script_change_does_not_change_snapshot(self):
        self.submit(); self.script.write_text('exit 99\n')
        self.assertEqual(m.worker(self.root,'test-a'),0)
        self.assertEqual(self.state()['status'],'COMPLETED')

if __name__=='__main__': unittest.main(verbosity=2)
