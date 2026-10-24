from hashlib import sha256
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from migrate_storage import migrate
from movie_night import ApprovalStore
from adapters import MediaIndex


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.state=Path(self.tmp.name)/'state';self.state.mkdir()
        self.root=Path(self.tmp.name)/'disk';(self.root/'Movies').mkdir(parents=True)
        self.file=self.root/'Movies/fixture.mkv';self.file.write_bytes(b'fixture')
        digest=sha256(b'fixture').hexdigest()
        self.receipt=[dict(target='Movies/fixture.mkv',size=7,sha256=digest)]
        class Volume:
            def ensure(_):return self.root
        self.volume=Volume()
        store=ApprovalStore(self.state/'preferences.sqlite3')
        with store.db as db:
            db.execute('CREATE TABLE movie_download_queue(id TEXT,job_id TEXT,state TEXT,message TEXT,updated INTEGER)')
            db.execute('CREATE TABLE movie_finalized(principal TEXT,ids TEXT)')
            db.execute("INSERT INTO movie_finalized VALUES('fixture','[\"tt12345\",\"tt12346\",\"tt12347\"]')")
            for pid,status in [('done','indexed'),('paused','cancelled')]:
                old='/old/'+('fixture.mkv' if pid=='done' else 'partial.mkv')
                payload=json.dumps({'choice':{'destination':old,'size':7}})
                evidence=json.dumps({'file':{'sha256':digest,'destination':old}}) if pid=='done' else '{}'
                db.execute('INSERT INTO plans VALUES(?,?,?,?)',(pid,'fixture',payload,1000))
                db.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?,?)',(pid,pid,old,payload,status,7,evidence))
                db.execute('INSERT INTO movie_download_queue VALUES(?,?,?,?,?)',(pid,pid,'linked','',1000))
        store.close()
        MediaIndex(self.state/'download-index.sqlite3',self.root)
    def state_rows(self):
        with sqlite3.connect(self.state/'preferences.sqlite3') as db:
            return db.execute('SELECT * FROM jobs').fetchall()
    def test_complete_copy_rebound_and_cancelled_history_preserved_for_explicit_retry(self):
        result=migrate(self.state,self.volume,self.receipt)
        self.assertEqual(dict(completed=1,archived=1,files=1),result)
        with sqlite3.connect(self.state/'preferences.sqlite3') as db:
            self.assertEqual(1,db.execute('SELECT count(*) FROM jobs').fetchone()[0])
            self.assertEqual('/old/partial.mkv',db.execute('SELECT destination FROM archived_jobs').fetchone()[0])
            self.assertEqual(str(self.file),db.execute('SELECT destination FROM jobs').fetchone()[0])
            self.assertEqual((None,'failed'),db.execute("SELECT job_id,state FROM movie_download_queue WHERE id='paused'").fetchone())
            self.assertEqual('["tt12345","tt12346","tt12347"]',db.execute('SELECT ids FROM movie_finalized').fetchone()[0])
            self.assertIn('/old/fixture.mkv',db.execute("SELECT payload FROM plans WHERE id='done'").fetchone()[0])
        self.assertEqual(b'fixture',self.file.read_bytes())
        with self.assertRaisesRegex(ValueError,'already recorded'):migrate(self.state,self.volume,self.receipt)
    def test_wrong_copy_does_not_mutate_jobs(self):
        before=self.state_rows();self.file.write_bytes(b'changed')
        with self.assertRaises(ValueError):migrate(self.state,self.volume,self.receipt)
        self.assertEqual(before,self.state_rows())
    def test_active_job_blocks_migration(self):
        with sqlite3.connect(self.state/'preferences.sqlite3') as db:db.execute("UPDATE jobs SET state='downloading' WHERE id='paused'")
        before=self.state_rows()
        with self.assertRaisesRegex(ValueError,'Active jobs'):migrate(self.state,self.volume,self.receipt)
        self.assertEqual(before,self.state_rows())
    def test_unexpected_job_rolls_back_completed_job_update(self):
        with sqlite3.connect(self.state/'preferences.sqlite3') as db:db.execute("UPDATE jobs SET state='failed' WHERE id='paused'")
        before=self.state_rows()
        with self.assertRaisesRegex(ValueError,'Unexpected job'):migrate(self.state,self.volume,self.receipt)
        self.assertEqual(before,self.state_rows())


if __name__=='__main__':unittest.main()
