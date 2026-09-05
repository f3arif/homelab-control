#!/usr/bin/env bash
set -euo pipefail
HERMES_HOME='/home/coolyo/.hermes'
LAUNCHER="$HOME/.local/bin/hermes"
WRAPPER="$HOME/.local/bin/hermes-afz"
MODEL='gpt-5.6-luna'
PROVIDER='openai-codex'
CONTEXT='65536'

echo '===== HP ENVY HERMES PRIMARY CONFIGURE ====='
echo "TIME=$(date -Is)"
echo "HOST=$(hostname)"
echo "USER=$(id -un)"

if [[ "$(hostname)" != 'hpenvy' || "$(id -un)" != 'coolyo' ]]; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CONFIG_WRONG_TARGET'
  exit 41
fi
if [[ ! -x "$LAUNCHER" || ! -f "$HERMES_HOME/config.yaml" || ! -r "$HERMES_HOME/auth.json" ]]; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CONFIG_INSTALL_INCOMPLETE'
  exit 42
fi
if pgrep -af '[h]ermes.*gateway' >/dev/null 2>&1; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CONFIG_GATEWAY_ALREADY_RUNNING_SAFE_STOP'
  exit 43
fi

auth_verified="$(python3 - "$HERMES_HOME/auth.json" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:
    print('false'); raise SystemExit
def usable(v):
    if isinstance(v,str):
        return bool(v.strip())
    if isinstance(v,dict):
        return any(usable(x) for x in v.values())
    if isinstance(v,list):
        return any(usable(x) for x in v)
    return False
hits=[]
def walk(v,path=()):
    if isinstance(v,dict):
        for k,x in v.items():
            p=path+(str(k),)
            if 'openai-codex' in str(k).lower() or any('openai-codex' in z.lower() for z in p):
                hits.append(x)
            walk(x,p)
    elif isinstance(v,list):
        for i,x in enumerate(v): walk(x,path+(str(i),))
walk(d)
print('true' if any(usable(x) for x in hits) else 'false')
PY
)"
if [[ "$auth_verified" != true ]]; then
  echo 'AUTH_VERIFIED=false'
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_AUTH_NOT_VERIFIED'
  exit 44
fi

backup="$HERMES_HOME/config.yaml.afz-primary-$(date +%Y%m%dT%H%M%S).bak"
cp -p "$HERMES_HOME/config.yaml" "$backup"

if ! python3 - "$HERMES_HOME/config.yaml" "$MODEL" "$PROVIDER" "$CONTEXT" <<'PY'
import os,stat,sys
from pathlib import Path
path=Path(sys.argv[1]); model=sys.argv[2]; provider=sys.argv[3]; context=int(sys.argv[4])
try:
    from ruamel.yaml import YAML
    y=YAML(); y.preserve_quotes=True
    with path.open('r',encoding='utf-8') as f: data=y.load(f) or {}
    section=data.setdefault('model',{})
    section['default']=model
    section['provider']=provider
    section['context_length']=context
    section.pop('base_url',None)
    tmp=path.with_suffix('.yaml.afztmp')
    with tmp.open('w',encoding='utf-8') as f: y.dump(data,f)
except ImportError:
    import yaml
    data=yaml.safe_load(path.read_text(encoding='utf-8')) or {}
    section=data.setdefault('model',{})
    section['default']=model
    section['provider']=provider
    section['context_length']=context
    section.pop('base_url',None)
    tmp=path.with_suffix('.yaml.afztmp')
    tmp.write_text(yaml.safe_dump(data,sort_keys=False,allow_unicode=True),encoding='utf-8')
mode=stat.S_IMODE(path.stat().st_mode)
os.chmod(tmp,mode)
os.replace(tmp,path)
PY
then
  cp -p "$backup" "$HERMES_HOME/config.yaml"
  echo 'CONFIG_WRITE_FAILED_ROLLED_BACK=true'
  echo 'FINAL_CLASSIFICATION=HP_HERMES_PRIMARY_CONFIG_VERIFY_FAILED'
  exit 45
fi

mkdir -p "$HOME/.local/bin"
cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/.local/bin/hermes" "$@"
EOF
chmod 700 "$WRAPPER"

model_json="$("$LAUNCHER" config get model --json 2>/dev/null || true)"
read -r provider model ctx base_present <<EOF
$(printf '%s' "$model_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d.get("model",d); print(m.get("provider",""),m.get("default",m.get("model","")),m.get("context_length",""),"true" if bool(m.get("base_url")) else "false")')
EOF
wrap_version="$("$WRAPPER" --version 2>&1 | head -n1 || true)"

secret_in_config=false
if grep -Eq '^[[:space:]]*api_key:[[:space:]]*[^#[:space:]]+' "$HERMES_HOME/config.yaml"; then secret_in_config=true; fi
secret_in_env=false
if grep -Eq '^OPENAI_API_KEY=.+$' "$HERMES_HOME/.env" 2>/dev/null; then secret_in_env=true; fi

printf 'MODEL=%s\nPROVIDER=%s\nCONTEXT_LENGTH=%s\nBASE_URL_PRESENT=%s\n' "$model" "$provider" "$ctx" "$base_present"
printf 'AUTH_VERIFIED=%s\n' "$auth_verified"
printf 'WRAPPER=%s\nWRAPPER_VERSION=%s\n' "$WRAPPER" "$wrap_version"
printf 'CONFIG_BACKUP=%s\n' "$backup"
printf 'OPENAI_SECRET_PERSISTED_IN_CONFIG=%s\nOPENAI_SECRET_PERSISTED_IN_HERMES_ENV=%s\n' "$secret_in_config" "$secret_in_env"
printf 'GATEWAY_STARTED=false\nGENERATION_TEST_STARTED=false\nSECRET_VALUES_EMITTED=false\n'

if [[ "$model" == "$MODEL" && "$provider" == "$PROVIDER" && "$ctx" == "$CONTEXT" && "$base_present" == false && "$auth_verified" == true && "$secret_in_config" == false && "$secret_in_env" == false ]]; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_PRIMARY_CONFIGURED'
  exit 0
fi

cp -p "$backup" "$HERMES_HOME/config.yaml"
echo 'VERIFY_FAILED_ROLLED_BACK=true'
echo 'FINAL_CLASSIFICATION=HP_HERMES_PRIMARY_CONFIG_VERIFY_FAILED'
exit 46
