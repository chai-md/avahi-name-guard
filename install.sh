#!/usr/bin/env bash
# avahi-name-guard インストーラ
#
#   sudo ./install.sh                     # 監視タイマーのみ導入
#   sudo ./install.sh --auto-iface        # + avahi をデフォルトルートのIFに限定
#   sudo ./install.sh --iface enP7s7      # + avahi を指定IFに限定（カンマ区切り可）
#   sudo ./install.sh --no-ipv6           # + avahi の IPv6 を無効化
#   sudo ./install.sh --uninstall         # 削除（avahi 設定はバックアップから手動で戻す）
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
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "sudo で実行してください" >&2; exit 1; }

if (( UNINSTALL )); then
  systemctl disable --now avahi-name-guard.timer 2>/dev/null || true
  rm -f /etc/systemd/system/avahi-name-guard.{service,timer} /usr/local/sbin/avahi-name-guard
  systemctl daemon-reload
  echo "削除しました。avahi 設定を戻す場合は ${CONF}.bak.* を参照してください。"
  exit 0
fi

# avahi-daemon.conf の [server] セクションに key=value を設定
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
  [[ -f "$CONF" ]] || { echo "$CONF がありません" >&2; exit 1; }
  cp -a "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)"
  if [[ -n "$IFACES" ]]; then
    for i in ${IFACES//,/ }; do
      ip link show "$i" >/dev/null 2>&1 || { echo "インターフェース $i が見つかりません" >&2; exit 1; }
    done
    set_conf allow-interfaces "$IFACES"
    echo "avahi を ${IFACES} に限定しました"
  fi
  if (( NO_IPV6 )); then
    set_conf use-ipv6 no
    echo "avahi の IPv6 を無効化しました"
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
echo "現在の mDNS 名: $(busctl --system -- call org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetHostName 2>/dev/null | sed -E 's/^s "(.*)"$/\1/').local"
echo "ログ確認: journalctl -t avahi-name-guard -f"
