#!/bin/bash
# first-boot-proxmox.sh — Debian 13 (T2 カーネル) の初回起動後に1回だけ実行し、
# Proxmox VE を重ねる。preseed の late_command から、または手動で実行する。
# 公式手順 (Install Proxmox VE on Debian 13 Trixie) 準拠。
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

HOSTNAME_FQDN="$(hostname -f)"
IP_ADDR="$(hostname -I | awk '{print $1}')"

# --- /etc/hosts: FQDN が実 IP を指すこと (PVE の前提) ---
grep -q "$HOSTNAME_FQDN" /etc/hosts || \
  echo "$IP_ADDR $HOSTNAME_FQDN $(hostname -s)" >> /etc/hosts

# --- Proxmox リポジトリ (Debian 13 = deb822 形式, pve-no-subscription) ---
cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
wget -q https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
  -O /usr/share/keyrings/proxmox-archive-keyring.gpg

apt-get update
# proxmox-ve は proxmox-default-kernel を引いてくるが、ブートは T2 カーネルに
# 固定する (下記)。パッケージ自体は依存解決のため入れて構わない。
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  proxmox-ve postfix open-iscsi chrony ifupdown2

# --- ブート固定: GRUB のデフォルトを T2 カーネルにする ---
T2_ENTRY="$(grep -o "gnulinux-[^']*t2-pve[^']*" /boot/grub/grub.cfg | head -1 || true)"
if [ -n "$T2_ENTRY" ]; then
  sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$T2_ENTRY\"|" /etc/default/grub
  grep -q '^GRUB_DEFAULT=' /etc/default/grub || echo "GRUB_DEFAULT=\"$T2_ENTRY\"" >> /etc/default/grub
  update-grub
  echo "GRUB default pinned to T2 kernel entry: $T2_ENTRY"
else
  echo "WARN: T2 カーネルの GRUB エントリが見つからない。手動確認が必要" >&2
fi
# Debian 標準カーネルは消して誤ブートを防ぐ (T2 では内蔵 SSD が見えないため危険)
apt-get remove -y linux-image-amd64 'linux-image-6.*-amd64' || true

# --- ネットワーク: vmbr0 (物理 NIC をブリッジ) ---
# /etc/network/interfaces の書き換えは実機の NIC 名 (wlp3s0 / 有線) を見て
# 試験後に確定する。Wi-Fi をアップリンクにする場合は hostapd 的な構成は使えず、
# routed 構成 (vmbr0 は NAT) になる点に注意。
echo "TODO: vmbr0 構成は実機 NIC を確認してから確定"

systemctl enable pve-cluster pvedaemon pveproxy pvestatd 2>/dev/null || true
echo "Proxmox 化完了。再起動して T2 カーネルで上がることを確認すること。"
echo "Web UI: https://${IP_ADDR}:8006"
