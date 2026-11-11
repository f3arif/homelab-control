"""Apply the reviewed H3 R55 fixes only to unchanged PR323 base source.

Run in an isolated checkout, never against the production service directories.
Only the four explicitly named source files below may be changed.
"""
from pathlib import Path
import subprocess

REPO=Path(__file__).resolve().parents[2]
ROOT=REPO/'services/movie-night-review-ui'
BASE='c6fe9a6e71ce8d510136da1289fd938c4e6bacd6'
PREFIX='services/movie-night-review-ui/'


def apply(path,replacements):
    p=ROOT/path
    expected=subprocess.check_output(['git','show',BASE+':'+PREFIX+path],cwd=REPO)
    if p.read_bytes()!=expected:
        raise RuntimeError('Refusing source drift: '+path)
    content=expected.decode()
    for before,after in replacements:
        if content.count(before)!=1:
            raise RuntimeError('Non-unique source target: '+path+' '+before[:70])
        content=content.replace(before,after)
    p.write_text(content)
    print('PATCHED',path)


apply('src/adapters.py',[
('    def register(self, choice, proof):\n','''    def removed_ids(self):
        # Read tombstones even with destructive endpoints disabled.
        with sqlite3.connect(f"file:{self.db}?mode=ro", uri=True) as c:
            if not c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='removed_media'").fetchone():
                return set()
            return {row[0] for row in c.execute('SELECT id FROM removed_media')}

    def require_not_removed(self, imdb):
        if imdb in self.removed_ids():
            raise ValueError('Owner intentionally removed server copy; no automatic re-download')

    def register(self, choice, proof):
'''),
("            choice=Choice(**json.loads(row[0])['choice']).validate()\n            if self.storage_guard:self.storage_guard()\n","            choice=Choice(**json.loads(row[0])['choice']).validate()\n            # Reject stale jobs before provider resolution or transfer.\n            self.index.require_not_removed(choice.imdb)\n            if self.storage_guard:self.storage_guard()\n"),
])

apply('src/webapp.py',[
('    def require_enabled(self):\n','''    def removed_media_ids(self):
        reader = getattr(self.index, 'removed_ids', None)
        return reader() if callable(reader) else set()

    def require_not_removed(self, imdb):
        if imdb in self.removed_media_ids():
            raise ValueError('Owner intentionally removed server copy; no automatic re-download')

    def removed_status(self, status, imdb):
        if imdb in self.removed_media_ids():
            return dict(status, state='removed', downloaded=False, indexed=False,
                        playbackTested=False, processing=False)
        return status

    def require_enabled(self):
'''),
("            queued=[x[0] for x in store.db.execute(\"SELECT id FROM jobs WHERE state='approved'\")]\n","            removed=self.removed_media_ids()\n            queued=[]\n            for pid, imdb in store.db.execute(\"SELECT id,title FROM jobs WHERE state='approved'\").fetchall():\n                if imdb in removed:store.transition(pid,'failed')\n                else:queued.append(pid)\n"),
("    def prepare(self,imdb,principal):\n        self.require_enabled();self.require_finalized(imdb,principal)\n","    def prepare(self,imdb,principal):\n        self.require_enabled();self.require_finalized(imdb,principal)\n        self.require_not_removed(imdb)\n"),
("        future=entry[3]\n        if not future.done():","        self.require_not_removed(entry[1])\n        future=entry[3]\n        if not future.done():"),
("            removed=self.delete_service.removed_ids() if self.delete_service else set()\n","            removed=self.removed_media_ids()\n"),
("    def propose(self, imdb, principal):\n        self.require_enabled()\n        self.require_finalized(imdb,principal)\n","    def propose(self, imdb, principal):\n        self.require_enabled()\n        self.require_finalized(imdb,principal)\n        self.require_not_removed(imdb)\n"),
("        current=self.inventory.verify(choice)\n        if current!=choice:","        current=self.inventory.verify(choice)\n        self.require_not_removed(imdb)\n        if current!=choice:"),
("                return store.approve(pid,binding,principal,reply,choice,int(self.clock()),int(self.clock()),self.free(),completed_present=True)\n            self.require_finalized(choice.imdb,principal)\n","                result=store.approve(pid,binding,principal,reply,choice,int(self.clock()),int(self.clock()),self.free(),completed_present=True)\n                return self.removed_status(result,choice.imdb)\n            self.require_not_removed(choice.imdb)\n            self.require_finalized(choice.imdb,principal)\n"),
("            return {**status,'processing':bool(future and not future.done())}\n","            row=store.db.execute('SELECT title FROM jobs WHERE id=?',(pid,)).fetchone()\n            result={**status,'processing':bool(future and not future.done())}\n            return self.removed_status(result,row[0]) if row else result\n"),
("                     'Server deletion is unavailable.','Owner session unavailable.',\n","                     'Server deletion is unavailable.','Owner session unavailable.',\n                     'Owner intentionally removed server copy; no automatic re-download',\n"),
("        if set(data) != {'imdb','confirmationToken','confirmedTitle'}:\n            raise HTTPException(400,'Invalid deletion confirmation')\n","        if (set(data) != {'imdb','confirmationToken','confirmedTitle'}\n                or not all(isinstance(data[k],str) for k in ('imdb','confirmationToken','confirmedTitle'))\n                or not 1 <= len(data['confirmedTitle']) <= 200\n                or not 1 <= len(data['confirmationToken']) <= 128):\n            raise HTTPException(400,'Invalid deletion confirmation')\n"),
])

apply('src/auto_downloads.py',[
("        now=int(self.c.clock())\n        for imdb in ids:\n","        now=int(self.c.clock())\n        removed=self.c.removed_media_ids()\n        for imdb in ids:\n            if imdb in removed:\n                db.execute('INSERT OR IGNORE INTO movie_download_queue VALUES(?,?,?,?,?,NULL,?,?)',\n                           (str(uuid4()),principal,imdb,rows[imdb]['name'],'removed','Removed from your 8 TB server.',now))\n                db.execute(\"UPDATE movie_download_queue SET state='removed',message='Removed from your 8 TB server.',updated=? WHERE principal=? AND imdb=?\",(now,principal,imdb))\n                continue\n"),
("        self.c.require_enabled();self.c.require_finalized(imdb,principal)\n","        self.c.require_enabled();self.c.require_finalized(imdb,principal)\n        self.c.require_not_removed(imdb)\n"),
("                message='Source service unavailable. Try again later.'\n","                if str(exc)=='Owner intentionally removed server copy; no automatic re-download':\n                    self._finish(request_id,'removed','Removed from your 8 TB server.')\n                    continue\n                message='Source service unavailable. Try again later.'\n"),
])

apply('src/review_service.py',[
('def build_app(state, origin, discovery=None, downloads=False, provider=None, media_root=None, auto_downloads=False, volume=None):\n','def build_app(state, origin, discovery=None, downloads=False, provider=None, media_root=None, auto_downloads=False, volume=None, server_delete=False):\n'),
("    if auto_downloads and not downloads:raise ValueError('Automatic downloads require --downloads')\n","    if auto_downloads and not downloads:raise ValueError('Automatic downloads require --downloads')\n    if server_delete and not downloads:raise ValueError('Server deletion requires --downloads')\n"),
('        from server_file_delete import ServerFileDeletion\n        controller.delete_service=ServerFileDeletion(index,controller.db,clock=controller.clock)\n','        if server_delete:\n            from server_file_delete import ServerFileDeletion\n            controller.delete_service=ServerFileDeletion(index,controller.db,clock=controller.clock)\n'),
("                        (downloads and r.path in DOWNLOAD_GET and r.methods == {'GET'}) or\n","                        (downloads and r.path in DOWNLOAD_GET and r.methods == {'GET'}) or\n                        (server_delete and r.path in DELETE_GET and r.methods == {'GET'}) or\n"),
("                        (r.path in POST_PATHS | (DOWNLOAD_POST if downloads else set()) and r.methods == {'POST'})]\n","                        (r.path in POST_PATHS | (DOWNLOAD_POST if downloads else set()) | (DELETE_POST if server_delete else set()) and r.methods == {'POST'})]\n"),
("    parser.add_argument('--auto-downloads', action='store_true')\n","    parser.add_argument('--auto-downloads', action='store_true')\n    parser.add_argument('--server-delete', action='store_true', help='Explicitly activate owner-confirmed server deletion after approval')\n"),
("    app, controller = build_app(state, args.origin, discovery=CinemetaDiscovery(), downloads=args.downloads, auto_downloads=args.auto_downloads)\n","    app, controller = build_app(state, args.origin, discovery=CinemetaDiscovery(), downloads=args.downloads, auto_downloads=args.auto_downloads, server_delete=args.server_delete)\n"),
("    '/movie-night/api/downloads','/movie-night/catalog/movie/downloaded.json',\n    '/movie-night/api/delete-server/{imdb}'))\nDOWNLOAD_POST=frozenset(('/movie-night/api/propose','/movie-night/api/approve',\n    '/movie-night/api/cancel','/movie-night/api/delete-server'))\n","    '/movie-night/api/downloads','/movie-night/catalog/movie/downloaded.json'))\nDOWNLOAD_POST=frozenset(('/movie-night/api/propose','/movie-night/api/approve','/movie-night/api/cancel'))\nDELETE_GET=frozenset(('/movie-night/api/delete-server/{imdb}',))\nDELETE_POST=frozenset(('/movie-night/api/delete-server',))\n"),
])
