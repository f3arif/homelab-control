#!/usr/bin/env bash
set -euo pipefail
PIN='f50b5bb0fa5b48caef753c790bf0b09a3570918a'
HERMES_HOME='/home/coolyo/.hermes'
INSTALL_DIR="$HERMES_HOME/hermes-agent"
INSTALLER="/tmp/hermes-install-${PIN}.sh"

echo '===== HP ENVY HERMES USER INSTALL ====='
echo "TIME=$(date -Is)"
echo "HOST=$(hostname)"
echo "USER=$(id -un)"

if [[ "$(hostname)" != 'hpenvy' || "$(id -un)" != 'coolyo' ]]; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_INSTALL_WRONG_TARGET'
  exit 41
fi
if [[ -e "$HERMES_HOME/config.yaml" ]]; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_INSTALL_PREEXISTING_CONFIG_SAFE_STOP'
  exit 42
fi
if [[ -e "$HERMES_HOME/bin/hermes" || -e "$INSTALL_DIR" ]]; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_INSTALL_PREEXISTING_ARTIFACT_SAFE_STOP'
  exit 43
fi

curl -fsSL --retry 3 --connect-timeout 15 \
  "https://raw.githubusercontent.com/NousResearch/hermes-agent/${PIN}/scripts/install.sh" \
  -o "$INSTALLER"
chmod 700 "$INSTALLER"
trap 'rm -f "$INSTALLER"' EXIT

HERMES_HOME="$HERMES_HOME" HERMES_INSTALL_DIR="$INSTALL_DIR" \
  bash "$INSTALLER" \
    --commit "$PIN" \
    --hermes-home "$HERMES_HOME" \
    --dir "$INSTALL_DIR" \
    --skip-setup \
    --skip-browser \
    --skip-computer-use \
    --non-interactive

LAUNCHER="$HERMES_HOME/bin/hermes"
if [[ ! -x "$LAUNCHER" ]]; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_INSTALL_LAUNCHER_MISSING'
  exit 44
fi
VERSION="$($LAUNCHER --version 2>&1 | tail -n 1)"
HEAD="$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null || true)"
if [[ "$HEAD" != "$PIN" ]]; then
  echo "GIT_HEAD=$HEAD"
  echo 'FINAL_CLASSIFICATION=HP_HERMES_INSTALL_PIN_MISMATCH'
  exit 45
fi

printf 'HERMES_HOME=%s\n' "$HERMES_HOME"
printf 'INSTALL_DIR=%s\n' "$INSTALL_DIR"
printf 'HERMES_VERSION=%s\n' "$VERSION"
printf 'GIT_HEAD=%s\n' "$HEAD"
printf 'CONFIG_EXISTS=%s\n' "$( [[ -e "$HERMES_HOME/config.yaml" ]] && echo true || echo false )"
printf 'GATEWAY_STARTED=false\nGENERATION_TEST_STARTED=false\n'
echo 'FINAL_CLASSIFICATION=HP_HERMES_INSTALLED_USER_STANDARD_UNCONFIGURED'
echo '===== HP ENVY HERMES USER INSTALL END ====='
