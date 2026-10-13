import datetime,json,os,pathlib,shutil,sqlite3,subprocess,time,requests
ROOT=pathlib.Path(os.environ['AFZ_FALLBACK_ROOT'])
REC=pathlib.Path(os.environ['AFZ_REQUESTS_RECOVERY_DIR'])
NAME='afz-media-seerr-fallback-r1'
live=ROOT/'seerr'; previous=REC/'seerr-before-restore'; candidate=REC/'seerr-restored-candidate'
assert candidate.exists() and not previous.exists()
with sqlite3.connect(candidate/'db/db.sqlite3') as original_db:
    expected_owner=original_db.execute('select jellyfinUsername from user where id=1').fetchone()[0]
report={'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'STARTING','rollback_copy':str(previous)}
def save():
    (REC/'activation-receipt.json').write_text(json.dumps(report,indent=2))
save()
subprocess.run(['docker','stop','--time','30',NAME],check=True)
live.rename(previous)
try:
    shutil.copytree(candidate,live)
    subprocess.run(['docker','start',NAME],check=True)
    cfg=json.loads((live/'settings.json').read_text())
    deadline=time.monotonic()+420
    while time.monotonic()<deadline:
        try:
            r=requests.get('http://127.0.0.1:18799/api/v1/settings/public',timeout=5)
            if r.status_code==200 and r.json().get('initialized'):
                hdr={'X-Api-Key':cfg['main']['apiKey']}
                users=requests.get('http://127.0.0.1:18799/api/v1/user',params={'take':100},headers=hdr,timeout=12)
                requests_list=requests.get('http://127.0.0.1:18799/api/v1/request',params={'take':1},headers=hdr,timeout=12)
                users.raise_for_status();requests_list.raise_for_status()
                u=users.json();q=requests_list.json()
                owner=next(x for x in u['results'] if x['id']==1)
                assert owner['jellyfinUsername']==expected_owner
                assert u['pageInfo']['results']==3 and q['pageInfo']['results']==63
                report.update(status='RESTORED',completed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),initialized=True,user_count=u['pageInfo']['results'],request_count=q['pageInfo']['results'],owner_id=1,owner_username=expected_owner,request_url=cfg['main']['applicationUrl'])
                save();print(json.dumps(report),flush=True);break
        except (requests.RequestException,ValueError,KeyError,AssertionError):
            pass
        time.sleep(5)
    else:
        raise RuntimeError('Restored Requests did not pass owner/history validation within 420 seconds')
except Exception as exc:
    subprocess.run(['docker','stop','--time','30',NAME],check=False)
    if live.exists(): live.rename(REC/'seerr-failed-activation')
    previous.rename(live)
    subprocess.run(['docker','start',NAME],check=True)
    report.update(status='ROLLED_BACK',error=str(exc));save();print(json.dumps(report),flush=True)
    raise
