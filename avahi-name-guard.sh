#!/usr/bin/env bash
# avahi-name-guard
#   avahi-daemon が自己衝突などで "<host>-2.local" に改名した場合に、
#   本来のホスト名 "<host>.local" へ自動で戻す。
#   - 本当に別ホストが同名を使っている場合は戻さない（警告のみ）
#   - 1時間あたりの修正回数に上限を設け、フラップ時は原因対策を促す
#   依存: systemd(busctl), iproute2, avahi-daemon（avahi-utils は不要）
set -uo pipefail

TAG=avahi-name-guard
STATE_DIR=/run/avahi-name-guard
MAX_FIX_PER_HOUR=${MAX_FIX_PER_HOUR:-6}
SETTLE_SEC=${SETTLE_SEC:-6}

log() { logger -t "$TAG" -- "$*"; echo "$*"; }

AV=(busctl --system --timeout=8 -- call org.freedesktop.Avahi / org.freedesktop.Avahi.Server)

get_name() { "${AV[@]}" GetHostName 2>/dev/null | sed -E 's/^s "(.*)"$/\1/'; }

systemctl is-active --quiet avahi-daemon || exit 0

want=${WANT_NAME:-$(hostnamectl --static 2>/dev/null || hostname)}
want=${want%%.*}
[[ -n "$want" ]] || exit 0

cur=$(get_name)
if [[ -z "$cur" ]]; then
  log "avahi の D-Bus に接続できません（スキップ）"
  exit 0
fi
[[ "$cur" == "$want" ]] && exit 0

log "mDNS名が ${cur}.local になっています（期待値 ${want}.local）"

# --- 本当に別ホストが want.local を名乗っていないか確認 ---
own_addrs=$(ip -o addr show | awk '{split($4,a,"/"); print a[1]}')
if out=$("${AV[@]}" ResolveHostName iisiu -1 -1 "${want}.local" -1 0 2>/dev/null); then
  # 出力例: iisisu 2 0 "foo.local" 0 "192.0.2.10" 0
  addr=$(awk '{print $6}' <<<"$out" | tr -d '"')
  addr=${addr%%%*}
  if [[ -n "$addr" ]] && ! grep -qxF "$addr" <<<"$own_addrs"; then
    log "警告: ${want}.local は別ホスト (${addr}) が使用中です。名前は戻しません。"
    exit 0
  fi
fi

# --- 修正回数の上限（フラップ対策） ---
mkdir -p "$STATE_DIR"
now=$(date +%s)
hist="$STATE_DIR/fixes"
touch "$hist"
awk -v t=$((now - 3600)) '$1 > t' "$hist" > "$hist.tmp" && mv "$hist.tmp" "$hist"
count=$(wc -l < "$hist")
if (( count >= MAX_FIX_PER_HOUR )); then
  log "直近1時間で ${count} 回修正済み。改名が繰り返されています。avahi の対象インターフェースを絞ってください（install.sh --auto-iface 等）。"
  exit 0
fi
echo "$now" >> "$hist"

# --- 1段目: D-Bus で名前を戻す ---
"${AV[@]}" SetHostName s "$want" >/dev/null 2>&1
sleep "$SETTLE_SEC"
if [[ "$(get_name)" == "$want" ]]; then
  log "${want}.local に戻しました（SetHostName）"
  exit 0
fi

# --- 2段目: avahi-daemon を再起動 ---
systemctl restart avahi-daemon
sleep "$SETTLE_SEC"
if [[ "$(get_name)" == "$want" ]]; then
  log "${want}.local に戻しました（avahi-daemon 再起動）"
else
  log "戻せませんでした（現在: $(get_name).local）。原因側の設定を確認してください。"
fi
exit 0
