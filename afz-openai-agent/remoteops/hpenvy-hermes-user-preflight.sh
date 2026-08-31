#!/usr/bin/env bash
set -u
printf '%s\n' '===== HP ENVY HERMES USER PREFLIGHT ====='
printf 'TIME=%s\n' "$(date -Is 2>/dev/null || date)"
printf 'HOST=%s\n' "$(hostname 2>/dev/null || true)"
printf 'USER=%s\n' "$(id -un 2>/dev/null || true)"
printf 'HOME=%s\n' "${HOME:-}"

host_ok=false; user_ok=false; home_writable=false; deps_ok=false; github_ok=false; disk_ok=false
[ "$(hostname 2>/dev/null || true)" = 'hpenvy' ] && host_ok=true
[ "$(id -un 2>/dev/null || true)" = 'coolyo' ] && user_ok=true
[ -n "${HOME:-}" ] && [ -w "$HOME" ] && home_writable=true

for c in bash python3 git curl; do
  if command -v "$c" >/dev/null 2>&1; then
    printf 'DEP_%s=%s\n' "${c^^}" "$(command -v "$c")"
  else
    printf 'DEP_%s=MISSING\n' "${c^^}"
  fi
done
if command -v bash >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then deps_ok=true; fi
printf 'PYTHON_VERSION=%s\n' "$(python3 --version 2>&1 | head -1 || true)"
printf 'GIT_VERSION=%s\n' "$(git --version 2>&1 | head -1 || true)"
printf 'CURL_VERSION=%s\n' "$(curl --version 2>&1 | head -1 || true)"

free_kb=$(df -Pk "${HOME:-/}" 2>/dev/null | awk 'NR==2{print $4+0}')
printf 'HOME_FREE_KB=%s\n' "${free_kb:-0}"
[ "${free_kb:-0}" -ge 3145728 ] && disk_ok=true
printf 'MEM_AVAILABLE_MB=%s\n' "$(awk '/MemAvailable:/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null || echo 0)"

pin='f50b5bb0fa5b48caef753c790bf0b09a3570918a'
installer_url="https://raw.githubusercontent.com/NousResearch/hermes-agent/${pin}/scripts/install.sh"
if curl -fsSI --max-time 20 "$installer_url" >/dev/null 2>&1; then github_ok=true; fi
printf 'PINNED_INSTALLER_REACHABLE=%s\n' "$github_ok"

hermes_home="${HOME:-/home/coolyo}/.hermes"
printf 'HERMES_HOME=%s\n' "$hermes_home"
printf 'HERMES_HOME_EXISTS=%s\n' "$([ -d "$hermes_home" ] && echo true || echo false)"
printf 'HERMES_LAUNCHER_EXISTS=%s\n' "$([ -x "$hermes_home/bin/hermes" ] && echo true || echo false)"
printf 'HERMES_CONFIG_EXISTS=%s\n' "$([ -f "$hermes_home/config.yaml" ] && echo true || echo false)"
if [ -f "$hermes_home/config.yaml" ]; then
  printf 'HERMES_CONFIG_SHA256=%s\n' "$(sha256sum "$hermes_home/config.yaml" 2>/dev/null | awk '{print $1}')"
fi

# Credential discovery is path/name-only. Never print environment values or file contents.
[ -n "${OPENAI_API_KEY+x}" ] && openai_env=true || openai_env=false
printf 'OPENAI_API_KEY_IN_WORKER_ENV=%s\n' "$openai_env"
credential_files=''
for d in /opt/afz-ai /etc/systemd/system /etc/default; do
  [ -e "$d" ] || continue
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    credential_files="${credential_files}${f};"
  done < <(grep -RIl --include='*.env' --include='*.service' --include='*.conf' --include='*.cfg' --include='*.ini' 'OPENAI_API_KEY' "$d" 2>/dev/null | head -20)
done
if [ -n "$credential_files" ]; then
  printf 'OPENAI_CREDENTIAL_REFERENCE_FOUND=true\n'
  printf 'OPENAI_CREDENTIAL_REFERENCE_PATHS=%s\n' "$credential_files"
else
  printf 'OPENAI_CREDENTIAL_REFERENCE_FOUND=false\n'
fi

printf 'AFZ_CHAT_HEALTH='; curl -fsS --max-time 5 http://127.0.0.1:8500/health 2>/dev/null | tr '\r\n' ' ' || printf 'UNREACHABLE'; printf '\n'
printf 'HOST_OK=%s\nUSER_OK=%s\nHOME_WRITABLE=%s\nDEPS_OK=%s\nDISK_OK=%s\n' "$host_ok" "$user_ok" "$home_writable" "$deps_ok" "$disk_ok"
if $host_ok && $user_ok && $home_writable && $deps_ok && $github_ok && $disk_ok; then
  printf '%s\n' 'FINAL_CLASSIFICATION=HP_HERMES_PREFLIGHT_READY_USER_STANDARD'
  exit 0
else
  printf '%s\n' 'FINAL_CLASSIFICATION=HP_HERMES_PREFLIGHT_BLOCKED'
  exit 20
fi
