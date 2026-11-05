#!/usr/bin/env bash
# avahi-name-guard
#   When avahi-daemon renames itself to "<host>-2.local" (e.g. due to a
#   self-conflict), restore the original name "<host>.local".
#   - Does nothing if another host really owns the name (warning only)
#   - Limits fixes per hour; on flapping, asks you to fix the root cause
#   Requires: systemd (busctl), iproute2, avahi-daemon (avahi-utils not needed)
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
  log "Cannot reach avahi over D-Bus (skipping)"
  exit 0
fi
[[ "$cur" == "$want" ]] && exit 0

log "mDNS name is ${cur}.local (expected ${want}.local)"

# --- Make sure no other host really owns want.local ---
own_addrs=$(ip -o addr show | awk '{split($4,a,"/"); print a[1]}')
if out=$("${AV[@]}" ResolveHostName iisiu -1 -1 "${want}.local" -1 0 2>/dev/null); then
  # Example output: iisisu 2 0 "foo.local" 0 "192.0.2.10" 0
  addr=$(awk '{print $6}' <<<"$out" | tr -d '"')
  addr=${addr%%%*}
  if [[ -n "$addr" ]] && ! grep -qxF "$addr" <<<"$own_addrs"; then
    log "WARNING: ${want}.local is in use by another host (${addr}). Not restoring."
    exit 0
  fi
fi

# --- Rate limit (flap protection) ---
mkdir -p "$STATE_DIR"
now=$(date +%s)
hist="$STATE_DIR/fixes"
touch "$hist"
awk -v t=$((now - 3600)) '$1 > t' "$hist" > "$hist.tmp" && mv "$hist.tmp" "$hist"
count=$(wc -l < "$hist")
if (( count >= MAX_FIX_PER_HOUR )); then
  log "Already fixed ${count} times in the last hour; renames keep recurring. Restrict avahi's interfaces (e.g. install.sh --auto-iface)."
  exit 0
fi
echo "$now" >> "$hist"

# --- Step 1: restore the name over D-Bus ---
"${AV[@]}" SetHostName s "$want" >/dev/null 2>&1
sleep "$SETTLE_SEC"
if [[ "$(get_name)" == "$want" ]]; then
  log "Restored ${want}.local (SetHostName)"
  exit 0
fi

# --- Step 2: restart avahi-daemon ---
systemctl restart avahi-daemon
sleep "$SETTLE_SEC"
if [[ "$(get_name)" == "$want" ]]; then
  log "Restored ${want}.local (avahi-daemon restart)"
else
  log "Could not restore (current: $(get_name).local). Check the root cause."
fi
exit 0
