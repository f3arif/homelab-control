#!/usr/bin/env bash
set -u
BASE=/home/coolyo/afz-stremio-hotmirror
SRC=/home/coolyo/afz-jellyfin-primary/mounts/afz-media
SEL="$BASE/config/selection.json"
LOG="$BASE/logs/sync.log"
STATUS="$BASE/state/status.json"
LOCK="$BASE/state/sync.lock"
HELPER="$BASE/hotmirror.py"
# Movie copies stop while free space would fall below this reserve.
RESERVE_BYTES="${AFZ_HOTMIRROR_RESERVE_BYTES:-$((40 * 1024 * 1024 * 1024))}"
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
if [ ! -d "$SRC/Movies" ] || [ ! -d "$SRC/TV" ]; then
  echo "[$(now)] source tree missing" >>"$LOG"
  write_status blocked "source-tree-missing"
  exit 0
fi

echo "[$(now)] START" >>"$LOG"
# Refresh the newest-first selection so new H3 movies are picked up. On failure
# the previous selection stays in place. Pruning runs only after a successful
# refresh in this same run; AFZ_HOTMIRROR_FREEZE_SELECTION=1 disables both.
PRUNE_ARG=()
if [ "${AFZ_HOTMIRROR_FREEZE_SELECTION:-0}" = 1 ]; then
  export AFZ_PRUNE_SKIP_REASON=frozen
elif python3 "$HELPER" select "$SRC" "$SEL" >>"$LOG" 2>&1; then
  PRUNE_ARG=(--prune)
else
  echo "[$(now)] selection refresh failed; keeping previous selection, no pruning" >>"$LOG"
  export AFZ_PRUNE_SKIP_REASON=selection-refresh-failed
fi
if [ ! -f "$SEL" ]; then
  write_status blocked "selection-missing"
  exit 0
fi

write_status running "copying-tv"
rsync -a --no-owner --no-group --partial --human-readable --stats "$SRC/TV/" "$BASE/TV/" >>"$LOG" 2>&1 || {
    write_status failed "tv-rsync"
    exit 20
  }

write_status running "copying-movies"
# Process substitution (not a pipe) so a failed rsync exits the script itself.
while IFS=$'\t' read -r name bytes; do
  [ -d "$SRC/Movies/$name" ] || {
    echo "[$(now)] SKIP missing movie: $name" >>"$LOG"
    continue
  }
  have=0
  [ -d "$BASE/Movies/$name" ] && have="$(du -sb "$BASE/Movies/$name" | cut -f1)"
  free="$(df -B1 --output=avail "$BASE" | tail -1 | tr -d ' ')"
  need=$(( bytes > have ? bytes - have : 0 ))
  if [ $(( free - need )) -lt "$RESERVE_BYTES" ]; then
    echo "[$(now)] LOW_DISK stop before $name need=$need free=$free reserve=$RESERVE_BYTES" >>"$LOG"
    write_status blocked "low-disk:$name"
    exit 0
  fi
  mkdir -p "$BASE/Movies/$name"
  echo "[$(now)] MOVIE $name" >>"$LOG"
  rsync -a --no-owner --no-group --partial --human-readable --stats "$SRC/Movies/$name/" "$BASE/Movies/$name/" >>"$LOG" 2>&1 || {
      write_status failed "movie-rsync:$name"
      exit 21
    }
done < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8-sig"))
for x in d.get("selectedMovies",[]):
    print(x["name"]+"\t"+str(int(x.get("bytes") or 0)))
' "$SEL")

# Re-check the mount right before verify/prune; a dropped mount is not "files removed".
if ! mountpoint -q "$SRC"; then
  echo "[$(now)] source mount lost before verify" >>"$LOG"
  write_status blocked "source-mount-lost"
  exit 0
fi
python3 "$HELPER" verify "$SRC" "$BASE" "$SEL" "$STATUS" "${PRUNE_ARG[@]}"
rc=$?
echo "[$(now)] FINISH rc=$rc" >>"$LOG"
exit $rc
