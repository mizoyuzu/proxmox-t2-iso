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
# 実際には udev の modalias で大半が自動ロードされる。強制ロードは
# preseed.cfg の preseed/early_command 側でも指定して二重化してある。
mkdir -p etc/modprobe.d
for m in t2bce_core t2bce_dma t2bce_vhci nvme_apple brcmfmac hid_appletb_kbd \
         appletbdrm; do
  echo "$m" >> etc/modprobe.d/t2-early.conf
done
# ファームウェア注入 (Wi-Fi BCM4364 / BT BCM4377 他、実機の実績セット)
mkdir -p lib/firmware/brcm
cp -a "$ROOT/firmware-files/brcm/." lib/firmware/brcm/ 2>/dev/null \
  || echo "WARN: firmware-files/brcm が無い。firmware/ の sha256 目録から実機分を配置すること"
# preseed を initrd ルートに同梱 (d-i が自動で拾う)
cp "$ROOT/preseed.cfg" ./preseed.cfg
find . | cpio -o -H newc --quiet | gzip -9 > "$TREE/install.amd/initrd.gz"
cd - >/dev/null

# --- 4. GRUB / isolinux: 自動インストールを先頭+デフォルトにする ---
# 実物確認済み (Debian 13.7.0 netinst): /boot/grub/grub.cfg の各 menuentry は
# /install.amd/vmlinuz + /install.amd/initrd.gz (gtk は gtk/initrd.gz) を使う。
# EFI 側は /efi/debian/grub.cfg が /.disk/id/<uuid> を探して本 grub.cfg を読む
# ため、インプレース再構築 (手順6) で .disk/id を壊さないことが重要。
python3 - "$TREE/boot/grub/grub.cfg" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
entry = """set default=0
set timeout=5
menuentry --hotkey=a 'Automated install (T2 Proxmox)' {
    set background_color=black
    linux    /install.amd/vmlinuz auto=true priority=critical vga=788 --- quiet
    initrd   /install.amd/initrd.gz
}
"""
open(path, "w").write(entry + src)
print("grub.cfg: T2 automated entry prepended")
PYEOF
# BIOS (isolinux) 側にも自動インストール項目を追加 (MBP は UEFI のみだが保険)
cat >> "$TREE/isolinux/txt.cfg" <<'EOF'
label t2auto
	menu label ^Automated install (T2 Proxmox)
	kernel /install.amd/vmlinuz
	append auto=true priority=critical vga=788 initrd=/install.amd/initrd.gz --- quiet
EOF

# --- 5. /t2 ペイロード ---
mkdir -p "$TREE/t2/debs" "$TREE/t2/scripts"
cp "$KERNEL_DEB_DIR"/*.deb "$TREE/t2/debs/"
cp "$ROOT/scripts/first-boot-proxmox.sh" "$TREE/t2/scripts/"
chmod +x "$TREE/t2/scripts/first-boot-proxmox.sh"

# --- 6. md5sum 再生成 + ISO 再構築 (インプレース方式) ---
# 元 ISO を土台にファイルだけ差し替える。El Torito (isolinux + EFI の
# /boot/grub/efi.img) と /.disk/id/<uuid> は元 ISO のものを保持するのが肝。
# 一から mkisofs すると EFI スタブが探す .disk/id の UUID がずれてブートしない。
(cd "$TREE" && find . -type f -print0 | sort -z | xargs -0 md5sum > md5sum.txt)
xorriso -indev "$DEBIAN_ISO" -outdev "$OUT_ISO" \
  -boot_image isolinux keep -boot_image grub keep \
  -map "$TREE" / -commit

# --- 検証: ブートイメージが両方残っていること ---
echo "=== El Torito report (BIOS + EFI の2つがあること) ==="
xorriso -indev "$OUT_ISO" -report_el_torito plain 2>/dev/null | grep -E "El Torito boot img|Boot image" || true

echo "done: $OUT_ISO (ブート実地確認はカーネル .deb が揃ってから QEMU / 実機で)"
