import datetime, hashlib, json, os, pathlib, shutil, sqlite3, zipfile
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
root=pathlib.Path(os.environ.get('AFZ_RECOVERY_ROOT', r'C:\AFZ\Recovery'))/('WindowsMain-Requests-'+stamp)
root.mkdir(parents=True,exist_ok=False)
sources={'jellyseerr':pathlib.Path(os.environ.get('AFZ_OLD_JELLYSEERR_CONFIG', r'I:\Docker\Jellyseerr\config')),'radarr':pathlib.Path(os.environ.get('AFZ_OLD_RADARR_CONFIG', r'I:\Docker\radarr\config'))}
manifest=[]
for app,src in sources.items():
    if app=='jellyseerr':
        files=[p for p in src.iterdir() if p.is_file()]+list((src/'db').glob('*'))
    else:
        files=[src/'config.xml']+list(src.glob('radarr.db*'))
    for p in files:
        if not p.is_file() or p.is_symlink(): continue
        rel=p.relative_to(src); out=root/'raw'/app/rel
        out.parent.mkdir(parents=True,exist_ok=True)
        before=hashlib.sha256(p.read_bytes()).hexdigest()
        shutil.copy2(p,out)
        after=hashlib.sha256(p.read_bytes()).hexdigest()
        copied=hashlib.sha256(out.read_bytes()).hexdigest()
        if not before==after==copied: raise RuntimeError('Source changed or copy failed: '+str(rel))
        manifest.append({'app':app,'path':str(rel),'bytes':out.stat().st_size,'sha256':copied})
report={'created_utc':stamp,'path':str(root),'source_unchanged':True,'files':manifest,'apps':{}}
for app,dbrel in [('jellyseerr',pathlib.Path('db/db.sqlite3')),('radarr',pathlib.Path('radarr.db'))]:
    raw=root/'raw'/app
    work=root/'inspection'/app
    shutil.copytree(raw,work)
    clean=root/'normalized'/app
    clean.mkdir(parents=True,exist_ok=True)
    settings='settings.json' if app=='jellyseerr' else 'config.xml'
    shutil.copy2(raw/settings,clean/settings)
    target=clean/dbrel; target.parent.mkdir(parents=True,exist_ok=True)
    conn=sqlite3.connect(str(work/dbrel))
    check=conn.execute('pragma quick_check').fetchone()[0]
    if check!='ok': raise RuntimeError(app+' integrity: '+check)
    dest=sqlite3.connect(str(target)); conn.backup(dest); dest.close()
    tables=[r[0] for r in conn.execute("select name from sqlite_master where type='table'")]
    info={'quick_check':check,'tables':tables}
    if app=='jellyseerr':
        cfg=json.loads((clean/settings).read_text(encoding='utf-8-sig'))
        info['settings']={'initialized':cfg.get('main',{}).get('initialized'),'mediaServerType':cfg.get('main',{}).get('mediaServerType'),
            'jellyfin':{k:cfg.get('jellyfin',{}).get(k) for k in ['ip','port','useSsl','urlBase','externalUrl','serverId']},
            'jellyfinTokenPresent':bool(cfg.get('jellyfin',{}).get('apiKey')),
            'radarr':[{k:x.get(k) for k in ['id','name','hostname','port','profileId','profileName','directory','is4k','isDefault','syncEnabled']} for x in cfg.get('radarr',[])],
            'sonarrCount':len(cfg.get('sonarr',[]))}
        for t in ['user','media','media_request','migrations']:
            if t in tables:
                info[t+'_count']=conn.execute('select count(*) from "'+t+'"').fetchone()[0]
        if 'user' in tables:
            cols=[r[1] for r in conn.execute('pragma table_info("user")')]
            safe=[c for c in ['id','displayName','username','userType','permissions','jellyfinUserId','createdAt'] if c in cols]
            info['users']=[dict(zip(safe,row)) for row in conn.execute('select '+','.join('"'+c+'"' for c in safe)+' from "user"')]
        if 'media_request' in tables:
            info['request_status_counts']=conn.execute('select status,count(*) from media_request group by status').fetchall()
    else:
        for t in ['Movies','QualityProfiles','DownloadClients','RootFolders']:
            if t in tables: info[t+'_count']=conn.execute('select count(*) from "'+t+'"').fetchone()[0]
        if 'QualityProfiles' in tables:
            info['quality_profiles']=conn.execute('select Id,Name from QualityProfiles').fetchall()
        if 'RootFolders' in tables: info['root_folders']=conn.execute('select Id,Path from RootFolders').fetchall()
    conn.close(); report['apps'][app]=info
(root/'recovery-inventory.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
bundle=root/'windows-main-requests-private.zip'
with zipfile.ZipFile(bundle,'w',zipfile.ZIP_DEFLATED) as z:
    for p in (root/'normalized').rglob('*'):
        if p.is_file(): z.write(p,p.relative_to(root/'normalized').as_posix())
print(json.dumps({'path':str(root),'archive':str(bundle),'archive_bytes':bundle.stat().st_size,'archive_sha256':hashlib.sha256(bundle.read_bytes()).hexdigest(),'source_files_copied':len(manifest),'source_unchanged':True,'apps':report['apps']},indent=2))
