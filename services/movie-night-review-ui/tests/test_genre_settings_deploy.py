"""Release guards exercised with temporary files/databases and a mocked service."""
from pathlib import Path
import io, json, sqlite3, sys, tempfile, unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import deploy_genre_settings as release


class GenreSettingsDeployTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.live, self.stage, self.state = root/'src', root/'stage', root/'state'
        self.live.mkdir(); self.state.mkdir()
        files = {}
        for name in release.FILES:
            p = self.live/name
            if name != 'genre_settings.py':p.write_bytes(b'old')
            files[str(p)] = b'new'
        release.Release(self.stage, files).prepare()
        self.unit = root/'service'; self.unit.write_bytes(b'unchanged unit')
        (self.stage/'live-baseline.json').write_text(json.dumps({str(self.unit): release.digest(self.unit)}))
        with sqlite3.connect(self.state/'preferences.sqlite3') as db:
            db.execute('CREATE TABLE jobs(state TEXT)')
            db.execute('CREATE TABLE movie_download_queue(state TEXT)')
            db.execute("INSERT INTO jobs VALUES('indexed')")
            db.execute("INSERT INTO movie_download_queue VALUES('linked')")
        with sqlite3.connect(self.state/'download-index.sqlite3') as db:
            db.execute('CREATE TABLE media(id TEXT)'); db.execute("INSERT INTO media VALUES('fixture')")
        for key, value in [('LIVE', self.live), ('STAGE', self.stage), ('STATE', self.state)]:
            p = patch.object(release, key, value); p.start(); self.addCleanup(p.stop)
        p = patch.object(release.socket, 'gethostname', return_value='afz-zbook'); p.start(); self.addCleanup(p.stop)

    def run_action(self, action, verify=None):
        with patch.object(sys, 'stdout', io.StringIO()), patch.object(sys, 'argv', ['deploy', action]), patch.object(release, 'service') as service, patch.object(release, 'healthy'), patch.object(release, 'verify', side_effect=verify or (lambda _: {'suggestions': 10, 'finalized': 5})):
            release.main()
            return [call.args[0] for call in service.call_args_list]

    def test_apply_and_rollback_preserve_databases_and_unit(self):
        before = release.state_digest()
        self.assertEqual(['stop', 'start'], self.run_action('apply'))
        self.assertTrue(all((self.live/n).read_bytes() == b'new' for n in release.FILES))
        self.assertEqual(['stop', 'start'], self.run_action('rollback'))
        self.assertTrue(all(release.digest(self.live/n) == (None if n=='genre_settings.py' else __import__('hashlib').sha256(b'old').hexdigest()) for n in release.FILES))
        self.assertEqual(before, release.state_digest())
        self.assertEqual(b'unchanged unit', self.unit.read_bytes())
        self.assertEqual(2, len(list(self.stage.glob('*/preferences.sqlite3'))))

    def test_rollback_preserves_preferences_saved_after_deployment(self):
        self.run_action('apply')
        saved=b'{"included":["Drama"],"excluded":[],"revision":1}'
        (self.state/'genre-settings.json').write_bytes(saved)
        self.run_action('rollback')
        self.assertEqual(saved,(self.state/'genre-settings.json').read_bytes())
        self.assertFalse((self.live/'genre_settings.py').exists())

    def test_live_drift_refused_before_stopping_service(self):
        (self.live/'screen.js').write_bytes(b'other agent')
        with patch.object(sys, 'argv', ['deploy', 'apply']), patch.object(release, 'service') as service:
            with self.assertRaisesRegex(RuntimeError, 'Live source drift'): release.main()
            service.assert_not_called()
        self.assertEqual(b'old', (self.live/'feedback.py').read_bytes())

    def test_active_queue_or_transfer_refuses_restart(self):
        for table, state in [('jobs', 'downloading'), ('movie_download_queue', 'checking')]:
            with self.subTest(table=table):
                with sqlite3.connect(self.state/'preferences.sqlite3') as db: db.execute('INSERT INTO '+table+' VALUES(?)', (state,))
                with patch.object(sys, 'argv', ['deploy', 'apply']), patch.object(release, 'service') as service:
                    with self.assertRaises(RuntimeError): release.main()
                    service.assert_not_called()
                with sqlite3.connect(self.state/'preferences.sqlite3') as db: db.execute('DELETE FROM '+table+' WHERE state=?', (state,))

    def test_failed_acceptance_restores_source_without_restoring_state(self):
        def failure(_):
            with sqlite3.connect(self.state/'download-index.sqlite3') as db: db.execute("INSERT INTO media VALUES('later-state')")
            raise RuntimeError('acceptance failed')
        with self.assertRaisesRegex(RuntimeError, 'acceptance failed'): self.run_action('apply', failure)
        self.assertTrue(all(release.digest(self.live/n) == (None if n=='genre_settings.py' else __import__('hashlib').sha256(b'old').hexdigest()) for n in release.FILES))
        with release.connect('download-index.sqlite3') as db:
            self.assertEqual(2, db.execute('SELECT count(*) FROM media').fetchone()[0])

    def test_tampered_backup_refused_before_stopping_service(self):
        (self.stage/'1.before').write_bytes(b'tampered')
        with patch.object(sys, 'argv', ['deploy', 'apply']), patch.object(release, 'service') as service:
            with self.assertRaisesRegex(RuntimeError, 'Stage drift'): release.main()
            service.assert_not_called()


if __name__ == '__main__': unittest.main()
