import base64,contextlib,copy,hashlib,io,json,os,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
import worker
from worker import Rejected,Provider,validate_manifest,run,job_lock
from install import install

def manifest(size=4):
 return {'approved':True,'files':[{'canonicalId':'tt123','torrentId':12,'fileId':3,'providerName':'file.mkv','sizeBytes':size,'destination':'Movies/Fixture/file.mkv','editionConfirmed':True}]}
class Response(io.BytesIO):
 def __init__(self,data=b'data',length='4',encoding='identity'):
  super().__init__(data);self.headers={'Content-Length':length,'Content-Encoding':encoding}
class FakeProvider:
 def __init__(self):self.calls=0
 def resolve(self,row):self.calls+=1;return 'https://fixture.invalid/secret-signed-url'
class WorkerTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.base=Path(self.temp.name)
  self.root=self.base/'media';self.root.mkdir();self.state=self.base/'state';self.state.mkdir();self.provider=FakeProvider()
 def execute(self,m=None,response=None,free=worker.RESERVE+100):
  return run(m or manifest(),self.root,self.state,self.provider,lambda u:response or Response(),lambda p:free)
 def rejected(self,m):
  with self.assertRaises(Rejected):validate_manifest(m)
 def test_unapproved(self):m=manifest();m['approved']=False;self.rejected(m)
 def test_missing_id(self):m=manifest();m['files'][0]['fileId']=None;self.rejected(m)
 def test_unknown_zero_fraction_boolean_sizes(self):
  for s in [None,0,-1,1.5,True]:self.rejected(manifest(s))
 def test_nine_billion_boundary(self):self.assertEqual(validate_manifest(manifest(9_000_000_000))[1],9_000_000_001)
 def test_above_nine_billion(self):self.rejected(manifest(9_000_000_001))
 def test_series_policy_not_movie_capped(self):m=manifest(10_000_000_000);m['files'][0]['canonicalId']='tt123:1:1';m['files'][0]['destination']='TV/Fixture/file.mkv';validate_manifest(m)
 def test_batch_cap_includes_eof_byte(self):m=manifest(worker.MAX_BYTES);m['files'][0]['canonicalId']='tt123:1:1';self.rejected(m)
 def test_traversal_absolute_windows(self):
  for p in ['../Movies/a.mkv','/Movies/a.mkv','Movies/../../a.mkv','Movies\\a.mkv']:
   m=manifest();m['files'][0]['destination']=p;self.rejected(m)
 def test_edition_required(self):m=manifest();m['files'][0]['editionConfirmed']=False;self.rejected(m)
 def test_batch_file_count(self):
  m=manifest();m['files']*=73;self.rejected(m)
 def test_transfer_deadline_preserves_partial(self):
  with patch('worker.time.monotonic',side_effect=[0,0,7201]):
   with self.assertRaises(Rejected):self.execute()
  self.assertTrue((self.root/'Movies/Fixture/file.mkv.part').exists())
 def test_duplicate(self):m=manifest();m['files']*=2;self.rejected(m)
 def test_duplicate_provider_file(self):
  m=manifest();other=copy.deepcopy(m['files'][0]);other['canonicalId']='tt124';other['destination']='Movies/Other/file.mkv';m['files'].append(other);self.rejected(m)
 def test_destination_race_preserves_new_existing_file(self):
  @contextlib.contextmanager
  def response(url):
   yield Response()
   (self.root/'Movies/Fixture/file.mkv').write_bytes(b'concurrent')
  with self.assertRaises(Rejected):run(manifest(),self.root,self.state,self.provider,response,lambda p:worker.RESERVE+100)
  self.assertEqual((self.root/'Movies/Fixture/file.mkv').read_bytes(),b'concurrent')
 def test_parent_symlink_swap_refused(self):
  outside=self.base/'outside';outside.mkdir()
  def resolve(row):
   (self.root/'Movies/Fixture').rename(self.root/'held')
   (self.root/'Movies/Fixture').symlink_to(outside)
   return 'https://fixture.invalid/file'
  self.provider.resolve=resolve
  with self.assertRaises(Rejected):self.execute()
  self.assertEqual(list(outside.iterdir()),[])
 def test_complete_atomic_publication(self):
  r=self.execute();self.assertEqual(r['mediaBytes'],4);self.assertEqual((self.root/'Movies/Fixture/file.mkv').read_bytes(),b'data');self.assertFalse((self.root/'Movies/Fixture/file.mkv.part').exists())
 def test_existing_file_preserved_no_provider_call(self):
  p=self.root/'Movies/Fixture/file.mkv';p.parent.mkdir(parents=True);p.write_bytes(b'old')
  with self.assertRaises(Rejected):self.execute()
  self.assertEqual(p.read_bytes(),b'old');self.assertEqual(self.provider.calls,0)
 def test_existing_partial_preserved(self):
  p=self.root/'Movies/Fixture/file.mkv.part';p.parent.mkdir(parents=True);p.write_bytes(b'old')
  with self.assertRaises(Rejected):self.execute()
  self.assertEqual(p.read_bytes(),b'old')
 def test_symlink_parent_refused(self):
  outside=self.base/'outside';outside.mkdir();(self.root/'Movies').symlink_to(outside)
  with self.assertRaises(Rejected):self.execute()
  self.assertEqual(list(outside.iterdir()),[])
 def test_storage_reserve(self):
  with self.assertRaises(Rejected):self.execute(free=worker.RESERVE+3)
  self.assertEqual(self.provider.calls,0)
 def test_storage_exact_boundary(self):self.execute(free=worker.RESERVE+4)
 def test_truncated_keeps_partial(self):
  with self.assertRaises(Rejected):self.execute(response=Response(b'da'))
  self.assertEqual((self.root/'Movies/Fixture/file.mkv.part').read_bytes(),b'da')
 def test_oversized_stops_one_extra_byte(self):
  response=Response(b'dataMORE')
  with self.assertRaises(Rejected):self.execute(response=response)
  receipts=[json.loads(p.read_text()) for p in self.state.glob('run-*.json')];self.assertEqual(receipts[0]['mediaBytes'],5)
 def test_unknown_or_wrong_length(self):
  for length in ['', '5']:
   with tempfile.TemporaryDirectory() as d:
    with self.assertRaises(Rejected):run(manifest(),self.root,Path(d),self.provider,lambda u:Response(length=length),lambda p:worker.RESERVE+100)
   partial=self.root/'Movies/Fixture/file.mkv.part'
   if partial.exists():partial.unlink() # fixture reset only
 def test_encoding_rejected(self):
  with self.assertRaises(Rejected):self.execute(response=Response(encoding='gzip'))
 def test_exclusive_lock(self):
  with job_lock(self.state):
   with self.assertRaises(Rejected):self.execute()
 def test_receipts_no_signed_url(self):self.execute();self.assertNotIn('secret-signed-url',''.join(p.read_text() for p in self.state.glob('*.json')))
 def test_dry_validation_no_credential_or_network(self):
  with patch('worker.existing_key',side_effect=AssertionError),patch('worker.https_get',side_effect=AssertionError):validate_manifest(manifest())
 def test_installer_hashes_no_start_or_credentials(self):
  bundle=Path(__file__).parent
  with patch('worker.existing_key',side_effect=AssertionError):r=install(bundle,self.base/'install',self.base/'newmedia',manifest())
  self.assertFalse(r['started']);self.assertFalse(r['credentialAccess'])
 def test_installer_existing_target_refused(self):
  with self.assertRaises(Rejected):install(Path(__file__).parent,self.state,self.base/'newmedia',manifest())
 def test_installer_tampered_bundle_refused(self):
  d=self.base/'bundle';d.mkdir()
  for name in ['worker.py','install.py','bundle-hashes.json']:(d/name).write_bytes((Path(__file__).parent/name).read_bytes())
  (d/'worker.py').write_text('tampered')
  with self.assertRaises(Rejected):install(d,self.base/'install',self.base/'newmedia',manifest())
  self.assertFalse((self.base/'install').exists())
 def test_installer_pending_manifest_refused(self):
  m=manifest();m['approved']=False
  with self.assertRaises(Rejected):install(Path(__file__).parent,self.base/'install',self.base/'newmedia',m)
class CredentialFixtureTests(unittest.TestCase):
 def config(self,keys,host='comet.elfhosted.com'):
  t=tempfile.TemporaryDirectory();self.addCleanup(t.cleanup);p=Path(t.name)/'fixture.json'
  parts=[base64.urlsafe_b64encode(json.dumps({'debridService':'torbox','debridApiKey':k}).encode()).decode().rstrip('=') for k in keys]
  p.write_text(json.dumps({'addons':[{'transportUrl':'https://'+host+'/'+x+'/manifest.json'} for x in parts]}));return p
 def test_synthetic_existing_key_only(self):self.assertEqual(worker.existing_key(self.config(['synthetic-only'])),'synthetic-only')
 def test_ambiguous_existing_keys_rejected(self):
  with self.assertRaises(Rejected):worker.existing_key(self.config(['a','b']))
 def test_lookalike_domain_rejected(self):
  with self.assertRaises(Rejected):worker.existing_key(self.config(['a'],'comet.elfhosted.com.invalid'))
 def test_deduplicated_same_key(self):self.assertEqual(worker.existing_key(self.config(['a','a'])),'a')

class ProviderTests(unittest.TestCase):
 def provider(self,**overrides):
  p=Provider('synthetic');t={'id':12,'download_finished':True,'download_present':True,'files':[{'id':3,'name':'file.mkv','size':4,'infected':False,'zipped':False}]};t.update(overrides);calls=[]
  def api(endpoint,query,bearer=False):calls.append(endpoint);return [t] if endpoint=='mylist' else 'https://fixture.invalid/media'
  p._api=api;return p,calls,t
 def test_completed_identity_only_two_gets(self):p,c,t=self.provider();p.resolve(manifest()['files'][0]);self.assertEqual(c,['mylist','requestdl'])
 def test_incomplete_no_link(self):
  for field in ['download_finished','download_present']:
   p,c,t=self.provider(**{field:False})
   with self.assertRaises(Rejected):p.resolve(manifest()['files'][0])
   self.assertEqual(c,['mylist'])
 def test_size_filename_and_safety_mismatch(self):
  for field,value in [('size',5),('name','other'),('infected',True),('zipped',None)]:
   p,c,t=self.provider();t['files'][0][field]=value
   with self.assertRaises(Rejected):p.resolve(manifest()['files'][0])
   self.assertEqual(c,['mylist'])
 def test_api_size_limit(self):
  response=Response(b'x'*2_000_001)
  with patch('worker.https_get',return_value=response):
   with self.assertRaises(Rejected):Provider('synthetic')._api('mylist',{'id':12},True)
 def test_inventory_uses_fixed_torbox_endpoint(self):
  with patch('worker.https_get',return_value=Response(json.dumps({'success':True,'data':[]}).encode())) as get:
   Provider('synthetic')._api('mylist',{'id':12},True)
   url,headers=get.call_args.args;self.assertEqual(url,'https://api.torbox.app/v1/api/torrents/mylist?id=12');self.assertEqual(headers,{'Authorization':'Bearer synthetic'})
 def test_redirect_response_rejected(self):
  # Transport guard rejects all non200 statuses without a second request.
  conn=unittest.mock.MagicMock();conn.getresponse.return_value.status=302
  with patch('worker.socket.getaddrinfo',return_value=[(0,0,0,0,('8.8.8.8',443))]),patch('worker.socket.create_connection'),patch('worker.http.client.HTTPSConnection',return_value=conn):
   with self.assertRaises(Rejected):
    with worker.https_get('https://fixture.invalid/path'):pass
  self.assertEqual(conn.request.call_count,1)
 def test_private_target_no_socket(self):
  with patch('worker.socket.getaddrinfo',return_value=[(0,0,0,0,('127.0.0.1',443))]),patch('worker.socket.create_connection') as connect:
   with self.assertRaises(Rejected):
    with worker.https_get('https://fixture.invalid/path'):pass
   connect.assert_not_called()
if __name__=='__main__':unittest.main()
