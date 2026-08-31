#!/usr/bin/env bash
set -u

MODE="${1:-audit}"
IN_IF="tailscale0"
OUT_IF="surfshark"
ROUTE_TABLE="5253"
ROUTE_PREF="5253"
SERVICE_NAME="tailscale-surfshark-policy.service"
ROUTE_HELPER="/usr/local/sbin/afz-tailscale-surfshark-route"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

say() { printf '%s\n' "$*"; }
section() { printf '\n===== %s =====\n' "$1"; }

readonly_audit() {
  section "AFZ HP ENVY SURFSHARK EXIT-NODE AUDIT"
  say "MODE=${MODE}"
  say "UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  say "HOST=$(hostname 2>/dev/null || true)"

  section "INTERFACES"
  ip -br addr show "$IN_IF" 2>&1 || true
  ip -br addr show "$OUT_IF" 2>&1 || true
  ip -br addr show eno1 2>&1 || true

  section "WIREGUARD"
  wg show "$OUT_IF" 2>&1 || true

  section "TAILSCALE"
  tailscale status 2>&1 | sed -n '1,30p' || true
  tailscale ip -4 2>&1 || true

  section "POLICY SERVICE"
  systemctl is-enabled "$SERVICE_NAME" 2>&1 || true
  systemctl is-active "$SERVICE_NAME" 2>&1 || true
  systemctl status "$SERVICE_NAME" --no-pager -l 2>&1 | sed -n '1,60p' || true

  section "IP RULES"
  ip -4 rule show 2>&1 || true

  section "ROUTE TABLES"
  ip -4 route show table main 2>&1 || true
  printf '%s\n' "--- table 52 (Tailscale, if present) ---"
  ip -4 route show table 52 2>&1 || true
  printf '%s\n' "--- table ${ROUTE_TABLE} (AFZ Surfshark, if present) ---"
  ip -4 route show table "$ROUTE_TABLE" 2>&1 || true

  section "FORWARDING"
  sysctl net.ipv4.ip_forward 2>&1 || true

  section "NAT"
  sudo -n iptables -t nat -S POSTROUTING 2>&1 | grep -E 'tailscale|surfshark|100\.64\.0\.0/10|MASQUERADE' || true

  section "ROUTE PROBES"
  ip -4 route get 1.1.1.1 from 100.64.0.1 iif "$IN_IF" 2>&1 || true
  ip -4 route get 8.8.8.8 from 100.64.0.1 iif "$IN_IF" 2>&1 || true

  section "HP HOST PUBLIC IP"
  curl -4 -fsS --max-time 8 https://ifconfig.me 2>&1 || true
  printf '\n'

  local in_up=0 out_up=0 policy_rule=0 policy_default=0 nat_rule=0
  ip link show "$IN_IF" >/dev/null 2>&1 && in_up=1
  ip link show "$OUT_IF" >/dev/null 2>&1 && out_up=1
  ip -4 rule show 2>/dev/null | grep -Eq "iif ${IN_IF}.*lookup ${ROUTE_TABLE}|iif ${IN_IF}.*lookup surfshark" && policy_rule=1
  ip -4 route show table "$ROUTE_TABLE" 2>/dev/null | grep -Eq "^default .*dev ${OUT_IF}( |$)" && policy_default=1
  sudo -n iptables -t nat -C POSTROUTING -s 100.64.0.0/10 -o "$OUT_IF" -j MASQUERADE >/dev/null 2>&1 && nat_rule=1

  say "CHECK_TAILSCALE0_UP=${in_up}"
  say "CHECK_SURFSHARK_UP=${out_up}"
  say "CHECK_AFZ_POLICY_RULE=${policy_rule}"
  say "CHECK_AFZ_POLICY_DEFAULT=${policy_default}"
  say "CHECK_AFZ_SURFSHARK_NAT=${nat_rule}"
  if [ "$in_up" -eq 1 ] && [ "$out_up" -eq 1 ] && [ "$policy_rule" -eq 1 ] && [ "$policy_default" -eq 1 ]; then
    say "RESULT=AUDIT_POLICY_PRESENT"
  elif [ "$in_up" -eq 1 ] && [ "$out_up" -eq 1 ]; then
    say "RESULT=AUDIT_POLICY_MISSING_OR_INCOMPLETE"
  else
    say "RESULT=AUDIT_INTERFACE_NOT_READY"
  fi
}

apply_policy() {
  if [ "${AFZ_CHANGE_AUTHORIZED:-0}" != "1" ]; then
    say "RESULT=APPLY_DENIED_LOCAL_AUTHORIZATION_REQUIRED"
    exit 41
  fi
  if ! sudo -n true >/dev/null 2>&1; then
    say "RESULT=APPLY_DENIED_PASSWORDLESS_SUDO_REQUIRED"
    exit 42
  fi
  if ! ip link show "$IN_IF" >/dev/null 2>&1; then
    say "RESULT=APPLY_ABORT_TAILSCALE_INTERFACE_MISSING"
    exit 43
  fi
  if ! ip link show "$OUT_IF" >/dev/null 2>&1; then
    say "RESULT=APPLY_ABORT_SURFSHARK_INTERFACE_MISSING"
    exit 44
  fi

  local helper_tmp service_tmp stamp
  helper_tmp="$(mktemp)"
  service_tmp="$(mktemp)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  trap 'rm -f "$helper_tmp" "$service_tmp"' EXIT

  cat >"$helper_tmp" <<'AFZ_ROUTE_HELPER'
#!/usr/bin/env bash
set -euo pipefail
IN_IF="tailscale0"
OUT_IF="surfshark"
TABLE="5253"
PREFS=(5188 5200 5201 5202 5203 5204 5253)

cleanup_rules() {
  local p
  for p in "${PREFS[@]}"; do
    while ip -4 rule del pref "$p" 2>/dev/null; do :; done
  done
}

start_policy() {
  ip link show "$IN_IF" >/dev/null
  ip link show "$OUT_IF" >/dev/null

  cleanup_rules
  ip -4 route replace default dev "$OUT_IF" table "$TABLE"

  # Preserve Tailscale's own peer/subnet routing first. If table 52 has no
  # matching route, RPDB processing continues to the later rules.
  ip -4 rule add pref 5188 iif "$IN_IF" lookup 52

  # Preserve local/private destinations on the HP Envy's normal routing plane.
  ip -4 rule add pref 5200 iif "$IN_IF" to 10.0.0.0/8 lookup main
  ip -4 rule add pref 5201 iif "$IN_IF" to 172.16.0.0/12 lookup main
  ip -4 rule add pref 5202 iif "$IN_IF" to 192.168.0.0/16 lookup main
  ip -4 rule add pref 5203 iif "$IN_IF" to 169.254.0.0/16 lookup main
  ip -4 rule add pref 5204 iif "$IN_IF" to 224.0.0.0/4 lookup main

  # Remaining IPv4 packets that entered through Tailscale are Internet exit
  # traffic and are routed into Surfshark. Locally generated HP Envy traffic
  # has no iif=tailscale0 and is therefore not captured by this rule.
  ip -4 rule add pref 5253 iif "$IN_IF" lookup "$TABLE"

  # Tailscale already owns forwarding admission. Add only the egress SNAT
  # required for the WireGuard tunnel; do not bypass or replace ts-forward.
  iptables -t nat -C POSTROUTING -s 100.64.0.0/10 -o "$OUT_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 100.64.0.0/10 -o "$OUT_IF" -j MASQUERADE
}

stop_policy() {
  cleanup_rules
  while iptables -t nat -C POSTROUTING -s 100.64.0.0/10 -o "$OUT_IF" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -o "$OUT_IF" -j MASQUERADE
  done
  ip -4 route flush table "$TABLE" 2>/dev/null || true
}

case "${1:-start}" in
  start) start_policy ;;
  stop) stop_policy ;;
  *) echo "usage: $0 start|stop" >&2; exit 64 ;;
esac
AFZ_ROUTE_HELPER

  cat >"$service_tmp" <<'AFZ_SERVICE'
[Unit]
Description=AFZ Tailscale exit traffic via Surfshark
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sh -c 'n=0; while [ $n -lt 30 ]; do ip link show tailscale0 >/dev/null 2>&1 && ip link show surfshark >/dev/null 2>&1 && exit 0; n=$((n+1)); sleep 1; done; exit 1'
ExecStart=/usr/local/sbin/afz-tailscale-surfshark-route start
ExecStop=/usr/local/sbin/afz-tailscale-surfshark-route stop

[Install]
WantedBy=multi-user.target
AFZ_SERVICE

  sudo -n mkdir -p /var/backups/afz
  if sudo -n test -f "$SERVICE_PATH"; then
    sudo -n cp -a "$SERVICE_PATH" "/var/backups/afz/${SERVICE_NAME}.${stamp}.bak"
  fi
  if sudo -n test -f "$ROUTE_HELPER"; then
    sudo -n cp -a "$ROUTE_HELPER" "/var/backups/afz/afz-tailscale-surfshark-route.${stamp}.bak"
  fi

  sudo -n install -m 0755 "$helper_tmp" "$ROUTE_HELPER"
  sudo -n install -m 0644 "$service_tmp" "$SERVICE_PATH"
  sudo -n systemctl daemon-reload
  sudo -n systemctl enable "$SERVICE_NAME" >/dev/null
  sudo -n systemctl restart "$SERVICE_NAME"

  say "APPLY_SERVICE_ACTIVE=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
  say "APPLY_SERVICE_ENABLED=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
  say "RESULT=APPLY_COMPLETED"
}

case "$MODE" in
  audit)
    readonly_audit
    ;;
  apply)
    apply_policy
    readonly_audit
    ;;
  *)
    say "RESULT=INVALID_MODE"
    exit 64
    ;;
esac
