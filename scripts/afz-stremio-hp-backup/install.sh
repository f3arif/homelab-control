#!/usr/bin/env bash
# Installs this bundle onto HP Envy at the paths the systemd units expect.
# Existing deployed files are kept as *.before-install-<stamp>.bak.
# Does not touch private material (transport token, addon collection, bridge.mjs, .venv)
# or the mirror selection; restore those separately (see README).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE=/home/coolyo/afz-stremio-secondhost-20260918
MIR=/home/coolyo/afz-stremio-hotmirror
UNITS=/home/coolyo/.config/systemd/user
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
put() {
  local src="$1" dst="$2" mode="$3"
  mkdir -p "$(dirname "$dst")"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then return; fi
  [ -f "$dst" ] && cp -p "$dst" "$dst.before-install-$STAMP.bak"
  install -m "$mode" "$src" "$dst"
  echo "installed $dst"
}
put "$HERE/run-backup.sh"       "$BASE/run-backup.sh"          0755
put "$HERE/sync-from-h3.sh"     "$BASE/sync-from-h3.sh"        0755
put "$HERE/apply-hp-standby.py" "$BASE/apply-hp-standby.py"    0755
put "$HERE/health-backup.sh"    "$BASE/bin/health-backup.sh"   0755
put "$HERE/sync-hotmirror.sh"   "$MIR/sync.sh"                 0755
put "$HERE/hotmirror.py"        "$MIR/hotmirror.py"            0755
for f in canary.sh test-canary.py prod-verify.py; do
  put "$HERE/verify/$f" "$MIR/verify/$f" 0755
done
for u in "$HERE"/systemd/*; do
  put "$u" "$UNITS/$(basename "$u")" 0644
done
if [ "${1:-}" = "--enable" ]; then
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  systemctl --user daemon-reload
  systemctl --user enable --now afz-stremio-provider-bridge.service afz-stremio-backup.service \
    afz-stremio-backup-sync.timer afz-stremio-backup-health.timer afz-stremio-hotmirror-sync.timer
fi
echo AFZ_HP_BACKUP_INSTALL_OK
