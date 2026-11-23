import contextlib,io,json,sqlite3,tempfile,unittest
from dataclasses import asdict,replace
from pathlib import Path
from unittest.mock import patch
from test_mobile_selection import MobileSelectionTests
from confirmed_sources import ConfirmedSources
import worker_candidate as worker
from adapters import validate_file


class SourceTests(MobileSelectionTests):
    # Reuse only the fixture, not the old selection tests.
    def setUp(self):
        super().setUp()
        self.source=self.c.confirmed_sources
        self.row=self.c.similar.source.admission(self.id)
        self.item=dict(hash='a'*40,movie=self.row,choice=asdict(replace(
            self.h.choice,provider_name='Dream.Mission.1.2024.2160p.x264.mkv',quality='2160p')))
        self.adds=0
        def add_cached(value):
            self.adds+=1
            self.assertEqual('a'*40,value)
            return 12
        def api(*args):
            return dict(id=12,hash='a'*40,download_finished=True,download_present=True,files=[
                dict(id=3,name=self.item['choice']['provider_name'],size=self.h.choice.size,infected=False,zipped=False)])
        self.h.provider.add_cached=add_cached
        self.h.provider._api=api
        self.c.worker.run=lambda job: {'state':'approved'}
        self.c.worker.root=self.h.media

    def offer(self):
        with patch.object(self.source,'choices',return_value=[self.item]):
            return self.source.options('fixture',self.id)['source_options'][0]['option_id']

    def test_options_have_no_selection_or_provider_write(self):
        token=self.offer()
        self.assertEqual(32,len(token))
        self.assertEqual(0,self.adds)
        self.assertEqual(0,self.count('jobs'))
        self.assertEqual(0,self.count('movie_mobile_selections'))

    def test_exact_choice_has_durable_confirmation_and_idempotent_replay(self):
        token=self.offer()
        first=self.source.confirm('fixture',self.id,token)
        second=self.source.confirm('fixture',self.id,token)
        self.assertTrue(first['downloadRequested'])
        self.assertEqual(first['download']['jobId'],second['download']['jobId'])
        self.assertEqual(1,self.adds)
        with sqlite3.connect(self.h.db) as db:
            data=json.loads(db.execute('SELECT payload FROM jobs').fetchone()[0])
        self.assertEqual('2160p',data['choice']['quality'])
        self.assertEqual(self.item['choice']['provider_name'],data['choice']['provider_name'])
        self.assertEqual('owner-selected-source',data['authorization'])

    def test_unconfirmed_wrong_movie_wrong_owner_and_expired_offer(self):
        token=self.offer()
        for principal,imdb in [('other',self.id),('fixture','tt12345678')]:
            with self.assertRaises(ValueError):self.source.confirm(principal,imdb,token)
        self.assertEqual(400,self.h.post('feedback',dict(action='confirm-source',imdb=self.id,optionId=token,confirmed=False)).status_code)
        with sqlite3.connect(self.h.db) as db:db.execute('UPDATE movie_source_offers SET expires=0')
        with self.assertRaises(ValueError):self.source.confirm('fixture',self.id,token)
        self.assertEqual(0,self.adds)

    def test_changed_cache_file_never_starts_transfer(self):
        token=self.offer()
        self.h.provider._api=lambda *args:dict(id=12,hash='a'*40,download_finished=True,download_present=True,files=[])
        with patch('confirmed_sources.time.sleep'):
            with self.assertRaisesRegex(ValueError,'changed'):self.source.confirm('fixture',self.id,token)
        self.assertEqual(0,self.count('jobs'))

    def test_confirmation_includes_only_selected_additional_budget(self):
        with patch.object(self.source,'committed',return_value=100_000_000_000):
            token=self.offer()
            self.source.confirm('fixture',self.id,token)
        with sqlite3.connect(self.h.db) as db:data=json.loads(db.execute('SELECT payload FROM jobs').fetchone()[0])
        self.assertEqual(self.h.choice.size+1,data['additionalTransferAuthorizationBytes'])

    def test_4k_probe_rejects_wrong_resolution(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'clip.mkv';p.write_bytes(b'x')
            c=replace(self.h.choice,quality='2160p',codec='HEVC',size=1)
            probe=lambda _:dict(format={'duration':'8880'},streams=[dict(codec_type='video',codec_name='hevc',width=3840,height=1600)])
            self.assertTrue(validate_file(p,c,probe)['mediaProbePassed'])
            with self.assertRaises(ValueError):validate_file(p,replace(c,quality='1080p'),probe)

    def test_transfer_timeout_is_classified_and_secrets_are_discarded(self):
        self.assertEqual('network-timeout',worker.transfer_error(TimeoutError('https://secret/token')))
        self.assertEqual('network-timeout',worker.transfer_error(worker.Rejected('network-timeout')))
        self.assertEqual('transfer-failed',worker.transfer_error(ValueError('https://secret/token')))
        # A timeout raised while using parent_fd must retain its own category.
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(TimeoutError):
                with worker.parent_fd(Path(tmp),'Movies/clip.mkv'):
                    raise TimeoutError('private')

    def test_zero_automatic_budget_still_returns_confirmable_sources(self):
        with patch.object(self.source,'choices',return_value=[self.item]), patch.object(self.source,'committed',return_value=100_000_000_000):
            result=self.source.options('fixture',self.id)
        self.assertEqual(0,result['remaining_budget_bytes'])
        self.assertTrue(result['explicit_source_confirmation_allowed'])
        self.assertEqual(self.h.choice.size+1,result['source_options'][0]['additional_budget_bytes'])
        self.assertEqual(0,self.adds)
        self.assertEqual(0,self.count('jobs'))

    def test_small_owner_source_keeps_the_automatic_minimum(self):
        from movie_night import select_compact
        from test_worker import manifest
        small=replace(self.h.choice,size=2_585_807_653)
        with patch('movie_night.MIN_BYTES',5_000_000_000),patch('worker_candidate.MIN_BYTES',5_000_000_000):
            with self.assertRaises(ValueError):small.validate()
            self.assertEqual(small,small.validate(owner_selected=True))
            self.assertIsNone(select_compact([small]))
            data=manifest(2_585_807_653)
            with self.assertRaises(worker.Rejected):worker.validate_manifest(data)
            data['ownerSelectedSource']=True
            self.assertEqual(2_585_807_654,worker.validate_manifest(data)[1])
            with self.assertRaises(ValueError):replace(small,size=0).validate(owner_selected=True)

    def test_new_file_does_not_reauthorize_previous_extra_allowance(self):
        prior=dict(choice=dict(self.item['choice'],size=7_132_210_155),additionalTransferAuthorizationBytes=4_166_143_639)
        with sqlite3.connect(self.h.db) as db:
            db.execute('INSERT INTO archived_jobs VALUES(?,?,?,?,?,?,?,?,?)',
                       ('old-allowance','tt123456','old-file',json.dumps(prior),'failed',0,'{}','fixture',0))
        with patch.object(self.source,'committed',return_value=104_166_143_639):
            token=self.offer()
            self.source.confirm('fixture',self.id,token)
        with sqlite3.connect(self.h.db) as db:
            payload=json.loads(db.execute('SELECT payload FROM jobs').fetchone()[0])
        self.assertEqual(self.h.choice.size+1,payload['additionalTransferAuthorizationBytes'])

    def test_changed_allowance_requires_fresh_confirmation(self):
        token=self.offer()
        with patch.object(self.source,'committed',return_value=100_000_000_000):
            with self.assertRaisesRegex(ValueError,'allowance changed'):
                self.source.confirm('fixture',self.id,token)
        self.assertEqual(0,self.count('jobs'))
        self.assertEqual(0,self.count('movie_download_queue'))

    def test_http_confirmation_runs_the_real_worker_to_an_indexed_file(self):
        with patch('movie_night.MIN_BYTES',5_000_000_000),patch('worker_candidate.MIN_BYTES',5_000_000_000):
            from adapters import WorkerAdapter
            self.h.worker.run=WorkerAdapter.run.__get__(self.h.worker,WorkerAdapter)
            self.h.worker.probe=lambda _:dict(format={'duration':'8880'},streams=[dict(codec_type='video',codec_name='h264',width=3840,height=1600)])
            token=self.offer()
            response=self.h.post('feedback',dict(action='confirm-source',imdb=self.id,optionId=token,confirmed=True))
            self.c.similar.jobs[response.json()['jobId']]['future'].result(15)
            answer=self.h.post('feedback',dict(action='similar-status',jobId=response.json()['jobId']))
            self.assertEqual(200,answer.status_code,answer.text)
            job_id=answer.json()['download']['jobId']
            result=self.c.futures[job_id].result(5)
            self.assertTrue(result['indexed'],result)
            self.assertEqual(self.h.body,self.h.client.get('/movie-night/media/'+self.id).content)
            self.assertEqual(1,self.adds)
    def test_full_partial_recovery_preserves_explicit_small_file_authorization(self):
        from movie_night import ApprovalStore
        self.h.worker.probe=lambda _:dict(format={'duration':'8880'},streams=[dict(codec_type='video',codec_name='h264',width=3840,height=1600)])
        with patch('movie_night.MIN_BYTES',5_000_000_000),patch('worker_candidate.MIN_BYTES',5_000_000_000):
            token=self.offer()
            answer=self.source.confirm('fixture',self.id,token)
            job=answer['download']['jobId']
            store=ApprovalStore(self.h.db)
            try:store.transition(job,'downloading',bytes_received=len(self.h.body))
            finally:store.close()
            directory=self.h.media/'Movies'
            directory.mkdir(exist_ok=True)
            (directory/(Path(self.item['choice']['destination']).name+'.part')).write_bytes(self.h.body)
            self.assertTrue(self.h.worker.finish_transferred(job))
            self.assertTrue(self.c.downloads('fixture')['jobs'][0]['indexed'])

    def test_http_options_are_read_only_and_confirmation_requires_token(self):
        with patch.object(self.source,'choices',return_value=[self.item]):
            response=self.h.post('feedback',dict(action='source-options',imdb=self.id))
            answer=self.finish(response)
        self.assertEqual(200,answer.status_code,answer.text)
        self.assertTrue(answer.json()['confirmation_required'])
        self.assertEqual(0,self.count('jobs'))

# Keep fixture inheritance without re-running all parent selection tests here.
for name in list(vars(MobileSelectionTests)):
    if name.startswith('test_') and name not in vars(SourceTests):
        setattr(SourceTests,name,None)

if __name__=='__main__':unittest.main(verbosity=2)
