# avahi-name-guard

English | [日本語](README.ja.md)

Automatically restores the mDNS host name on DGX Spark (or any Linux host running avahi) when avahi renames it from `foo.local` to `foo-2.local`.

## What is happening

When avahi-daemon believes its name is already taken on the network, it renames itself with `-2`, `-3`, … (RFC 6762 conflict resolution).
Even with no other host using the same name, avahi can mistake **its own announcements** for someone else's when the host is on the same network through **multiple interfaces**, and rename itself (a known avahi issue).

DGX Spark is particularly prone to this:

- Wired 10GbE (usually `enP7s7`) and Wi-Fi (usually `wlP9s9`) connected to the same LAN
- ConnectX-7 exposes two netdevs per physical port (e.g. `enp1s0f0np0` and `enP2p1s0f0np0`)
- Re-announcements every time an IPv6 address is added or changes
- Bridges such as docker0

## How it works

| Layer | What it does |
|---|---|
| Auto-repair | A systemd timer checks avahi's current host name over D-Bus every 30 s. If it has drifted, it is restored with `SetHostName`; if that fails, avahi-daemon is restarted |
| Safety check | If the original name is **really in use by another host** (it resolves to an address that is not ours), the name is left alone and only a warning is logged |
| Flap protection | At most 6 fixes per hour. Beyond that it logs a message asking you to fix the root cause and stops |
| Root-cause fix (optional) | `install.sh --auto-iface` / `--iface` restricts the interfaces avahi uses; `--no-ipv6` disables IPv6 in avahi |

No avahi-utils needed — it only uses `busctl` (part of systemd).

## Install

On each host:

```bash
git clone https://github.com/chai-md/avahi-name-guard && cd avahi-name-guard
# or: tar xzf avahi-name-guard.tar.gz && cd avahi-name-guard

# Start with the watchdog only
sudo ./install.sh

# If renames keep recurring, also restrict avahi (publish only on the default-route interface)
sudo ./install.sh --auto-iface
# Or specify interfaces explicitly (check names with: ip -br addr)
sudo ./install.sh --iface enP7s7
```

`--auto-iface` / `--iface` rewrites `allow-interfaces=` in avahi-daemon.conf (the original is kept as `.bak.<timestamp>`).

> **Note**: If you rely on mDNS over ConnectX-7 (e.g. NVIDIA's cluster discovery scripts), restricting avahi to the LAN only will break discovery. In that case, list the LAN interface plus **only one netdev per physical port**.
> Example: `--iface enP7s7,enp1s0f0np0,enp1s0f1np1` (leave out the duplicate `enP2p…` netdevs)

After installation the cloned/extracted directory is no longer needed; everything is copied to `/usr/local/sbin` and `/etc/systemd/system`. Keep it if you want to use `./install.sh --uninstall` later.

## Deploying to multiple hosts

Use Tailscale names or IP addresses so it works even while mDNS names are broken:

```bash
for h in foo bar baz; do
  scp avahi-name-guard.tar.gz "$h":/tmp/ &&
  ssh -t "$h" 'cd /tmp && tar xzf avahi-name-guard.tar.gz && cd avahi-name-guard && sudo ./install.sh'
done
```

## Checking and troubleshooting

```bash
journalctl -t avahi-name-guard -f              # repair log
systemctl list-timers avahi-name-guard.timer   # timer status
journalctl -u avahi-daemon | grep -E 'conflict|Registering new address'  # what happened right before a rename
```

Look at the `Registering new address record … on <IF>` lines just before `Host name conflict, retrying with foo-2` to see which interface triggers the rename.

## Configuration

Edit `/etc/systemd/system/avahi-name-guard.service` (or use `systemctl edit avahi-name-guard.service`):

| Variable | Default | Meaning |
|---|---|---|
| `MAX_FIX_PER_HOUR` | 6 | Maximum repairs per hour before giving up |
| `SETTLE_SEC` | 6 | Seconds to wait after each repair step before re-checking |
| `WANT_NAME` | static host name | Name to restore (without `.local`) |

## Uninstall

```bash
sudo ./install.sh --uninstall
```

Or manually:

```bash
sudo systemctl disable --now avahi-name-guard.timer
sudo rm -f /etc/systemd/system/avahi-name-guard.{service,timer} /usr/local/sbin/avahi-name-guard
sudo systemctl daemon-reload
```

To revert avahi settings, restore `/etc/avahi/avahi-daemon.conf.bak.*` and run `sudo systemctl restart avahi-daemon`.
