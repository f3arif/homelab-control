import contextlib,io,json,sqlite3,tempfile,unittest
from dataclasses import replace,asdict
from pathlib import Path
from unittest.mock import patch
from selected_stream import parse_hint,matches,matches_title
from movie_night import Choice,OWNER_CAP,select_compact
from adapters import validate_file,WorkerAdapter
import test_confirmed_sources as sources
from test_worker import manifest
import worker_candidate as worker


class HintTests(unittest.TestCase):
    def test_client_urls_paths_unknown_fields_and_bad_sizes_rejected(self):
        base={'fileName':'Rush.Hour.2.2001.1080p.mkv','sizeBytes':23_916_587_980,'infoHash':'a'*40}
        for change in ({'url':'https://private/token'},{'fileName':'../movie.mkv'},{'fileName':'movie\\name.mkv'},
                       {'fileName':'movie.mkv\n'},{'sizeBytes':True},{'sizeBytes':0},{'sizeBytes':OWNER_CAP+1},
                       {'infoHash':'wrong'},{'fileName':'movie.txt'}):
            with self.assertRaises(ValueError):parse_hint(dict(base,**change))
        self.assertEqual(23_916_587_980,parse_hint(base)['sizeBytes'])

    def test_exact_hash_name_and_byte_size_are_all_bound(self):
        hint=parse_hint({'fileName':'Movie.2024.1080p.mkv','sizeBytes':27,'infoHash':'a'*40})
        self.assertTrue(matches(hint,'a'*40,'folder/Movie.2024.1080p.mkv',27))
        for h,n,size in [('b'*40,hint['fileName'],27),('a'*40,'Other.2024.mkv',27),('a'*40,hint['fileName'],28)]:
            self.assertFalse(matches(hint,h,n,size))

    def test_bilingual_filename_can_match_but_wrong_movie_and_year_cannot(self):
        movie={'name':'Rush Hour 2','year':2001}
        self.assertTrue(matches_title('Час пик 2 - Rush Hour 2 Brett Ratner 2001 1080p.mkv',movie))
        self.assertFalse(matches_title('Rush.Hour.3.2007.1080p.mkv',movie))
        self.assertFalse(matches_title('Rush.Hour.2.2007.1080p.mkv',movie))


class SelectedStreamTests(sources.SourceTests):
    def discovery(self, names=None, codec='AVC', size=23_916_587_980):
        name=names or 'Dream.Mission.1.2024.BluRay.REMUX.1080p.mkv'
        streams=[{'name':'Comet 1080p','description':codec or '', 'behaviorHints':{'filename':name,'bingeGroup':'comet|torbox|'+'a'*40}}]
        cache={'a'*40:{'hash':'a'*40,'name':name,'files':[{'name':name,'size':size}]}}
        self.h.provider._api=lambda *args:cache
        @contextlib.contextmanager
        def response(*args):
            yield io.BytesIO(json.dumps({'streams':streams}).encode())
        return name,patch('confirmed_sources.worker.https_get',response),patch('confirmed_sources.configured_comet',return_value='https://fixture.invalid/comet')

    def test_selected_large_file_offered_without_selection_or_transfer(self):
        name,net,endpoint=self.discovery()
        with net,endpoint:
            hint=parse_hint(dict(fileName=name,sizeBytes=23_916_587_980,infoHash='a'*40))
            result=self.source.options('fixture',self.id,hint)
            self.assertEqual(1,len(result['source_options']))
            self.assertTrue(result['selected_source_matched'])
            self.assertEqual(23_916_587_980,result['source_options'][0]['size_bytes'])
            self.assertEqual('AVC',result['source_options'][0]['codec'])
            self.assertEqual([],self.source.choices(self.id,self.row))
        self.assertEqual(0,self.adds)
        self.assertEqual(0,self.count('jobs'))

    def test_missing_codec_is_explicitly_deferred_only_for_selected_file(self):
        name,net,endpoint=self.discovery(codec='')
        with net,endpoint:
            hint=parse_hint(dict(fileName=name,infoHash='a'*40))
            result=self.source.options('fixture',self.id,hint)
        self.assertEqual('AUTO',result['source_options'][0]['codec'])
        self.assertTrue(result['source_options'][0]['codec_inspection_required'])
        self.assertEqual(0,self.adds)

    def test_other_hash_file_size_or_movie_is_never_substituted(self):
        name,net,endpoint=self.discovery()
        with net,endpoint:
            for change in ({'infoHash':'b'*40},{'sizeBytes':23_916_587_981},{'fileName':'Dream.Mission.2.2024.1080p.mkv'}):
                hint=parse_hint(dict({'fileName':name,'infoHash':'a'*40},**change))
                with self.assertRaisesRegex(ValueError,'unavailable or ambiguous'):
                    self.source.options('fixture',self.id,hint)
        self.assertEqual(0,self.adds)
        self.assertEqual(0,self.count('jobs'))

    def test_ui_hint_cannot_raise_automatic_or_batch_size_limits(self):
        large=replace(self.h.choice,size=25_700_000_000)
        with self.assertRaises(ValueError):large.validate()
        self.assertIsNone(select_compact([large]))
        self.assertEqual(large,large.validate(owner_selected=True))
        data=manifest(25_700_000_000)
        with self.assertRaises(worker.Rejected):worker.validate_manifest(data)
        data['ownerSelectedSource']=True
        self.assertEqual(25_700_000_001,worker.validate_manifest(data)[1])
        data['files'][0]['sizeBytes']=OWNER_CAP+1
        with self.assertRaises(worker.Rejected):worker.validate_manifest(data)

    def test_unconfirmed_http_hint_does_not_select_or_download(self):
        name,net,endpoint=self.discovery()
        with net,endpoint:
            answer=self.finish(self.h.post('feedback',dict(action='source-options',imdb=self.id,
                selectedSource=dict(fileName=name,sizeBytes=23_916_587_980,infoHash='a'*40))))
        self.assertEqual(200,answer.status_code,answer.text)
        self.assertTrue(answer.json()['selected_source_matched'])
        self.assertEqual(0,self.count('jobs'))
        self.assertEqual(0,self.count('movie_mobile_selections'))

    def test_auto_codec_requires_explicit_authorization_and_rejects_bad_video(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'fixture.mkv';p.write_bytes(b'x')
            c=replace(self.h.choice,codec='AUTO',size=1)
            probe=lambda _:dict(format={'duration':'7000'},streams=[dict(codec_type='video',codec_name='hevc',width=1920,height=800)])
            with self.assertRaises(ValueError):validate_file(p,c,probe)
            self.assertEqual('HEVC',validate_file(p,c,probe,owner_selected=True)['actualCodec'])
            wrong=lambda _:dict(format={'duration':'7000'},streams=[dict(codec_type='video',codec_name='mpeg4',width=1920,height=1080)])
            with self.assertRaises(ValueError):validate_file(p,c,wrong,owner_selected=True)
            low=lambda _:dict(format={'duration':'7000'},streams=[dict(codec_type='video',codec_name='h264',width=1280,height=720)])
            with self.assertRaises(ValueError):validate_file(p,c,low,owner_selected=True)

    def test_full_partial_recovery_discovers_codec_only_with_durable_authorization(self):
        self.item['choice']['codec']='AUTO'
        super().test_full_partial_recovery_preserves_explicit_small_file_authorization()
        with sqlite3.connect(self.h.index.db) as db:
            metadata=json.loads(db.execute('SELECT metadata FROM media WHERE id=?',(self.id,)).fetchone()[0])
        self.assertEqual('AVC',metadata['codec'])

    def test_actual_worker_indexes_detected_codec_after_explicit_confirmation(self):
        self.item['choice']['codec']='AUTO'
        self.h.worker.run=WorkerAdapter.run.__get__(self.h.worker,WorkerAdapter)
        self.h.worker.probe=lambda _:dict(format={'duration':'8880'},streams=[dict(codec_type='video',codec_name='h264',width=3840,height=1600)])
        token=self.offer()
        response=self.h.post('feedback',dict(action='confirm-source',imdb=self.id,optionId=token,confirmed=True))
        self.c.similar.jobs[response.json()['jobId']]['future'].result(15)
        answer=self.h.post('feedback',dict(action='similar-status',jobId=response.json()['jobId']))
        self.assertEqual(200,answer.status_code,answer.text)
        job_id=answer.json()['download']['jobId']
        self.assertTrue(self.c.futures[job_id].result(5)['indexed'])
        with sqlite3.connect(self.h.index.db) as db:
            metadata=json.loads(db.execute('SELECT metadata FROM media WHERE id=?',(self.id,)).fetchone()[0])
        self.assertEqual('AVC',metadata['codec'])

for name in list(vars(sources.SourceTests)):
    if name.startswith('test_') and name not in vars(SelectedStreamTests):
        setattr(SelectedStreamTests,name,None)

if __name__=='__main__':unittest.main(verbosity=2)
