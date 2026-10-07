#!/bin/sh
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec /usr/bin/flock -n -F "$BASE/run.lock" /usr/bin/python3 "$BASE/supervisor.py" >>"$BASE/recovery.log" 2>&1
