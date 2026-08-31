#!/usr/bin/env bash
set -u

echo '===== HP ENVY HERMES CREDENTIAL PLUMBING AUDIT ====='
echo "TIME=$(date -Is)"
echo "HOST=$(hostname)"
echo "USER=$(id -un)"

if [[ "$(hostname)" != 'hpenvy' || "$(id -un)" != 'coolyo' ]]; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CREDENTIAL_AUDIT_WRONG_TARGET'
  exit 41
fi

# Identify listener/PIDs without printing full process command lines.
PIDS=''
if command -v lsof >/dev/null 2>&1; then
  PIDS="$(lsof -nP -t -iTCP:8500 -sTCP:LISTEN 2>/dev/null | sort -u | tr '\n' ' ' || true)"
fi
if [[ -z "${PIDS// }" ]] && command -v ss >/dev/null 2>&1; then
  PIDS="$(ss -ltnp 'sport = :8500' 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u | tr '\n' ' ' || true)"
fi
printf 'PORT8500_PIDS=%s\n' "${PIDS:-none}"

for pid in $PIDS; do
  [[ -r "/proc/$pid/status" ]] || continue
  name="$(awk '/^Name:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)"
  uid="$(awk '/^Uid:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)"
  cgroup="$(cat "/proc/$pid/cgroup" 2>/dev/null | grep -oE '[A-Za-z0-9_.@-]+\.service' | sort -u | tr '\n' ',' | sed 's/,$//' || true)"
  printf 'PID_INFO=%s|name=%s|uid=%s|units=%s\n' "$pid" "${name:-unknown}" "${uid:-unknown}" "${cgroup:-none}"
  if [[ -r "/proc/$pid/environ" ]]; then
    names="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed 's/=.*//' | grep -E '^(OPENAI_API_KEY|OPENAI_BASE_URL|OPENROUTER_API_KEY|AFZ_[A-Z0-9_]*|MODEL|PROVIDER)$' | sort -u | tr '\n' ',' | sed 's/,$//' || true)"
    printf 'PID_ENV_NAMES=%s|%s\n' "$pid" "${names:-none}"
  else
    printf 'PID_ENV_NAMES=%s|UNREADABLE\n' "$pid"
  fi
done

units="$(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'afz|chat|ai' | sort -u || true)"
for unit in $units; do
  user="$(systemctl show "$unit" -p User --value 2>/dev/null || true)"
  frag="$(systemctl show "$unit" -p FragmentPath --value 2>/dev/null || true)"
  envfiles="$(systemctl show "$unit" -p EnvironmentFiles --value 2>/dev/null || true)"
  printf 'UNIT=%s|user=%s|fragment=%s|environmentFiles=%s\n' "$unit" "${user:-default}" "${frag:-none}" "${envfiles:-none}"
done

# Path discovery only. Do not read file contents or values.
for root in /opt/afz-ai /var/lib/afz-ai /etc/afz-ai /etc/default /etc/systemd/system /home/coolyo/.config; do
  [[ -e "$root" ]] || continue
  find "$root" -maxdepth 3 -type f \( -name '.env' -o -iname '*env*' -o -iname '*credential*' -o -iname '*secret*' -o -iname '*config*' \) -print 2>/dev/null | sort | while IFS= read -r p; do
    [[ -n "$p" ]] && printf 'CANDIDATE_PATH=%s\n' "$p"
  done
done

health="$(curl -fsS --max-time 5 http://127.0.0.1:8500/health 2>/dev/null || true)"
if [[ -n "$health" ]]; then
  echo 'AFZ_CHAT_HEALTH_REACHABLE=true'
else
  echo 'AFZ_CHAT_HEALTH_REACHABLE=false'
fi

echo 'SECRET_VALUES_EMITTED=false'
echo 'FINAL_CLASSIFICATION=HP_HERMES_CREDENTIAL_PLUMBING_AUDITED'
echo '===== HP ENVY HERMES CREDENTIAL PLUMBING AUDIT END ====='
