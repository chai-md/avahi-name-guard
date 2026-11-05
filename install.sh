#!/usr/bin/env bash
# avahi-name-guard installer
#
#   sudo ./install.sh                     # install the watchdog timer only
#   sudo ./install.sh --auto-iface        # + restrict avahi to the default-route interface
#   sudo ./install.sh --iface enP7s7      # + restrict avahi to given interfaces (comma-separated)
#   sudo ./install.sh --no-ipv6           # + disable IPv6 in avahi
#   sudo ./install.sh --uninstall         # remove (restore avahi config from backup manually)
set -euo pipefail

cd "$(dirname "$0")"
CONF=/etc/avahi/avahi-daemon.conf
IFACES=""
NO_IPV6=0
UNINSTALL=0

while (( $# )); do
  case "$1" in
    --iface) IFACES=$2; shift 2 ;;
    --auto-iface) IFACES=$(ip route show default | awk '/^default/ {print $5; exit}'); shift ;;
    --no-ipv6) NO_IPV6=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Please run with sudo" >&2; exit 1; }

if (( UNINSTALL )); then
  systemctl disable --now avahi-name-guard.timer 2>/dev/null || true
  rm -f /etc/systemd/system/avahi-name-guard.{service,timer} /usr/local/sbin/avahi-name-guard
  systemctl daemon-reload
  echo "Removed. To revert avahi settings, see ${CONF}.bak.*"
  exit 0
fi

# Set key=value in the [server] section of avahi-daemon.conf
set_conf() {
  local key=$1 val=$2
  if grep -qE "^#?[[:space:]]*${key}=" "$CONF"; then
    sed -i -E "s|^#?[[:space:]]*${key}=.*|${key}=${val}|" "$CONF"
  else
    sed -i "/^\[server\]/a ${key}=${val}" "$CONF"
  fi
}

conf_changed=0
if [[ -n "$IFACES" || $NO_IPV6 -eq 1 ]]; then
  [[ -f "$CONF" ]] || { echo "$CONF not found" >&2; exit 1; }
  cp -a "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)"
  if [[ -n "$IFACES" ]]; then
    for i in ${IFACES//,/ }; do
      ip link show "$i" >/dev/null 2>&1 || { echo "Interface $i not found" >&2; exit 1; }
    done
    set_conf allow-interfaces "$IFACES"
    echo "Restricted avahi to: ${IFACES}"
  fi
  if (( NO_IPV6 )); then
    set_conf use-ipv6 no
    echo "Disabled IPv6 in avahi"
  fi
  conf_changed=1
fi

install -m 0755 avahi-name-guard.sh /usr/local/sbin/avahi-name-guard
install -m 0644 avahi-name-guard.service avahi-name-guard.timer /etc/systemd/system/
systemctl daemon-reload
(( conf_changed )) && systemctl restart avahi-daemon
systemctl enable --now avahi-name-guard.timer

sleep 2
/usr/local/sbin/avahi-name-guard || true
echo "Current mDNS name: $(busctl --system -- call org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetHostName 2>/dev/null | sed -E 's/^s "(.*)"$/\1/').local"
echo "Logs: journalctl -t avahi-name-guard -f"
