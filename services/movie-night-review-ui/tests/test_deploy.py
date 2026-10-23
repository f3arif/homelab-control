from pathlib import Path
import sys,tempfile,unittest,json
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from deploy import Release
class DeployTests(unittest.TestCase):
 def setUp(self):self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.a=self.root/'a';self.b=self.root/'b';self.a.write_bytes(b'old');self.r=Release(self.root/'stage',{str(self.a):b'new',str(self.b):b'added'});self.r.prepare()
 def tearDown(self):self.tmp.cleanup()
 def test_apply_and_rollback_preserve_absent_file(self):
  self.r.swap();self.assertEqual(b'new',self.a.read_bytes());self.assertEqual(b'added',self.b.read_bytes())
  self.r.swap(True);self.assertEqual(b'old',self.a.read_bytes());self.assertFalse(self.b.exists())
 def test_live_drift_changes_nothing(self):
  self.a.write_bytes(b'external')
  with self.assertRaises(RuntimeError):self.r.swap()
  self.assertFalse(self.b.exists());self.assertEqual(b'external',self.a.read_bytes())
 def test_tampered_stage_changes_nothing(self):
  (self.root/'stage/1.after').write_bytes(b'tampered')
  with self.assertRaises(RuntimeError):self.r.swap()
  self.assertEqual(b'old',self.a.read_bytes());self.assertFalse(self.b.exists())
 def test_rollback_refuses_drift(self):
  self.r.swap();self.b.write_bytes(b'external')
  with self.assertRaises(RuntimeError):self.r.swap(True)
  self.assertEqual(b'new',self.a.read_bytes())
