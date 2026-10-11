from pathlib import Path
import subprocess,os,json,hashlib
root=Path('/home/faiz/afz-nuvio-r33-addon-setup-20261011')
stage=Path('/mnt/c/AFZ/Nuvio-Setup-20260923/R33-addon-setup-candidate')
source=json.loads((stage/'source.json').read_text())
index=Path('/home/faiz/.local/share/afz-build-output/r33-addon-setup-20261011/patch-verification.index')
assert not index.exists()
env=dict(os.environ,GIT_INDEX_FILE=str(index))
def git(*args):
    return subprocess.check_output(['git',*args],cwd=root,env=env,text=True).strip()
assert hashlib.sha256((stage/'r33-addon-setup.patch').read_bytes()).hexdigest()==source['patchSha256']
git('read-tree',source['baseCommit'])
git('apply','--cached','--check',str(stage/'r33-addon-setup.patch'))
git('apply','--cached',str(stage/'r33-addon-setup.patch'))
tree=git('write-tree')
expected=git('rev-parse',source['sourceCommit']+'^{tree}')
assert tree==expected
report=dict(patchSha256=source['patchSha256'],baseCommit=source['baseCommit'],sourceCommit=source['sourceCommit'],candidateTree=tree,exactTreeMatch=True)
(stage/'patch-apply-verification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
