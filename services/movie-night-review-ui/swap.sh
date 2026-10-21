#!/usr/bin/env bash
# Movie Night UI: guarded three-file update with preflight verification and automatic rollback on failure.
# Usage: swap.sh apply | swap.sh rollback
# No service restart, state database writes, or download actions.
set -Eeuo pipefail
umask 077
D="$(cd "$(dirname "$0")" && pwd -P)"
SRC=/home/coolyo/afz-stremio-secondhost-20260918/movie-night-review-service/src
FILES=(screen.html screen.css screen.js)
case "${1:-}" in
  apply) FROM=candidate; EXPECT=rollback ;;
  rollback) FROM=rollback; EXPECT=candidate ;;
  *) echo "Usage: swap.sh apply|rollback" >&2; exit 2 ;;
esac
test -d "$SRC" || { echo "Missing expected live directory" >&2; exit 3; }
exec 9>"$D/.swap.lock"
flock -n 9 || { echo "Another Movie Night swap is in progress" >&2; exit 4; }

# Verify both source artifacts and rollback artifacts *before* touching live.
(cd "$D/$FROM" && sha256sum -c SHA256SUMS)
(cd "$D/$EXPECT" && sha256sum -c SHA256SUMS)
for f in "${FILES[@]}"; do
  [[ -f "$SRC/$f" && ! -L "$SRC/$f" ]] || { echo "Missing/unexpected live file $f" >&2; exit 5; }
  want="$(awk -v f="$f" '$2 == f { print $1 }' "$D/$EXPECT/SHA256SUMS")"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "Missing trusted expected hash: $f" >&2; exit 5; }
  have="$(sha256sum "$SRC/$f" | cut -d' ' -f1)"
  [[ "$have" == "$want" ]] || { echo "DRIFT: $f is not the expected $EXPECT version; nothing changed" >&2; exit 6; }
done

WORK="$(mktemp -d "$SRC/.movie-night-swap.XXXXXXXX")"
changed=0
restore_on_failure() {
  local code="${1:-1}" bad=0
  trap - ERR INT TERM
  if (( changed )); then
    echo "Swap failed or interrupted; restoring previous $EXPECT files" >&2
    for f in "${FILES[@]}"; do
      tmp="$SRC/.$f.restore.$$"
      if cp -p "$D/$EXPECT/$f" "$tmp" && /usr/bin/mv -f "$tmp" "$SRC/$f"; then
        :
      else
        echo "URGENT: automatic restore failed for $f" >&2
        bad=1
      fi
    done
    if ! ( cd "$SRC" && sha256sum -c "$D/$EXPECT/SHA256SUMS" ); then
      bad=1
    fi
    if (( bad )); then echo "URGENT: inspect live page and use saved rollback copies" >&2; fi
  fi
  /usr/bin/rm -rf -- "$WORK"
  exit "$code"
}
trap 'restore_on_failure $?' ERR
trap 'restore_on_failure 130' INT
trap 'restore_on_failure 143' TERM

# Stage all copies on the same filesystem. Any failure here leaves live untouched.
for f in "${FILES[@]}"; do
  cp -p "$D/$FROM/$f" "$WORK/$f"
done
(cd "$WORK" && sha256sum -c "$D/$FROM/SHA256SUMS")
changed=1
for f in "${FILES[@]}"; do
  /usr/bin/mv -f "$WORK/$f" "$SRC/$f"
done
(cd "$SRC" && sha256sum -c "$D/$FROM/SHA256SUMS")
changed=0
trap - ERR INT TERM
/usr/bin/rmdir -- "$WORK"
echo "SWAPPED_TO=$FROM"
