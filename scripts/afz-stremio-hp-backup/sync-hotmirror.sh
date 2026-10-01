#!/usr/bin/env bash
set -u
BASE=/home/coolyo/afz-stremio-hotmirror
SRC=/home/coolyo/afz-jellyfin-primary/mounts/afz-media
SEL="$BASE/config/selection.json"
LOG="$BASE/logs/sync.log"
STATUS="$BASE/state/status.json"
LOCK="$BASE/state/sync.lock"
mkdir -p "$BASE"/{Movies,TV,config,logs,state}
exec 9>"$LOCK"
flock -n 9 || exit 0

now(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
write_status(){
  python3 - "$STATUS" "$1" "$2" <<'PY'
import json,sys,datetime
p,status,detail=sys.argv[1:]
json.dump({
  "status":status,
  "detail":detail,
  "updatedUtc":datetime.datetime.now(datetime.timezone.utc).isoformat()
},open(p,"w"),indent=2)
PY
}

if ! mountpoint -q "$SRC"; then
  echo "[$(now)] source mount unavailable: $SRC" >>"$LOG"
  write_status blocked "source-mount-unavailable"
  exit 0
fi
if [ ! -d "$SRC/Movies" ] || [ ! -d "$SRC/TV" ] || [ ! -f "$SEL" ]; then
  echo "[$(now)] source or selection missing" >>"$LOG"
  write_status blocked "source-or-selection-missing"
  exit 0
fi

echo "[$(now)] START" >>"$LOG"
write_status running "copying-tv"
rsync -a --no-owner --no-group --partial --human-readable --stats   "$SRC/TV/" "$BASE/TV/" >>"$LOG" 2>&1 || {
    write_status failed "tv-rsync"
    exit 20
  }

write_status running "copying-movies"
python3 - "$SEL" <<'PY' | while IFS= read -r name; do
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8-sig"))
for x in d.get("selectedMovies",[]):
    print(x["name"])
PY
  [ -d "$SRC/Movies/$name" ] || {
    echo "[$(now)] SKIP missing movie: $name" >>"$LOG"
    continue
  }
  mkdir -p "$BASE/Movies/$name"
  echo "[$(now)] MOVIE $name" >>"$LOG"
  rsync -a --no-owner --no-group --partial --human-readable --stats     "$SRC/Movies/$name/" "$BASE/Movies/$name/" >>"$LOG" 2>&1 || {
      write_status failed "movie-rsync:$name"
      exit 21
    }
done

python3 - "$SEL" "$BASE" "$STATUS" <<'PY'
import json,sys,os,datetime
sel=json.load(open(sys.argv[1],encoding="utf-8-sig"))
base=sys.argv[2]
out=sys.argv[3]

def tree_bytes(p):
    total=0
    files=0
    for root,dirs,names in os.walk(p):
        for n in names:
            try:
                total += os.path.getsize(os.path.join(root,n))
                files += 1
            except OSError:
                pass
    return total,files

tv_b,tv_f=tree_bytes(os.path.join(base,"TV"))
movie_b=movie_f=0
missing=[]
for x in sel.get("selectedMovies",[]):
    p=os.path.join(base,"Movies",x["name"])
    if not os.path.isdir(p):
        missing.append(x["name"])
        continue
    b,f=tree_bytes(p)
    movie_b += b
    movie_f += f

ok=(not missing and tv_b==int(sel["tvBytes"]) and movie_b==int(sel["selectedMovieBytes"]))
json.dump({
  "status":"completed" if ok else "verify-mismatch",
  "updatedUtc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "selectedMovieCount":len(sel.get("selectedMovies",[])),
  "tvBytes":tv_b,
  "expectedTvBytes":int(sel["tvBytes"]),
  "movieBytes":movie_b,
  "expectedMovieBytes":int(sel["selectedMovieBytes"]),
  "tvFiles":tv_f,
  "movieFiles":movie_f,
  "missing":missing
},open(out,"w"),indent=2)
raise SystemExit(0 if ok else 30)
PY
rc=$?
echo "[$(now)] FINISH rc=$rc" >>"$LOG"
exit $rc
