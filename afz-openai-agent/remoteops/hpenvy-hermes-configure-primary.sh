#!/usr/bin/env bash
set -euo pipefail
HERMES_HOME='/home/coolyo/.hermes'
LAUNCHER="$HOME/.local/bin/hermes"
WRAPPER="$HOME/.local/bin/hermes-afz"
MODEL='gpt-5.6-luna'
BASE_URL='https://api.openai.com/v1'
CONTEXT='65536'

echo '===== HP ENVY HERMES PRIMARY CONFIGURE ====='
echo "TIME=$(date -Is)"
echo "HOST=$(hostname)"
echo "USER=$(id -un)"

if [[ "$(hostname)" != 'hpenvy' || "$(id -un)" != 'coolyo' ]]; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CONFIG_WRONG_TARGET'
  exit 41
fi
if [[ ! -x "$LAUNCHER" || ! -f "$HERMES_HOME/config.yaml" ]]; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CONFIG_INSTALL_INCOMPLETE'
  exit 42
fi
if pgrep -af '[h]ermes.*gateway' >/dev/null 2>&1; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CONFIG_GATEWAY_ALREADY_RUNNING_SAFE_STOP'
  exit 43
fi

backup="$HERMES_HOME/config.yaml.afz-primary-$(date +%Y%m%dT%H%M%S).bak"
cp -p "$HERMES_HOME/config.yaml" "$backup"

"$LAUNCHER" config set model.default "$MODEL" >/dev/null
"$LAUNCHER" config set model.provider openai-api >/dev/null
"$LAUNCHER" config set model.base_url "$BASE_URL" >/dev/null
"$LAUNCHER" config set model.context_length "$CONTEXT" >/dev/null

mkdir -p "$HOME/.local/bin"
cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  pid="$(systemctl show afz-ai.service -p MainPID --value 2>/dev/null || true)"
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [[ -r "/proc/$pid/environ" ]]; then
    key="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^OPENAI_API_KEY=//p' | head -n 1)"
    if [[ -n "$key" ]]; then
      export OPENAI_API_KEY="$key"
      unset key
    fi
  fi
fi
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo 'AFZ Hermes credential unavailable from afz-ai.service environment.' >&2
  exit 44
fi
exec "$HOME/.local/bin/hermes" "$@"
EOF
chmod 700 "$WRAPPER"

# Non-generation validation only: version parsing exercises the wrapper and
# confirms it can acquire the existing service credential without printing it.
WRAP_VERSION="$($WRAPPER --version 2>&1 | tail -n 1)"

provider="$(awk '/^model:/{m=1;next} m && /^[^[:space:]]/{m=0} m && /^[[:space:]]+provider:/{sub(/^[^:]+:[[:space:]]*/,"");gsub(/[\"'\'' ]/,"");print;exit}' "$HERMES_HOME/config.yaml")"
model="$(awk '/^model:/{m=1;next} m && /^[^[:space:]]/{m=0} m && /^[[:space:]]+default:/{sub(/^[^:]+:[[:space:]]*/,"");gsub(/[\"]/,"");print;exit}' "$HERMES_HOME/config.yaml")"
base="$(awk '/^model:/{m=1;next} m && /^[^[:space:]]/{m=0} m && /^[[:space:]]+base_url:/{sub(/^[^:]+:[[:space:]]*/,"");gsub(/[\"]/,"");print;exit}' "$HERMES_HOME/config.yaml")"
ctx="$(awk '/^model:/{m=1;next} m && /^[^[:space:]]/{m=0} m && /^[[:space:]]+context_length:/{sub(/^[^:]+:[[:space:]]*/,"");gsub(/[\" ]/,"");print;exit}' "$HERMES_HOME/config.yaml")"

secret_in_config=false
if grep -Eq '^[[:space:]]*api_key:[[:space:]]*[^#[:space:]]+' "$HERMES_HOME/config.yaml"; then secret_in_config=true; fi
secret_in_env=false
if grep -Eq '^OPENAI_API_KEY=.+$' "$HERMES_HOME/.env" 2>/dev/null; then secret_in_env=true; fi

printf 'MODEL=%s\nPROVIDER=%s\nBASE_URL=%s\nCONTEXT_LENGTH=%s\n' "$model" "$provider" "$base" "$ctx"
printf 'WRAPPER=%s\nWRAPPER_VERSION=%s\n' "$WRAPPER" "$WRAP_VERSION"
printf 'CONFIG_BACKUP=%s\n' "$backup"
printf 'OPENAI_SECRET_PERSISTED_IN_CONFIG=%s\nOPENAI_SECRET_PERSISTED_IN_HERMES_ENV=%s\n' "$secret_in_config" "$secret_in_env"
printf 'GATEWAY_STARTED=false\nGENERATION_TEST_STARTED=false\nSECRET_VALUES_EMITTED=false\n'

if [[ "$model" == "$MODEL" && "$provider" == 'openai-api' && "$base" == "$BASE_URL" && "$ctx" == "$CONTEXT" && "$secret_in_config" == false && "$secret_in_env" == false ]]; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_PRIMARY_CONFIGURED_NO_SECRET_COPY'
  exit 0
fi

echo 'FINAL_CLASSIFICATION=HP_HERMES_PRIMARY_CONFIG_VERIFY_FAILED'
exit 45
