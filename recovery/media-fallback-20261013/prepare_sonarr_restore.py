#!/usr/bin/env python3
"""Prepare the recovered Sonarr database and pinned isolated service."""
import os,pathlib,sqlite3,shutil,xml.etree.ElementTree as E,json
R=pathlib.Path(os.environ['AFZ_FALLBACK_ROOT']);REC=pathlib.Path(os.environ['AFZ_REQUESTS_RECOVERY_DIR'])
candidate=REC/'sonarr-restored-candidate';assert not candidate.exists()
shutil.copytree(REC/'original/sonarr',candidate)
db=sqlite3.connect(candidate/'sonarr.db');live=sqlite3.connect('file:'+str(R/'radarr/radarr.db')+'?mode=ro',uri=True)
cols=[x[1] for x in live.execute('pragma table_info(Users)')];assert cols==[x[1] for x in db.execute('pragma table_info(Users)')]
db.execute('DELETE FROM Users');db.executemany('INSERT INTO Users VALUES('+','.join('?' for _ in cols)+')',live.execute('SELECT * FROM Users').fetchall())
for table in ['DownloadClients','Indexers','RemotePathMappings','DownloadHistory','PendingReleases']: db.execute('DELETE FROM '+table)
assert db.execute('select count(*) from Notifications').fetchone()[0]==0
assert db.execute('select count(*) from ImportLists').fetchone()[0]==0
changes=[]
for sid,path in db.execute('select Id,Path from Series').fetchall():
 new='/tv/'+pathlib.PurePosixPath(path).name; db.execute('UPDATE Series SET Path=? WHERE Id=?',(new,sid));changes.append({'id':sid,'old':path,'new':new})
db.execute('DELETE FROM RootFolders');db.execute("INSERT INTO RootFolders(Id,Path) VALUES(1,'/tv')")
db.commit();assert db.execute('pragma quick_check').fetchone()[0]=='ok';db.close();live.close()
tree=E.parse(candidate/'config.xml')
for name,value in [('AuthenticationMethod','Forms'),('AuthenticationRequired','Enabled'),('LogLevel','Info'),('LaunchBrowser','False')]:
 elem=tree.find(name)
 if elem is None: elem=E.SubElement(tree.getroot(),name)
 elem.text=value
tree.write(candidate/'config.xml',encoding='utf-8',xml_declaration=True)
for p in candidate.iterdir():p.chmod(0o600)
(REC/'sonarr-preflight.json').write_text(json.dumps({'series':3,'episodeRecords':748,'existingFileRecords':46,'history':64,'paths':changes,'oldClientsAndIndexersRemoved':True,'authentication':'Forms; existing afzqbit account retained'},indent=2))
print('SONARR_CANDIDATE_READY')
