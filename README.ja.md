# avahi-name-guard

[English](README.md) | 日本語

DGX Spark（または avahi が動いている任意の Linux ホスト）で mDNS 名が `foo.local` から `foo-2.local` に変わってしまう問題を、自動で元に戻す仕組みです。

## 何が起きているか

avahi-daemon は「同じ名前が既にネットワーク上にある」と判断すると、`-2`, `-3` … を付けて改名します（RFC 6762 の衝突解決）。
同名の別ホストがいなくても、**同じホストが同じネットワークに複数のインターフェースで出ている**と、自分自身の告知を他人のものと誤認して改名することがあります（avahi の既知の問題）。

DGX Spark はこの条件を満たしやすい構成です。

- 有線 10GbE（通常 `enP7s7`）と Wi-Fi（通常 `wlP9s9`）が同じ LAN につながっている
- ConnectX-7 は物理 1 ポートあたり netdev が 2 本見える（`enp1s0f0np0` と `enP2p1s0f0np0` など）
- IPv6 アドレスが追加・変化するたびに再告知される
- docker0 などのブリッジ

## 仕組み

| 層 | 内容 |
|---|---|
| 自動修復 | systemd タイマーで 30 秒ごとに avahi の現在名を D-Bus で確認。ズレていたら `SetHostName` で戻し、だめなら avahi-daemon を再起動 |
| 安全装置 | 本来の名前を**別ホストが本当に使っている**場合（解決結果が自分のアドレスでない）は戻さず警告だけ出す |
| フラップ防止 | 修正は 1 時間に 6 回まで。超えたら原因対策を促すログを出して止まる |
| 原因対策（任意） | `install.sh --auto-iface` / `--iface` で avahi が使うインターフェースを限定、`--no-ipv6` で IPv6 を無効化 |

avahi-utils は不要で、`busctl`（systemd 標準）だけで動きます。

## 導入

各ホストで:

```bash
git clone https://github.com/chai-md/avahi-name-guard && cd avahi-name-guard
# または: tar xzf avahi-name-guard.tar.gz && cd avahi-name-guard

# まず監視だけ入れる
sudo ./install.sh

# 再発が多ければ原因側も絞る（デフォルトルートのIFだけで mDNS を出す）
sudo ./install.sh --auto-iface
# IF を明示する場合（ip -br addr で名前を確認）
sudo ./install.sh --iface enP7s7
```

`--auto-iface` / `--iface` を使うと、avahi-daemon.conf の `allow-interfaces=` を書き換えます（元のファイルは `.bak.日時` で残します）。

> **注意**: ConnectX-7 経由の mDNS（NVIDIA のクラスタ検出スクリプトなど）を使っている場合、LAN だけに絞ると検出できなくなります。その場合は LAN 側と、**物理ポートごとに 1 本だけ**を指定してください。
> 例: `--iface enP7s7,enp1s0f0np0,enp1s0f1np1`（`enP2p…` 側の重複 netdev は外す）

インストール後、clone・展開したディレクトリは不要です（`/usr/local/sbin` と `/etc/systemd/system` にコピー済み）。後で `./install.sh --uninstall` を使う場合は残しておいてください。

## 複数台へまとめて展開

mDNS 名が壊れている最中でも届くように、Tailscale 名か IP で:

```bash
for h in foo bar baz; do
  scp avahi-name-guard.tar.gz "$h":/tmp/ &&
  ssh -t "$h" 'cd /tmp && tar xzf avahi-name-guard.tar.gz && cd avahi-name-guard && sudo ./install.sh'
done
```

## 確認・調査

```bash
journalctl -t avahi-name-guard -f              # 修復ログ
systemctl list-timers avahi-name-guard.timer   # タイマー状態
journalctl -u avahi-daemon | grep -E 'conflict|Registering new address'  # 改名の直前に何が起きたか
```

`Host name conflict, retrying with foo-2` の直前の `Registering new address record … on <IF>` を見ると、どのインターフェースが引き金になっているかが分かります。

## 設定

`/etc/systemd/system/avahi-name-guard.service` を編集（または `systemctl edit avahi-name-guard.service`）:

| 変数 | 既定値 | 意味 |
|---|---|---|
| `MAX_FIX_PER_HOUR` | 6 | 1 時間あたりの修正回数の上限 |
| `SETTLE_SEC` | 6 | 各修正ステップ後、再確認までの待ち秒数 |
| `WANT_NAME` | 静的ホスト名 | 戻す先の名前（`.local` なし） |

## 削除

```bash
sudo ./install.sh --uninstall
```

手動の場合:

```bash
sudo systemctl disable --now avahi-name-guard.timer
sudo rm -f /etc/systemd/system/avahi-name-guard.{service,timer} /usr/local/sbin/avahi-name-guard
sudo systemctl daemon-reload
```

avahi の設定を戻す場合は `/etc/avahi/avahi-daemon.conf.bak.*` を戻して `sudo systemctl restart avahi-daemon` を実行してください。
