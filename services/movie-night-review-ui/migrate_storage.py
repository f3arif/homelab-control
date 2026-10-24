"""One-time offline migration of a copied Movie Night state, preserving history.

Run only on the ZBook after stopped-state copy and verified media copy. Source
Envy files/state remain untouched. No source lookup or download is performed.
"""
import argparse
from hashlib import sha256
import json
from pathlib import Path
import sqlite3
import time
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent/'src'))
from movie_night import ROOT
from storage_volume import MediaVolume


def file_hash(path):
    result=sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(4*1024*1024),b''):result.update(block)
    return result.hexdigest()


def migrate(state, volume, expected_files):
    state=Path(state);root=volume.ensure()
    for row in expected_files:
        rel=Path(row['target'])
        if rel.is_absolute() or '..' in rel.parts:raise ValueError('Unsafe migration target')
        path=root/rel
        if path.is_symlink() or path.stat().st_size!=row['size'] or file_hash(path)!=row['sha256']:
            raise ValueError('Copied media did not verify')
    db=sqlite3.connect(state/'preferences.sqlite3')
    try:
        db.execute('ATTACH DATABASE ? AS media_index',(str(state/'download-index.sqlite3'),))
        db.execute('BEGIN IMMEDIATE')
        if db.execute("SELECT COUNT(*) FROM jobs WHERE state IN ('approved','downloading')").fetchone()[0]:
            raise ValueError('Active jobs; stop safely before migration')
        if db.execute("SELECT COUNT(*) FROM movie_download_queue WHERE state IN ('queued','checking')").fetchone()[0]:
            raise ValueError('Active source requests; stop safely before migration')
        db.execute('CREATE TABLE IF NOT EXISTS storage_migrations(id TEXT PRIMARY KEY,details TEXT NOT NULL)')
        if db.execute("SELECT 1 FROM storage_migrations WHERE id='8tb-20261024'").fetchone():
            raise ValueError('Migration already recorded')
        db.execute('CREATE TABLE IF NOT EXISTS archived_jobs(id TEXT PRIMARY KEY,title TEXT,destination TEXT,payload TEXT,state TEXT,bytes INTEGER,evidence TEXT,reason TEXT,archived INTEGER)')
        archived=0;completed=0
        for row in db.execute('SELECT * FROM jobs').fetchall():
            pid,title,destination,payload,status,count,evidence=row
            if status in ('indexed','downloaded','playback-tested'):
                path=root/'Movies'/Path(destination).name
                proof=json.loads(evidence);size=json.loads(payload)['choice']['size']
                if not any(x['target']=='Movies/'+path.name and x['size']==size and x['sha256']==proof['file']['sha256'] for x in expected_files):
                    raise ValueError('Completed job missing verified copy')
                new=str(path)
                data=json.loads(payload);data['choice']['destination']=new
                proof['file']['destination']=new
                db.execute('UPDATE jobs SET destination=?,payload=?,evidence=? WHERE id=?',(new,json.dumps(data),json.dumps(proof),pid))
                # Preserve the original bound plan as authorization history.
                meta=db.execute('SELECT metadata FROM media_index.media WHERE id=?',(title,)).fetchone()
                if meta:
                    value=json.loads(meta[0]);value['destination']=new
                    db.execute('UPDATE media_index.media SET metadata=? WHERE id=?',(json.dumps(value),title))
                completed+=1
            elif status=='cancelled':
                db.execute('INSERT INTO archived_jobs VALUES(?,?,?,?,?,?,?,?,?)',(*row,'Paused for owner-requested 8 TB / 5–15 GB migration',int(time.time())))
                db.execute('DELETE FROM jobs WHERE id=?',(pid,))
                db.execute("UPDATE movie_download_queue SET job_id=NULL,state='failed',message='Moved to the 8 TB drive. Retry to find a 5–15 GB file; the previous partial is preserved.',updated=? WHERE job_id=?",(int(time.time()),pid))
                archived+=1
            else:raise ValueError('Unexpected job; manual review required')
        details=dict(completed=completed,archived=archived,files=expected_files)
        db.execute("INSERT INTO storage_migrations VALUES('8tb-20261024',?)",(json.dumps(details),))
        db.commit();return dict(completed=completed,archived=archived,files=len(expected_files))
    except Exception:db.rollback();raise
    finally:db.close()


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--state',required=True);p.add_argument('--receipt',required=True)
    a=p.parse_args();print(json.dumps(migrate(a.state,MediaVolume(),json.loads(Path(a.receipt).read_text()))))
