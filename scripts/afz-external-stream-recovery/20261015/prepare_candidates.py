"""Build isolated candidates; never overwrite deployed files during preparation."""
from pathlib import Path
import ast,hashlib,json,shutil,subprocess
HERE=Path(__file__).resolve().parent
ROOT=Path(r'C:\AFZ\Stremio-Failover-H3')
LIVE_BRIDGE=Path(r'C:\Users\Faiz\AFZ-Stremio-Mobile-Order\bridge.mjs')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
catalog=ROOT/'stremio_catalog.py'
text=catalog.read_text(encoding='utf-8')
tree=ast.parse(text)
fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='_external_resolved_url')
lines=text.splitlines(keepends=True)
text=''.join(lines[:fn.lineno-1])+(HERE/'external-resolver-function.py').read_text(encoding='utf-8')+'\n'+''.join(lines[fn.end_lineno:])
assert '_external_history=SourceHistory' not in text
anchor='def _persist_external_source_cache():'
assert text.count(anchor)==1
text=text.replace(anchor,(HERE/'catalog-hook.txt').read_text(encoding='utf-8')+anchor)
needle="        tmp=EXTERNAL_SOURCE_CACHE_FILE.with_suffix('.tmp')"
assert text.count(needle)==1
text=text.replace(needle,"        _external_history.remember_many(obj['rows'])\n"+needle)
ast.parse(text)
(HERE/'stremio_catalog.candidate.py').write_text(text,encoding='utf-8')
receipts={'catalog':{'path':str(catalog),'before':sha(catalog)},
          'bridges':[]}
for i,p in enumerate([LIVE_BRIDGE,ROOT/'bridge.mjs']):
 s=p.read_text(encoding='utf-8')
 assert 'async function getExternalSourceCollection' not in s
 anchor="async function externalStreams(imdbId,mediaType='movie'){"
 assert s.count(anchor)==1
 head,tail=s.split(anchor)
 tail=tail.replace('const addons=await getCollection();','const addons=await getExternalSourceCollection();',1)
 s=head+(HERE/'bridge-hook.txt').read_text(encoding='utf-8')+anchor+tail
 out=HERE/('bridge-live.candidate.mjs' if i==0 else 'bridge-core.candidate.mjs')
 out.write_text(s,encoding='utf-8')
 check=subprocess.run([r'C:\Program Files\nodejs\node.exe','--check',str(out)],capture_output=True,text=True)
 assert check.returncode==0,check.stderr
 receipts['bridges'].append({'path':str(p),'before':sha(p),'candidate':out.name})
receipts['catalog']['candidate']='stremio_catalog.candidate.py'
(HERE/'candidate-receipt.json').write_text(json.dumps(receipts,indent=2),encoding='utf-8')
print(json.dumps({'ok':True,'catalogBefore':receipts['catalog']['before'],'bridgesChecked':2}))
