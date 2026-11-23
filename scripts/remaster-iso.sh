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
if [[ ! -f "$ROOT/scripts/partman-t2-guard.sh" ]]; then
  echo "ERROR: partman safety guard is missing: $ROOT/scripts/partman-t2-guard.sh" >&2
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
# Keep the stock Debian kernel for the untouched GTK initrd, which contains
# Debian ABI modules. GTK entries are redirected before the T2 kernel replaces
# /install.amd/vmlinuz; text and T2-auto entries keep using the T2 kernel.
if [[ ! -f "$TREE/install.amd/vmlinuz" ]]; then
  echo "ERROR: source ISO is missing /install.amd/vmlinuz" >&2
  exit 1
fi
cp -- "$TREE/install.amd/vmlinuz" "$TREE/install.amd/vmlinuz-debian"
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

cd "$initrd_dir"
gzip -dc "$initrd_gz" | cpio -idm --quiet
rm -f -- preseed.cfg
mkdir -p "lib/modules/$kver"
cp -a "$modules_dir/." "lib/modules/$kver/"
depmod -b "$initrd_dir" "$kver"

# brcm firmware is post-install payload only, never part of the installer initrd.
rm -rf -- lib/firmware/brcm

find . -print0 | cpio --null -o -H newc --quiet | gzip -9 > "$initrd_gz"
' bash "$INITRD_DIR" "$TREE/install.amd/initrd.gz" "$MODULES_DIR" "$KVER_FULL"

# Re-extract the packed archive and check device-node types while the same
# fakeroot metadata session is alive. A separate fakeroot invocation would
# not retain the fake device metadata created by cpio.
rm -rf -- "$INITRD_VERIFY_DIR"
mkdir -p "$INITRD_VERIFY_DIR"
if ! fakeroot -- bash -c 'set -euo pipefail; cd "$1"; gzip -dc "$2" | cpio -idm --quiet; test -c "$1/dev/console"; test -c "$1/dev/null"; test ! -e preseed.cfg' \
  bash "$INITRD_VERIFY_DIR" "$TREE/install.amd/initrd.gz"; then
  rm -rf -- "$INITRD_VERIFY_DIR"
  echo "ERROR: rebuilt initrd failed validation: device nodes must be character devices and preseed.cfg must be absent" >&2
  exit 1
fi
rm -rf -- "$INITRD_VERIFY_DIR"

# --- 3a. Preseed is included only by the explicit T2 automated entry ---
PRESEED_STAGE="$(mktemp -d "$WORK/preseed-stage.XXXXXX")"
PRESEED_VERIFY_DIR="$(mktemp -d "$WORK/preseed-verify.XXXXXX")"
cp -- "$ROOT/preseed.cfg" "$PRESEED_STAGE/preseed.cfg"
(cd "$PRESEED_STAGE" && printf '%s\n' preseed.cfg | cpio -o -H newc --owner=0:0 --quiet) > "$TREE/install.amd/preseed-initrd.cpio"
chmod 0644 "$TREE/install.amd/preseed-initrd.cpio"

PRESEED_MEMBERS="$(cpio -it < "$TREE/install.amd/preseed-initrd.cpio")"
if [[ "$PRESEED_MEMBERS" != "preseed.cfg" && "$PRESEED_MEMBERS" != "./preseed.cfg" ]]; then
  echo "ERROR: preseed initrd must contain only preseed.cfg, found: $PRESEED_MEMBERS" >&2
  exit 1
fi
(cd "$PRESEED_VERIFY_DIR" && cpio -idm --quiet < "$TREE/install.amd/preseed-initrd.cpio")
if ! cmp -s -- "$ROOT/preseed.cfg" "$PRESEED_VERIFY_DIR/preseed.cfg"; then
  echo "ERROR: preseed initrd contents differ from $ROOT/preseed.cfg" >&2
  exit 1
fi
if ! grep -q 'localechooser/languagelist select ja' "$PRESEED_VERIFY_DIR/preseed.cfg" ||
   ! grep -q 'debian-installer/language string ja' "$PRESEED_VERIFY_DIR/preseed.cfg"; then
  echo "ERROR: preseed must select ja in both localechooser/languagelist and debian-installer/language" >&2
  exit 1
fi

cat -- "$TREE/install.amd/preseed-initrd.cpio" "$TREE/install.amd/initrd.gz" > "$TREE/install.amd/initrd-t2auto"
chmod 0644 "$TREE/install.amd/initrd-t2auto"
PRESEED_INITRD_SIZE="$(stat -c '%s' "$TREE/install.amd/preseed-initrd.cpio")"
T2AUTO_INITRD_SIZE="$(stat -c '%s' "$TREE/install.amd/initrd-t2auto")"
if [[ "$(head -c 6 "$TREE/install.amd/preseed-initrd.cpio")" != "070701" ]] ||
   [[ "$(head -c 6 "$TREE/install.amd/initrd-t2auto")" != "070701" ]] ||
   ! cmp -n "$PRESEED_INITRD_SIZE" -- "$TREE/install.amd/preseed-initrd.cpio" "$TREE/install.amd/initrd-t2auto" ||
   ! tail -c "+$((PRESEED_INITRD_SIZE + 1))" "$TREE/install.amd/initrd-t2auto" | cmp - "$TREE/install.amd/initrd.gz" ||
   (( T2AUTO_INITRD_SIZE != PRESEED_INITRD_SIZE + $(stat -c '%s' "$TREE/install.amd/initrd.gz") )); then
  echo "ERROR: combined T2 initrd is not preseed cpio followed by the main initrd" >&2
  exit 1
fi
rm -rf -- "$PRESEED_STAGE" "$PRESEED_VERIFY_DIR"

# --- 4. GRUB / isolinux: preserve normal install as the safe default ---
# Debian 13.8.0 amd64's top-level entries start with Graphical install, Install.
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
menuentry --hotkey=t 'Automated install (T2 Proxmox) - uses largest free space' {
    set background_color=black
    linux    /install.amd/vmlinuz auto=true priority=critical preseed/file=/preseed.cfg --- quiet
    initrd   /install.amd/initrd-t2auto
}
"""
with open(path, "w", encoding="utf-8") as config:
    config.write(src.rstrip() + "\n" + entry.lstrip())
print("grub.cfg: default=Install, timeout=30, T2 automated entry appended")
PYEOF

# Verify the preseed appears only in the explicit T2 menu entry and normal Install remains safe.
python3 - "$TREE/boot/grub/grub.cfg" <<'PYEOF'
import re
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

def menuentries(text):
    lines = text.splitlines(keepends=True)
    entries = []
    index = 0

    def brace_delta(line):
        delta = 0
        quote = None
        escaped = False
        for char in line:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif quote:
                if char == quote:
                    quote = None
            elif char in "'\"":
                quote = char
            elif char == "#":
                break
            elif char == "{":
                delta += 1
            elif char == "}":
                delta -= 1
        return delta

    enclosing_depth = 0
    while index < len(lines):
        if not re.match(r"\s*menuentry\b", lines[index]):
            enclosing_depth += brace_delta(lines[index])
            index += 1
            continue
        start = index
        menuentry_depth = 0
        top_level = enclosing_depth == 0
        while index < len(lines):
            menuentry_depth += brace_delta(lines[index])
            index += 1
            if menuentry_depth == 0:
                break
        if menuentry_depth != 0:
            raise SystemExit("ERROR: unterminated GRUB menuentry")
        entries.append((start, index, "".join(lines[start:index]), top_level))
    return lines, entries

lines, entries = menuentries(src)
rewritten = []
cursor = 0
gtk_rewrites = 0
for start, end, entry, _top_level in entries:
    rewritten.extend(lines[cursor:start])
    if "/install.amd/gtk/initrd.gz" in entry:
        entry, count = re.subn(
            r"(?m)^(\s*linux\s+)/install\.amd/vmlinuz(?=\s|$)",
            r"\g<1>/install.amd/vmlinuz-debian",
            entry,
        )
        if count != 1:
            raise SystemExit("ERROR: each stock GTK GRUB entry must have exactly one Debian kernel line")
        gtk_rewrites += 1
    rewritten.extend(entry.splitlines(keepends=True))
    cursor = end
rewritten.extend(lines[cursor:])
src = "".join(rewritten)
if not gtk_rewrites:
    raise SystemExit("ERROR: Debian GRUB config has no stock GTK entries")
open(path, "w", encoding="utf-8").write(src)
lines, parsed_entries = menuentries(src)
entries = [(entry, top_level) for _start, _end, entry, top_level in parsed_entries]
marker_count = src.count("--hotkey=t")
preseed_count = src.count("preseed/file")
combined_count = src.count("initrd-t2auto")
if (marker_count, preseed_count, combined_count) != (1, 1, 1):
    raise SystemExit("ERROR: GRUB must contain exactly one T2 hotkey, preseed path, and combined initrd")

t2_entries = [(entry, top_level) for entry, top_level in entries if "preseed/file" in entry or "initrd-t2auto" in entry]
expected_title = "Automated install (T2 Proxmox) - uses largest free space"
if len(t2_entries) != 1 or not t2_entries[0][1] or not re.search(r"(?m)^\s*menuentry\s+--hotkey=t\s+'" + re.escape(expected_title) + r"'\s*\{", t2_entries[0][0]):
    raise SystemExit("ERROR: only the named top-level T2 automated GRUB menuentry may use the preseed/combined initrd")
if "auto=true priority=critical preseed/file=/preseed.cfg --- quiet" not in t2_entries[0][0] or "/install.amd/initrd-t2auto" not in t2_entries[0][0]:
    raise SystemExit("ERROR: T2 automated GRUB entry has incorrect boot arguments or initrd")

install_entries = [entry for entry, _top_level in entries if re.search(r"(?m)^\s*menuentry\s+--hotkey=i\s+'Install'", entry)]
if (len(install_entries) != 1 or not re.search(r"(?m)^\s*linux\s+/install\.amd/vmlinuz(?:\s|$)", install_entries[0]) or
        "/install.amd/vmlinuz-debian" in install_entries[0] or
        "/install.amd/initrd.gz" not in install_entries[0] or
        "preseed/file" in install_entries[0] or "initrd-t2auto" in install_entries[0]):
    raise SystemExit("ERROR: stock Install GRUB entry must keep the T2 kernel and main initrd")
gtk_entries = [entry for entry, _top_level in entries if "/install.amd/gtk/initrd.gz" in entry]
if not gtk_entries or any(
        re.findall(r"(?m)^\s*linux\s+(\S+)", entry) != ["/install.amd/vmlinuz-debian"]
        for entry in gtk_entries):
    raise SystemExit("ERROR: stock GRUB GTK entries must use the preserved Debian kernel")
if any("/install.amd/vmlinuz " not in entry for entry, _top_level in t2_entries):
    raise SystemExit("ERROR: T2 automated GRUB entry must keep the T2 kernel")
if not re.search(r'(?m)^set default="Install"$', src) or not re.search(r"(?m)^set timeout=30$", src):
    raise SystemExit('ERROR: GRUB default must be Install with timeout=30')
print(f"grub.cfg: {gtk_rewrites} GTK entries use Debian kernel; T2 Install/default/auto verified")
PYEOF

# BIOS (isolinux) fallback; deliberately leave its existing default unchanged.
if [[ ! -f "$TREE/isolinux/txt.cfg" ]]; then
  echo "ERROR: source ISO is missing /isolinux/txt.cfg" >&2
  exit 1
fi
cat >> "$TREE/isolinux/txt.cfg" <<'EOF'

label t2auto
 menu label ^Automated install (T2 Proxmox) - uses largest free space
 kernel /install.amd/vmlinuz
 append auto=true priority=critical preseed/file=/preseed.cfg initrd=/install.amd/initrd-t2auto --- quiet
EOF

# Verify isolinux also gates the preseed and combined initrd to the t2auto label only.
python3 - "$TREE/isolinux" <<'PYEOF'
import re
import sys
from pathlib import Path

all_text = []
label_bodies = []
gtk_count = 0
for path in sorted(Path(sys.argv[1]).rglob("*.cfg")):
    src = re.sub(r"\bvga=788\b[ \t]*", "", path.read_text(encoding="utf-8"))
    lines = src.splitlines(keepends=True)
    starts = [index for index, line in enumerate(lines) if re.match(r"\s*label\s+\S+", line)]
    updated = []
    cursor = 0
    for position, start in enumerate(starts):
        end = starts[position + 1] if position + 1 < len(starts) else len(lines)
        updated.extend(lines[cursor:start])
        block = lines[start:end]
        if "/install.amd/gtk/initrd.gz" in "".join(block):
            gtk_count += 1
            changed = 0
            for index, line in enumerate(block):
                line, count = re.subn(
                    r"(?m)^(\s*kernel\s+)/install\.amd/vmlinuz(?=\s|$)",
                    r"\g<1>/install.amd/vmlinuz-debian",
                    line,
                )
                changed += count
                if "/install.amd/gtk/initrd.gz" in line:
                    line, count = re.subn(
                        r"(?m)^(\s*ontimeout\s+)/install\.amd/vmlinuz(?=\s|$)",
                        r"\g<1>/install.amd/vmlinuz-debian",
                        line,
                    )
                    changed += count
                block[index] = line
            if not changed:
                raise SystemExit(f"ERROR: {path}: GTK label has no kernel or ontimeout directive")
        updated.extend(block)
        cursor = end
    updated.extend(lines[cursor:])
    src = "".join(updated)
    path.write_text(src, encoding="utf-8")
    all_text.append(src)
    current = None
    body = []
    for line in src.splitlines():
        match = re.match(r"^label\s+(\S+)", line)
        if match:
            if current is not None:
                label_bodies.append((current, "\n".join(body)))
            current = match.group(1)
            body = []
        elif current is not None:
            body.append(line)
    if current is not None:
        label_bodies.append((current, "\n".join(body)))
combined = "\n".join(all_text)
t2auto_entries = [body for name, body in label_bodies if name == "t2auto"]
if len(t2auto_entries) != 1:
    raise SystemExit("ERROR: isolinux t2auto label is missing")
if combined.count("preseed/file") != 1 or combined.count("initrd-t2auto") != 1:
    raise SystemExit("ERROR: isolinux must contain exactly one preseed path and combined initrd")
if ("preseed/file=/preseed.cfg" not in t2auto_entries[0] or
        "initrd=/install.amd/initrd-t2auto" not in t2auto_entries[0] or
        not re.search(r"(?m)^\s*kernel\s+/install\.amd/vmlinuz\s*$", t2auto_entries[0])):
    raise SystemExit("ERROR: isolinux t2auto label must keep the T2 kernel and combined initrd")
if any("preseed/file" in body or "initrd-t2auto" in body for name, body in label_bodies if name != "t2auto"):
    raise SystemExit("ERROR: stock isolinux labels must not use preseed or combined initrd")
install_labels = [body for name, body in label_bodies if name == "install"]
if (len(install_labels) != 1 or not re.search(r"(?m)^\s*kernel\s+/install\.amd/vmlinuz\s*$", install_labels[0]) or
        "initrd=/install.amd/initrd.gz" not in install_labels[0]):
    raise SystemExit("ERROR: BIOS text Install must keep the T2 kernel and main initrd")
gtk_labels = [body for _name, body in label_bodies if "/install.amd/gtk/initrd.gz" in body]
if not gtk_labels or any(
        not re.findall(r"(?m)^\s*kernel\s+(\S+)", body) or
        any(kernel != "/install.amd/vmlinuz-debian" for kernel in re.findall(r"(?m)^\s*kernel\s+(\S+)", body)) or
        any(kernel != "/install.amd/vmlinuz-debian" for kernel in re.findall(r"(?m)^\s*ontimeout\s+(\S+)", body))
        for body in gtk_labels):
    raise SystemExit("ERROR: stock isolinux GTK labels must use the preserved Debian kernel")
if "/install.amd/vmlinuz" not in t2auto_entries[0]:
    raise SystemExit("ERROR: isolinux T2 automated entry must keep the T2 kernel")
print(f"isolinux: {gtk_count} GTK labels use Debian kernel; T2 text/default/auto verified")
PYEOF

# --- 5. /t2 post-install payload ---
mkdir -p "$TREE/t2/debs" "$TREE/t2/scripts" "$TREE/t2/systemd"
for deb in "${KERNEL_DEBS[@]}"; do
  cp -- "$deb" "$TREE/t2/debs/"
done
cp -- "$ROOT/scripts/first-boot-proxmox.sh" "$TREE/t2/scripts/first-boot-proxmox.sh"
chmod 0755 "$TREE/t2/scripts/first-boot-proxmox.sh"
cp -- "$ROOT/scripts/partman-t2-guard.sh" "$TREE/t2/scripts/partman-t2-guard.sh"
chmod 0755 "$TREE/t2/scripts/partman-t2-guard.sh"
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
