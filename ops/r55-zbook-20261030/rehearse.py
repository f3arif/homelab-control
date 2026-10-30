"""Run pinned R55 tests on ZBook; production is read-only, fixtures disposable."""
from contextlib import redirect_stdout,redirect_stderr
import datetime,hashlib,importlib.metadata,json,os,shutil,socket,subprocess,sys,tempfile,time,unittest
from pathlib import Path
from unittest.mock import patch
REPO=Path(__file__).resolve().parents[2]
SERVICE=REPO/'services/movie-night-review-ui'
LIVE=Path('/home/coolyo/afz-stremio-secondhost-20260918')
VOLUME=Path('/srv/afzmedia');OUT=Path(__file__).parent
EXPECTED='8f666286e603a1d16b75fb324e6a209e967b3687'
assert Path('/home/coolyo/AFZ/QA') in REPO.parents and (REPO/'.git').is_file()
subprocess.run(['git','diff','--exit-code',EXPECTED,'--','services/movie-night-review-ui/src','services/movie-night-review-ui/gateway','services/movie-night-review-ui/tests'],cwd=REPO,check=True,stdout=subprocess.DEVNULL)
assert sys.argv[1:]==['--disposable-ntfs'], 'explicit fixture permission required'
sys.path[:0]=[str(SERVICE/'src'),str(SERVICE/'gateway'),str(SERVICE/'tests')]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None
def pid():return subprocess.check_output(['systemctl','--user','show','afz-movie-night-review.service','--property=MainPID','--value'],text=True).strip()
def snapshot():
 files={n:sha(LIVE/'movie-night-review-service/src'/n) for n in ('adapters.py','webapp.py','auto_downloads.py','review_service.py','server_file_delete.py')}
 files.update({n:sha(LIVE/'state/movie-night-review'/n) for n in ('preferences.sqlite3','download-index.sqlite3')})
 rows=[]
 for p in sorted((VOLUME/'Media/MovieNight/Movies').iterdir()):
  s=p.lstat();rows.append((p.name,s.st_size,s.st_mtime_ns,s.st_ino))
 return {'mainPID':pid(),'fileHashes':files,'movieEntryCount':len(rows),'movieMetadataHash':hashlib.sha256(json.dumps(rows).encode()).hexdigest()}
before=snapshot()
entries=Path('/proc/'+before['mainPID']+'/environ').read_bytes().split(b'\0')
os.environ['PATH']=next(x[5:].decode() for x in entries if x.startswith(b'PATH='))
original=socket.socket.connect
def local_only(sock,address):
 if isinstance(address,tuple):
  if address[0] not in ('127.0.0.1','localhost','::1'):raise AssertionError('Outbound network forbidden')
 elif not Path(os.fsdecode(address)).resolve().is_relative_to('/tmp'):
  raise AssertionError('Only temporary Unix sockets allowed')
 return original(sock,address)
def run(label,pattern):
 start=time.monotonic()
 with (OUT/(label+'.log')).open('w') as log,redirect_stdout(log),redirect_stderr(log),patch.object(socket.socket,'connect',local_only):
  suite=unittest.defaultTestLoader.discover(str(SERVICE/'tests'),pattern=pattern)
  result=unittest.TextTestRunner(stream=log,verbosity=2).run(suite)
 r={'scope':label,'tests':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'skipped':len(result.skipped),'passed':result.wasSuccessful(),'seconds':round(time.monotonic()-start,3),'failingTests':[str(t) for t,_ in result.failures+result.errors]}
 print(json.dumps(r),flush=True);return r
results=[run('zbook-runtime-e2e','test_server_delete_e2e.py'),run('zbook-runtime-full','test_*.py')]
mount=subprocess.check_output(['findmnt','-T',str(VOLUME),'-n','-o','TARGET,FSTYPE,OPTIONS'],text=True).split()
assert mount[0]==str(VOLUME) and mount[1]=='ntfs3' and 'rw' in mount[2].split(',')
# New random private directory, NOT the real Media/MovieNight directory.
with tempfile.TemporaryDirectory(prefix='.afz-r55-disposable-',dir=VOLUME) as fresh:
 location=Path(fresh)
 assert location.parent==VOLUME and not location.is_symlink() and not any(location.iterdir())
 assert location.stat().st_dev==VOLUME.stat().st_dev
 old=tempfile.tempdir
 try:
  tempfile.tempdir=str(location)
  results.append(run('zbook-ntfs-delete-fixtures','test_server_file_delete.py'))
 finally:tempfile.tempdir=old
after=snapshot();versions={}
for name in ('fastapi','uvicorn','starlette','httpx','httpx2','requests'):
 try:versions[name]=importlib.metadata.version(name)
 except importlib.metadata.PackageNotFoundError:versions[name]=None
record={'atUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sourceCommit':EXPECTED,'host':'afz-zbook','python':sys.version.split()[0],'dependencies':versions,'ffmpegAvailableInServicePATH':bool(shutil.which('ffmpeg')),'ffprobeAvailableInServicePATH':bool(shutil.which('ffprobe')),'results':results,'liveStateUnchanged':before==after,'productionMediaDeleted':False,'productionServicesRestarted':False,'defaultOffUntouched':True,'ntfsFixtureCleaned':not location.exists(),'before':before,'after':after}
(OUT/'receipt.json').write_text(json.dumps(record,indent=2))
print('REHEARSAL_RECEIPT '+json.dumps(record),flush=True)
sys.exit(0 if all(r['passed'] for r in results) and before==after and not location.exists() else 1)
