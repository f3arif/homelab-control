#!/usr/bin/env bash
# One-file owner-private Movie Night Stremio addon rollout: no user state, media,
# provider, app or Tailscale route changes. Only the existing owner gateway restarts.
set -Eeuo pipefail
umask 077
ROOT=/home/coolyo/afz-stremio-secondhost-20260918
PRIVATE="$ROOT/state/movie-night-access"
TARGET="$ROOT/movie-night-access-service"
STAGE="$PRIVATE/nuvio-ready-20261027"
BACKUP_ROOT="$PRIVATE/rollback"
UNIT=afz-movie-night-access.service
OLD_SERVER=23c20baa9697a945485d40f6145459fce126e124a782fd34782505fe81a9ee66
OLD_GATEWAY=a3926c12233f02a2cebf04fc16326fb9fbedcdb9302311f9ae39ebd4d6b72bf3
NEW_SERVER=e1b576bbf38fefb76bd17d245e08f66af77750e74d03bd9bb76ebb84460c6b00
NEW_GATEWAY=06533a43fdfba98d4db92e2734ea74e6e1893626677acc6ab7afa2a70a1db967
NEW_CATALOG=8b9d68c4ac0e6b72b8a22e4f13f0dad579a4fa4787736f8ffb3d7ef3dfc3748a
sha() { sha256sum "$1" | cut -d ' ' -f 1; }
require_hash() {
    local actual
    actual="$(sha "$1")"
    test "$actual" = "$2" || { echo "REFUSED: unexpected file hash on $1" >&2; return 1; }
}
install -d -m 700 "$BACKUP_ROOT"
exec 9>"$PRIVATE/.nuvio-ready-install.lock"
flock -n 9 || { echo "REFUSED: another gateway operation is running" >&2; exit 75; }
require_hash "$TARGET/standalone_server.py" "$OLD_SERVER"
require_hash "$TARGET/movie_gateway.py" "$OLD_GATEWAY"
test ! -e "$TARGET/nuvio_ready_catalog.py" || { echo "REFUSED: addon already present"; exit 75; }
require_hash "$STAGE/standalone_server.py" "$NEW_SERVER"
require_hash "$STAGE/movie_gateway.py" "$NEW_GATEWAY"
require_hash "$STAGE/nuvio_ready_catalog.py" "$NEW_CATALOG"
systemctl --user is-active --quiet "$UNIT"
systemctl --user cat "$UNIT" | grep -F -q "$TARGET/standalone_server.py"
test -S "$ROOT/state/movie-night-review/run/review.sock"
test -f "$PRIVATE/owner.json"
python3 -m py_compile "$STAGE/standalone_server.py" "$STAGE/movie_gateway.py" "$STAGE/nuvio_ready_catalog.py"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
rollback="$BACKUP_ROOT/nuvio-ready-$stamp"
test ! -e "$rollback"
install -d -m 700 "$rollback"
cp -p "$TARGET/standalone_server.py" "$TARGET/movie_gateway.py" "$rollback/"
require_hash "$rollback/standalone_server.py" "$OLD_SERVER"
require_hash "$rollback/movie_gateway.py" "$OLD_GATEWAY"
changed=0
undo_on_error() {
    rc=$?
    trap - ERR INT TERM
    if test "$changed" -eq 1; then
        cp "$rollback/standalone_server.py" "$TARGET/.standalone.rollback.$$"
        cp "$rollback/movie_gateway.py" "$TARGET/.gateway.rollback.$$"
        chmod 600 "$TARGET/.standalone.rollback.$$" "$TARGET/.gateway.rollback.$$"
        mv -f "$TARGET/.standalone.rollback.$$" "$TARGET/standalone_server.py"
        mv -f "$TARGET/.gateway.rollback.$$" "$TARGET/movie_gateway.py"
        rm -f "$TARGET/nuvio_ready_catalog.py"
        systemctl --user restart "$UNIT" || true
        echo "ROLLBACK: restored previous gateway code" >&2
    fi
    exit "$rc"
}
trap undo_on_error ERR INT TERM
changed=1
for file in nuvio_ready_catalog.py movie_gateway.py standalone_server.py; do
    cp "$STAGE/$file" "$TARGET/.$file.next.$$"
    chmod 600 "$TARGET/.$file.next.$$"
    mv -f "$TARGET/.$file.next.$$" "$TARGET/$file"
done
require_hash "$TARGET/standalone_server.py" "$NEW_SERVER"
require_hash "$TARGET/movie_gateway.py" "$NEW_GATEWAY"
require_hash "$TARGET/nuvio_ready_catalog.py" "$NEW_CATALOG"
systemctl --user restart "$UNIT"
systemctl --user is-active --quiet "$UNIT"
# Verify actual owner-authenticated local gateway, exact index parity and
# bounded media headers/1-byte response. Never read or print a movie body.
python3 - "$PRIVATE/owner.json" <<'PY'
import json, sys, time, urllib.request, urllib.error
owner=json.load(open(sys.argv[1],encoding='utf-8'))['owner_login']
host='hpenvy.tailc9bb62.ts.net:8453'
base='http://127.0.0.1:8767/movie-night/'
def read(path, headers=None, method='GET', max_bytes=120000, expect=200):
    vals={'Host':host,'Tailscale-User-Login':owner}
    if headers: vals.update(headers)
    req=urllib.request.Request(base+path,headers=vals,method=method)
    try:
        with urllib.request.urlopen(req,timeout=7) as response:
            body=response.read(max_bytes+1) if method!='HEAD' else b''
            status=response.status
            hdr=response.headers
    except urllib.error.HTTPError as e:
        status=e.code;body=b'';hdr=e.headers
    if status!=expect or len(body)>max_bytes: raise RuntimeError('acceptance failed for '+path)
    return body,hdr
for n in range(15):
    try: read('manifest.json');break
    except Exception:
        if n==14: raise
        time.sleep(0.4)
manifest=json.loads(read('manifest.json')[0])
if manifest.get('id')!='com.afzengineering.movienight.ready': raise RuntimeError('manifest identity mismatch')
a=json.loads(read('catalog/movie/downloaded.json')[0])
b=json.loads(read('catalog/movie/afz_movie_night_ready.json')[0])
ids=[row['id'] for row in b['metas']]
if len(ids)!=len(set(ids)) or set(ids)!={r['id'] for r in a['metas']}:
    raise RuntimeError('private catalog does not match indexed ready files')
if not ids: raise RuntimeError('no ready files to test')
test_id=ids[0]
streams=json.loads(read('stream/movie/'+test_id+'.json')[0])['streams']
if len(streams)!=1 or streams[0]['url']!='https://'+host+'/movie-night/media/'+test_id:
    raise RuntimeError('stream URL escaped owner-only gateway')
head=read('media/'+test_id,method='HEAD')[1]
if int(head.get('Content-Length','0'))<=0:raise RuntimeError('HEAD has no size')
media=read('media/'+test_id,headers={'Range':'bytes=0-0'},max_bytes=1,expect=206)[0]
if len(media)!=1:raise RuntimeError('Range GET not playable')
read('catalog/movie/afz_movie_night_ready.json',headers={'Tailscale-User-Login':'not-the-owner'},expect=403)
read('catalog/movie/afz_movie_night_ready.json',headers={'Origin':'https://evil.example'},expect=403)
read('catalog/movie/afz_movie_night_ready.json',headers={'Sec-Fetch-Site':'cross-site','Sec-Fetch-Mode':'cors','Sec-Fetch-Dest':'empty'},expect=403)
read('catalog/movie/afz_movie_night_ready/skip=40.json')
print('OWNER_GATEWAY_ACCEPTED ready_files='+str(len(ids))+' manifest=200 range=206 head=200 invalid_access=403')
PY
systemctl --user is-active --quiet "$UNIT"
trap - ERR INT TERM
echo "LIVE_NUVIO_READY_ADDON_ACCEPTED"
echo "ROLLBACK_DIR=$rollback"
echo "No prefs, downloads, media, backend, public addon, Nuvio APK, or Serve routes changed."
