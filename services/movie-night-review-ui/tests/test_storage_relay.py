import asyncio
from collections import namedtuple
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from dataclasses import replace
from movie_night import Choice, ROOT, MIN_BYTES, CAP, select_compact
from storage_volume import MediaVolume
from private_relay import RelayAuth, read_secret
import worker_candidate as worker
from test_movie_night import choice
from download_provider import InventoryChoices


class DownloadBoundsTests(unittest.TestCase):
    def test_inclusive_five_fifteen_gb_at_choice_and_worker(self):
        for size in (MIN_BYTES - 1, MIN_BYTES, CAP, CAP + 1):
            valid = MIN_BYTES <= size <= CAP
            c = choice(size=size)
            self.assertEqual(valid, select_compact([c]) is not None)
            manifest = {'approved': True, 'files': [dict(canonicalId=c.imdb, torrentId=12,
                fileId=3, providerName=c.provider_name, sizeBytes=size, editionConfirmed=True,
                destination='Movies/fixture.mkv')]}
            if valid: self.assertEqual(size + 1, worker.validate_manifest(manifest)[1])
            else:
                with self.assertRaises(worker.Rejected): worker.validate_manifest(manifest)

    def test_bounded_inventory_accepts_large_qualifying_file_without_small_fallback(self):
        m = {'id': 'tt12345', 'name': 'Fixture One', 'year': 2024}
        files = [dict(id=n, name='Fixture.One.2024.1080p.x264.mkv', size=size,
                      infected=False, zipped=False) for n, size in enumerate((4_999_999_999,5_000_000_000,15_000_000_000,15_000_000_001))]
        row = dict(id=1, download_finished=True, download_present=True, files=files)
        self.assertEqual([5_000_000_000,15_000_000_000], [c.size for c in InventoryChoices.parse(m,[row],complete=False)])


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.mount=Path(self.tmp.name)/'volume';self.mount.mkdir()
        self.root=self.mount/'Media/MovieNight'
        self.row=dict(target=str(self.mount),uuid='fixture',fstype='ntfs3',options='rw,nosuid,nodev')
        self.usage=namedtuple('Usage','total used free')(8_000_000_000_000,1,7_000_000_000_000)
        self.volume=MediaVolume(self.root,self.mount,'fixture',lambda _:self.row,lambda _:self.usage)
    def test_exact_volume_creates_folder(self):
        self.assertEqual(self.root,self.volume.ensure());self.assertTrue((self.root/'Movies').is_dir())
    def test_wrong_missing_readonly_or_small_disk_never_creates_folder(self):
        for changed in (dict(uuid='wrong'),dict(target='/'),dict(fstype='ext4'),dict(options='ro')):
            prior=dict(self.row);self.row.update(changed)
            with self.assertRaisesRegex(ValueError,'8 TB drive unavailable'):self.volume.ensure()
            self.assertFalse(self.root.exists());self.row=prior
        self.usage=self.usage._replace(total=1_000_000_000_000)
        with self.assertRaises(ValueError):self.volume.ensure()
        self.assertFalse(self.root.exists())
    def test_symlink_destination_rejected(self):
        (self.mount/'Media').symlink_to(Path(self.tmp.name))
        with self.assertRaises(ValueError):self.volume.ensure()
    def test_mount_loss_after_creation_stops_writes(self):
        self.volume.ensure();self.row['uuid']='system-disk'
        with self.assertRaises(ValueError):self.volume.check()


class RelayAuthTests(unittest.TestCase):
    def request(self, peer, secret, server=('100.77.196.70',8797), extra=None):
        events=[];called=[]
        async def app(scope,receive,send):called.append(scope)
        async def send(event):events.append(event)
        async def receive():return {'type':'http.request','body':b''}
        headers=[] if secret is None else [(b'x-movie-night-relay',secret.encode())]
        if extra:headers.append((b'x-movie-night-relay',extra.encode()))
        asyncio.run(RelayAuth(app,'a'*64)({'type':'http','server':server,'client':(peer,123),'headers':headers},receive,send))
        return called,events
    def test_peer_and_secret_both_required(self):
        for peer,token in [('100.71.26.69',None),('100.71.26.69','b'*64),('100.1.2.3','a'*64),('127.0.0.1','a'*64)]:
            called,events=self.request(peer,token);self.assertFalse(called);self.assertEqual(403,events[0]['status'])
    def test_authorized_secret_removed_before_app(self):
        called,_=self.request('100.71.26.69','a'*64);self.assertEqual([],called[0]['headers'])
    def test_duplicate_secret_denied(self):
        called,events=self.request('100.71.26.69','a'*64,extra='a'*64);self.assertFalse(called);self.assertEqual(403,events[0]['status'])
    def test_private_unix_socket_keeps_existing_local_verification(self):
        called,_=self.request('',None,server=None);self.assertEqual(1,len(called))
    def test_secret_requires_private_regular_file(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/'secret';p.write_text('a'*64);p.chmod(0o600)
            self.assertEqual('a'*64,read_secret(p));p.chmod(0o644)
            with self.assertRaises(ValueError):read_secret(p)


if __name__=='__main__':unittest.main()
