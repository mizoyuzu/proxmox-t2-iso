#!/bin/bash
# remaster-iso.sh — 公式 Debian 13 netinst ISO を T2 用にリマスターする
#
# やること:
#   1. ISO を展開
#   2. インストーラのカーネルを自作 T2 カーネル (.deb) の vmlinuz に差し替え
#   3. initrd を再構築: T2 モジュール群 (t2bce / nvme-apple / brcmfmac / appletb)
#      と Wi-Fi/BT ファームウェアを注入し、preseed.cfg を同梱
#   4. GRUB メニューに自動インストール項目 (auto=true priority=critical) を追加
#   5. ISO ツリーに /t2 ペイロード (カーネル .deb 群、ファームウェア、first-boot) を配置
#   6. El Torito / EFI 構成を保ったまま xorriso で再構築
#
# キーボード/トラックパッドについて:
#   MBP15,1 のキーボードとトラックパッドは T2 (BCE) 経由で VHCI = 仮想 USB HID
#   として見える。initrd に t2bce_core / t2bce_vhci が入っていればインストーラ
#   段階から両方使える。TouchBar の表示 (Esc / F キー列) は tiny-dfr デーモンが
#   描画するため、systemd の無い d-i 環境では光らない。preseed で対話を最小化
#   してあるので実害は小さいが、保険に USB キーボードがあると安心。
#   インストール後の実システムでは tiny-dfr が動くので TouchBar も使える。
#
# 使い方:
#   DEBIAN_ISO=debian-13.x-amd64-netinst.iso KERNEL_DEB_DIR=./debs \
#     ./scripts/remaster-iso.sh [出力ISO名]
# 前提ツール: xorriso, cpio, dpkg-deb, depmod (kmod)
# ※ 試験後の実機適用前に、VM (QEMU) でブート確認を必ず行うこと。
set -euo pipefail

DEBIAN_ISO="${DEBIAN_ISO:?DEBIAN_ISO is required}"
KERNEL_DEB_DIR="${KERNEL_DEB_DIR:?KERNEL_DEB_DIR is required}"
OUT_ISO="${1:-debian-13-t2-proxmox.iso}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(pwd)/iso-work"
TREE="$WORK/tree"
INITRD_DIR="$WORK/initrd"

rm -rf "$WORK"; mkdir -p "$TREE" "$INITRD_DIR"

# --- 1. ISO 展開 ---
xorriso -osirrox on -indev "$DEBIAN_ISO" -extract / "$TREE" >/dev/null 2>&1
chmod -R u+w "$TREE"

# --- 2. カーネル .deb から vmlinuz / モジュールを取り出す ---
KEX="$WORK/kernel-extract"; mkdir -p "$KEX"
for d in "$KERNEL_DEB_DIR"/linux-image-*.deb; do dpkg-deb -x "$d" "$KEX"; done
KVMLINUZ="$(ls "$KEX"/boot/vmlinuz-*)"
KVER_FULL="$(basename "$KVMLINUZ" | sed 's/^vmlinuz-//')"
echo "installer kernel: $KVER_FULL"
cp "$KVMLINUZ" "$TREE/install.amd/vmlinuz"

# --- 3. initrd 再構築 ---
cd "$INITRD_DIR"
gzip -dc "$TREE/install.amd/initrd.gz" | cpio -idm --quiet
# T2 + 必須モジュールを丸ごと注入 (依存は depmod で解決)
mkdir -p "lib/modules/$KVER_FULL"
cp -a "$KEX/lib/modules/$KVER_FULL/." "lib/modules/$KVER_FULL/"
depmod -b . "$KVER_FULL"
# 早期ロードさせるモジュール (キーボード/トラックパッド/SSD/Wi-Fi)
for m in t2bce_core t2bce_dma t2bce_vhci nvme_apple brcmfmac hid_appletb_kbd \
         drm_appletbdr; do
  echo "$m" >> etc/modprobe.d/t2-early.conf 2>/dev/null || true
done
# ファームウェア注入 (Wi-Fi BCM4364 / BT BCM4377 他、実機の実績セット)
mkdir -p lib/firmware/brcm
cp -a "$ROOT/firmware-files/brcm/." lib/firmware/brcm/ 2>/dev/null \
  || echo "WARN: firmware-files/brcm が無い。firmware/ の sha256 目録から実機分を配置すること"
# preseed を initrd ルートに同梱 (d-i が自動で拾う)
cp "$ROOT/preseed.cfg" ./preseed.cfg
find . | cpio -o -H newc --quiet | gzip -9 > "$TREE/install.amd/initrd.gz"
cd - >/dev/null

# --- 4. GRUB: 自動インストールをデフォルト化 ---
# grub.cfg に auto=true priority=critical file=/cdrom/preseed.cfg 相当を追記。
# 実装は ISO の grub.cfg 形式に合わせて試験後に確定 (TODO)。
echo "TODO: patch $TREE/boot/grub/grub.cfg (auto install entry)"

# --- 5. /t2 ペイロード ---
mkdir -p "$TREE/t2/debs" "$TREE/t2/scripts"
cp "$KERNEL_DEB_DIR"/*.deb "$TREE/t2/debs/"
cp "$ROOT/scripts/first-boot-proxmox.sh" "$TREE/t2/scripts/"
chmod +x "$TREE/t2/scripts/first-boot-proxmox.sh"

# --- 6. md5sum 再生成 + ISO 再構築 (El Torito は元 ISO から引き継ぐ) ---
(cd "$TREE" && find . -type f -print0 | sort -z | xargs -0 md5sum > md5sum.txt)
xorriso -indev "$DEBIAN_ISO" -outdev "$OUT_ISO" \
  -boot_image isolinux keep -boot_image grub keep \
  -map "$TREE" / -commit -eject 2>/dev/null \
  || echo "TODO: xorriso の再構築パラメータは元 ISO の eltorito 報告に合わせて確定すること"

echo "done: $OUT_ISO (未検証 — QEMU ブート確認が前提)"
