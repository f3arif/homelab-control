"""Offline reviewed installer. Never invoked on HP during preparation."""
from pathlib import Path
import argparse,hashlib,json,os
from worker import validate_manifest,Rejected,safe_directory

def install(bundle,target,media,manifest):
    bundle=Path(bundle);target=Path(target);media=Path(media)
    validate_manifest(manifest)
    if os.path.lexists(target) or os.path.lexists(media): raise Rejected('installation-destination-exists')
    safe_directory(target.parent);safe_directory(media.parent)
    hashes=json.loads((bundle/'bundle-hashes.json').read_text())
    if set(hashes)!={'worker.py','install.py'}: raise Rejected('unexpected-bundle-file')
    payload={name:(bundle/name).read_bytes() for name in hashes}
    for name,digest in hashes.items():
        if hashlib.sha256(payload[name]).hexdigest()!=digest: raise Rejected('bundle-hash-mismatch')
    target.mkdir(mode=0o700);media.mkdir(mode=0o700)
    for p in [target/'state',media/'Movies',media/'TV']:p.mkdir(mode=0o700)
    for name in hashes:
        with (target/name).open('xb') as f:f.write(payload[name])
    with (target/'approved-manifest.json').open('x') as f:json.dump(manifest,f,indent=2)
    return {'installed':True,'started':False,'files':['worker.py','install.py','approved-manifest.json'],'credentialAccess':False}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--manifest',type=Path,required=True)
    a=p.parse_args()
    try: print(json.dumps(install(Path(__file__).parent,Path('/home/coolyo/afz-curation'),Path('/home/coolyo/afz-curated-media'),json.loads(a.manifest.read_text()))))
    except Exception as e:
        print(json.dumps({'ok':False,'code':str(e) if isinstance(e,Rejected) else 'sanitized-install-failure'}));raise SystemExit(1)
