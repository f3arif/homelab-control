"""Safety tests: disposable bytes only; no production mounted media or owner data."""
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from adapters import MediaIndex
from server_file_delete import ServerFileDeletion, RemovalUnavailable

IMDB = "tt12262116"
NAME = "Thirteen Lives"
FILENAME = "tt12262116.2022.mkv"
OWNER = "billing-owner"


class ServerDeleteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="afz-delete-fixture-")
        self.dir = Path(self.tmp.name)
        self.root = self.dir / "media"
        self.root.mkdir(mode=0o700)
        (self.root / "Movies").mkdir(mode=0o700)
        self.payload = b"dummy non-video fixture, never production"
        self.file = self.root / "Movies" / FILENAME
        self.file.write_bytes(self.payload)
        self.hash = hashlib.sha256(self.payload).hexdigest()
        self.jobs = self.dir / "jobs.sqlite3"
        with sqlite3.connect(self.jobs) as c:
            c.execute("CREATE TABLE jobs(payload TEXT NOT NULL,state TEXT NOT NULL)")
        self.index = MediaIndex(self.dir / "media-index.sqlite3", self.root)
        with sqlite3.connect(self.index.db) as c:
            c.execute("INSERT INTO media VALUES (?,?,?,?,?,?)",
                      (IMDB,FILENAME,json.dumps({"title":NAME,"year":2022}),
                       len(self.payload),self.hash,1))
        self.now = 1000
        self.service = ServerFileDeletion(self.index, self.jobs, clock=lambda: self.now)

    def tearDown(self):
        self.tmp.cleanup()

    def preview(self, principal=OWNER):
        return self.service.preview(principal, IMDB)

    def delete(self, preview, principal=OWNER, name=NAME):
        return self.service.delete(principal, IMDB, preview["confirmationToken"], name)

    def test_preview_has_binding_and_never_deletes(self):
        value = self.preview()
        self.assertEqual(value["title"], NAME)
        self.assertEqual(value["sizeBytes"], len(self.payload))
        self.assertTrue(value["requiresExplicitConfirmation"])
        self.assertEqual(value["expiresInSeconds"], 120)
        self.assertTrue(self.file.exists())
        self.assertEqual(len(self.index.metas()), 1)

    def test_explicit_confirm_removes_only_one_exact_file_and_catalog_entry(self):
        other = self.root / "Movies" / "tt12345678.2000.mkv"
        other.write_bytes(b"protected other movie")
        value = self.preview()
        reply = self.delete(value)
        self.assertEqual(reply["freedBytes"], len(self.payload))
        self.assertFalse(self.file.exists())
        self.assertEqual(other.read_bytes(), b"protected other movie")
        self.assertEqual(self.index.metas(), [])
        self.assertEqual(self.service.removed_ids(), {IMDB})
        with self.assertRaises(RemovalUnavailable):
            self.delete(value)

    def test_cancel_never_changes_file_or_index(self):
        value = self.preview()
        self.assertTrue(self.file.is_file())
        self.assertEqual(self.index.metas()[0]["id"], IMDB)
        self.assertNotIn(IMDB, self.service.removed_ids())
        self.assertTrue(value["confirmationToken"])

    def test_wrong_title_consumes_confirmation_without_removal(self):
        value = self.preview()
        with self.assertRaises(RemovalUnavailable):
            self.delete(value, name="Something Else")
        self.assertTrue(self.file.exists())
        with self.assertRaises(RemovalUnavailable):
            self.delete(value)

    def test_owner_binding_not_transferable(self):
        value = self.preview()
        with self.assertRaises(RemovalUnavailable):
            self.delete(value, principal="someone@example.test")
        self.assertTrue(self.file.is_file())
        self.assertEqual(self.delete(value)["deleted"], True)

    def test_expired_and_replayed_token_fail_closed(self):
        value = self.preview()
        self.now += 121
        with self.assertRaises(RemovalUnavailable):
            self.delete(value)
        self.assertTrue(self.file.exists())
        with self.assertRaises(RemovalUnavailable):
            self.delete(value)

    def test_replace_same_size_file_after_preview_is_rejected(self):
        value = self.preview()
        self.file.unlink()
        self.file.write_bytes(b"X" * len(self.payload))
        with self.assertRaises(RemovalUnavailable):
            self.delete(value)
        self.assertEqual(self.file.read_bytes(), b"X" * len(self.payload))

    def test_symlink_and_missing_movie_refused(self):
        value = self.preview()
        self.file.unlink()
        elsewhere = self.dir / "not-to-delete.txt"
        elsewhere.write_bytes(self.payload)
        self.file.symlink_to(elsewhere)
        with self.assertRaises(RemovalUnavailable):
            self.delete(value)
        self.assertTrue(elsewhere.exists())

    def test_pending_job_prevents_delete(self):
        payload = json.dumps({"choice":{"imdb":IMDB}})
        with sqlite3.connect(self.jobs) as c:
            c.execute("INSERT INTO jobs VALUES (?,?)",(payload,"downloading"))
        with self.assertRaises(RemovalUnavailable) as e:
            self.preview()
        self.assertIn("transfer",str(e.exception).lower())
        self.assertTrue(self.file.exists())

    def test_pending_queue_prevents_delete(self):
        with sqlite3.connect(self.jobs) as c:
            c.execute("CREATE TABLE movie_download_queue(imdb TEXT NOT NULL,state TEXT NOT NULL)")
            c.execute("INSERT INTO movie_download_queue VALUES (?,?)",(IMDB,"queued"))
        with self.assertRaises(RemovalUnavailable):
            self.preview()
        self.assertTrue(self.file.exists())

    def test_unknown_or_different_id_never_mutates(self):
        for imdb in ("../etc/passwd","tt0","tt12262116%2f","tt99999999"):
            with self.assertRaises(RemovalUnavailable):
                self.service.preview(OWNER, imdb)
        self.assertTrue(self.file.is_file())
        self.assertEqual(len(self.index.metas()), 1)

    def test_storage_guard_fail_closed(self):
        self.index.storage_guard=lambda: (_ for _ in ()).throw(RuntimeError("volume unavailable"))
        with self.assertRaises(RuntimeError):
            self.preview()
        self.assertTrue(self.file.exists())

    def test_tombstone_blocks_automatic_reregister(self):
        value=self.preview()
        self.delete(value)
        self.file.write_bytes(self.payload)
        choice=SimpleNamespace(imdb=IMDB,destination=FILENAME,size=len(self.payload))
        with self.assertRaises(ValueError) as result:
            self.index.register(choice,{"sha256":self.hash})
        self.assertIn("intentionally removed",str(result.exception))


if __name__ == "__main__":
    unittest.main()
