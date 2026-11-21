#!/bin/bash
# remaster-iso.sh — 公式 Debian 13 netinst ISO を T2 用にリマスターする
#
# FIRMWARE_DIR を指定した場合は、そのディレクトリの内容を
# /t2/firmware/brcm/ に追加する (インストーラ initrd には入れない)。
# Apple ファームウェアを公開リポジトリへコミットしないこと。
set -euo pipefail

DEBIAN_ISO="${DEBIAN_ISO:?DEBIAN_ISO is required}"
KERNEL_DEB_DIR="${KERNEL_DEB_DIR:?KERNEL_DEB_DIR is required}"
OUT_ISO="${1:-debian-13-t2-proxmox.iso}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
WORK="$(pwd)/iso-work"
TREE="$WORK/tree"
INITRD_DIR="$WORK/initrd"
INITRD_VERIFY_DIR="$WORK/initrd-verify"

if ! command -v fakeroot >/dev/null 2>&1; then
  echo "ERROR: fakeroot is required to extract and repack the installer initrd as a non-root user" >&2
  exit 1
fi
for tool in xorriso cpio dpkg-deb depmod python3 gzip md5sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $tool" >&2
    exit 1
  fi
done
if [[ ! -r "$DEBIAN_ISO" ]]; then
  echo "ERROR: Debian ISO is not readable: $DEBIAN_ISO" >&2
  exit 1
fi
if [[ ! -d "$KERNEL_DEB_DIR" ]]; then
  echo "ERROR: kernel deb directory does not exist: $KERNEL_DEB_DIR" >&2
  exit 1
fi
if [[ ! -f "$ROOT/preseed.cfg" ]]; then
  echo "ERROR: preseed file is missing: $ROOT/preseed.cfg" >&2
  exit 1
fi
if [[ ! -f "$ROOT/scripts/first-boot-proxmox.sh" ]]; then
  echo "ERROR: first-boot script is missing: $ROOT/scripts/first-boot-proxmox.sh" >&2
  exit 1
fi
if [[ ! -f "$ROOT/scripts/first-boot-proxmox.service" ]]; then
  echo "ERROR: first-boot systemd unit is missing: $ROOT/scripts/first-boot-proxmox.service" >&2
  exit 1
fi

if [[ -n "${FIRMWARE_DIR:-}" && ! -d "$FIRMWARE_DIR" ]]; then
  echo "ERROR: FIRMWARE_DIR is set but is not a directory: $FIRMWARE_DIR" >&2
  exit 1
fi
if [[ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" && ! -f "$SSH_AUTHORIZED_KEYS_FILE" ]]; then
  echo "ERROR: SSH_AUTHORIZED_KEYS_FILE is set but is not a regular file: $SSH_AUTHORIZED_KEYS_FILE" >&2
  exit 1
fi
if [[ "${SSH_AUTHORIZED_KEYS_FILE+x}" == x && -z "$SSH_AUTHORIZED_KEYS_FILE" ]]; then
  echo "ERROR: SSH_AUTHORIZED_KEYS_FILE is set but empty" >&2
  exit 1
fi

shopt -s nullglob
KERNEL_DEBS=("$KERNEL_DEB_DIR"/linux-image-*.deb)
shopt -u nullglob
if (( ${#KERNEL_DEBS[@]} == 0 )); then
  echo "ERROR: no linux-image-*.deb files found in $KERNEL_DEB_DIR" >&2
  exit 1
fi

rm -rf -- "$WORK"
mkdir -p "$TREE" "$INITRD_DIR"

# --- 1. ISO 展開 ---
xorriso -osirrox on -indev "$DEBIAN_ISO" -extract / "$TREE" >/dev/null
chmod -R u+w "$TREE"

# Debian EFI stub expects the original /.disk/id. Keep it in the extracted tree.
if [[ ! -e "$TREE/.disk/id" ]]; then
  echo "ERROR: source ISO does not contain /.disk/id; refusing to rebuild" >&2
  exit 1
fi

# --- 2. カーネル .deb から vmlinuz / モジュールを取り出す ---
KEX="$WORK/kernel-extract"
mkdir -p "$KEX"
for deb in "${KERNEL_DEBS[@]}"; do
  dpkg-deb -x "$deb" "$KEX"
done
mapfile -t KERNEL_IMAGES < <(find "$KEX/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -print | sort)
if (( ${#KERNEL_IMAGES[@]} != 1 )); then
  echo "ERROR: expected exactly one boot/vmlinuz-* in linux-image debs, found ${#KERNEL_IMAGES[@]}" >&2
  exit 1
fi
KVMLINUZ="${KERNEL_IMAGES[0]}"
KVER_FULL="$(basename "$KVMLINUZ" | sed 's/^vmlinuz-//')"
MODULES_DIR="$KEX/lib/modules/$KVER_FULL"
if [[ ! -d "$MODULES_DIR" ]]; then
  echo "ERROR: kernel modules are missing from linux-image debs: $MODULES_DIR" >&2
  exit 1
fi
echo "installer kernel: $KVER_FULL"
cp -- "$KVMLINUZ" "$TREE/install.amd/vmlinuz"

# --- 3. initrd 再構築 ---
# fakeroot supplies the root/device-node metadata cpio needs without requiring
# privileges from the Actions runner. Extraction and repacking share one
# fakeroot metadata session so cpio's fake device nodes retain their types.
fakeroot -- bash -c '
set -euo pipefail
initrd_dir="$1"
initrd_gz="$2"
modules_dir="$3"
kver="$4"
preseed="$5"

cd "$initrd_dir"
gzip -dc "$initrd_gz" | cpio -idm --quiet
mkdir -p "lib/modules/$kver"
cp -a "$modules_dir/." "lib/modules/$kver/"
depmod -b "$initrd_dir" "$kver"

# brcm firmware is post-install payload only, never part of the installer initrd.
rm -rf -- lib/firmware/brcm

# Early-load T2 devices; NVME_APPLE is Apple-Silicon-only.
mkdir -p etc/modprobe.d
printf "%s\\n" t2bce_core t2bce_dma t2bce_vhci hid_appletb_kbd appletbdrm brcmfmac > etc/modprobe.d/t2-early.conf
cp -- "$preseed" ./preseed.cfg

find . -print0 | cpio --null -o -H newc --quiet | gzip -9 > "$initrd_gz"
' bash "$INITRD_DIR" "$TREE/install.amd/initrd.gz" "$MODULES_DIR" "$KVER_FULL" "$ROOT/preseed.cfg"

# Re-extract the packed archive and check device-node types while the same
# fakeroot metadata session is alive. A separate fakeroot invocation would
# not retain the fake device metadata created by cpio.
mkdir -p "$INITRD_VERIFY_DIR"
if ! fakeroot -- bash -c 'set -euo pipefail; cd "$1"; gzip -dc "$2" | cpio -idm --quiet; test -c "$1/dev/console"; test -c "$1/dev/null"' \
  bash "$INITRD_VERIFY_DIR" "$TREE/install.amd/initrd.gz"; then
  rm -rf -- "$INITRD_VERIFY_DIR"
  echo "ERROR: rebuilt initrd failed validation: /dev/console and /dev/null must be character devices" >&2
  exit 1
fi
rm -rf -- "$INITRD_VERIFY_DIR"

# --- 4. GRUB / isolinux: preserve normal install as the safe default ---
# Debian 13.7.0 amd64's top-level entries start with Graphical install, Install.
# Put the final global settings after the source config so no later source line
# can override them, then append the explicitly-selected automated entry.
python3 - "$TREE/boot/grub/grub.cfg" <<'PYEOF'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as config:
    src = config.read()

if not re.search(r"(?m)^menuentry\b[^\n]*'Install'[^\n]*\{", src):
    raise SystemExit("ERROR: Debian GRUB config has no normal 'Install' menu entry")

# Do not retain earlier assignments that may compete with these final values.
src = re.sub(r"(?m)^[ \t]*set[ \t]+(?:default|timeout)=.*(?:\n|$)", "", src)
# vga=788 is deprecated; remove it from the stock Debian entries too.
src = re.sub(r"\bvga=788\b[ \t]*", "", src)
entry = """
set default=\"Install\"
set timeout=30
menuentry --hotkey=a 'Automated install (T2 Proxmox) - uses largest free space' {
    set background_color=black
    linux    /install.amd/vmlinuz auto=true priority=critical preseed/file=/preseed.cfg --- quiet
    initrd   /install.amd/initrd.gz
}
"""
with open(path, "w", encoding="utf-8") as config:
    config.write(src.rstrip() + "\n" + entry.lstrip())
print("grub.cfg: default=Install, timeout=30, T2 automated entry appended")
PYEOF

# BIOS (isolinux) fallback; deliberately leave its existing default unchanged.
if [[ ! -f "$TREE/isolinux/txt.cfg" ]]; then
  echo "ERROR: source ISO is missing /isolinux/txt.cfg" >&2
  exit 1
fi
python3 - "$TREE/isolinux" <<'PYEOF'
import re
import sys
from pathlib import Path

for path in Path(sys.argv[1]).rglob("*.cfg"):
    src = path.read_text(encoding="utf-8")
    updated = re.sub(r"\bvga=788\b[ \t]*", "", src)
    if updated != src:
        path.write_text(updated, encoding="utf-8")
PYEOF
cat >> "$TREE/isolinux/txt.cfg" <<'EOF'

label t2auto
 menu label ^Automated install (T2 Proxmox) - uses largest free space
 kernel /install.amd/vmlinuz
 append auto=true priority=critical preseed/file=/preseed.cfg initrd=/install.amd/initrd.gz --- quiet
EOF

# --- 5. /t2 post-install payload ---
mkdir -p "$TREE/t2/debs" "$TREE/t2/scripts" "$TREE/t2/systemd"
for deb in "${KERNEL_DEBS[@]}"; do
  cp -- "$deb" "$TREE/t2/debs/"
done
cp -- "$ROOT/scripts/first-boot-proxmox.sh" "$TREE/t2/scripts/first-boot-proxmox.sh"
chmod 0755 "$TREE/t2/scripts/first-boot-proxmox.sh"
cp -- "$ROOT/scripts/first-boot-proxmox.service" "$TREE/t2/systemd/first-boot-proxmox.service"

if [[ -n "${FIRMWARE_DIR:-}" ]]; then
  mkdir -p "$TREE/t2/firmware/brcm"
  cp -a "$FIRMWARE_DIR"/. "$TREE/t2/firmware/brcm/"
  echo "Firmware included in post-install payload from FIRMWARE_DIR=$FIRMWARE_DIR"
else
  echo "NOTE: FIRMWARE_DIR is unset/empty; /t2/firmware/brcm is omitted per public-repository firmware policy."
fi

if [[ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" ]]; then
  mkdir -p "$TREE/t2/ssh"
  install -m 0600 -- "$SSH_AUTHORIZED_KEYS_FILE" "$TREE/t2/ssh/authorized_keys"
fi

# --- 6. md5sum 再生成 + ISO 再構築 (インプレース方式) ---
# Keep original El Torito BIOS/EFI boot images and /.disk/id from the source.
(cd "$TREE" && find . -type f ! -path './md5sum.txt' -print0 | sort -z | xargs -0 -r md5sum > md5sum.txt)
if [[ "$(realpath -m "$OUT_ISO")" == "$(realpath -e "$DEBIAN_ISO")" ]]; then
  echo "ERROR: output ISO must not overwrite the Debian source ISO" >&2
  exit 1
fi
cp --reflink=auto -- "$DEBIAN_ISO" "$OUT_ISO"
if ! xorriso -indev "$OUT_ISO" -outdev "$OUT_ISO" \
  -boot_image any keep \
  -map "$TREE" / -commit; then
  echo "ERROR: xorriso failed to write remastered ISO: $OUT_ISO" >&2
  exit 1
fi

# --- Verify both original boot images survived the in-place rebuild ---
echo "=== El Torito report (BIOS + EFI の2つがあること) ==="
if ! BOOT_REPORT="$(xorriso -indev "$OUT_ISO" -report_el_torito plain 2>&1)"; then
  printf '%s\n' "$BOOT_REPORT" >&2
  echo "ERROR: could not inspect El Torito boot images in $OUT_ISO" >&2
  exit 1
fi
printf '%s\n' "$BOOT_REPORT"
BOOT_IMAGE_COUNT="$(grep -c 'El Torito boot img' <<< "$BOOT_REPORT" || true)"
if [[ "$BOOT_IMAGE_COUNT" != 2 ]] || ! grep -q 'BIOS' <<< "$BOOT_REPORT" || ! grep -Eq 'UEFI|EFI' <<< "$BOOT_REPORT"; then
  echo "ERROR: expected exactly two El Torito boot images (BIOS and EFI), found $BOOT_IMAGE_COUNT" >&2
  exit 1
fi

echo "done: $OUT_ISO"
