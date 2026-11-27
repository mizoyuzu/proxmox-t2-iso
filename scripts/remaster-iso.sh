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

prepare_kernel_modules_path() {
  local kernel_extract=$1 kver=$2
  local usr_modules_dir="$kernel_extract/usr/lib/modules/$kver"
  local compat_modules_path="$kernel_extract/lib/modules"

  if [[ -d "$usr_modules_dir" && ! -e "$compat_modules_path" && ! -L "$compat_modules_path" ]]; then
    mkdir -p "$kernel_extract/lib"
    ln -s ../usr/lib/modules "$compat_modules_path"
  fi
}

if [[ ! -f "$ROOT/preseed.cfg" ]]; then
  echo "ERROR: preseed file is missing: $ROOT/preseed.cfg" >&2
  exit 1
fi
if [[ ! -f "$ROOT/preseed-manual.cfg" ]]; then
  echo "ERROR: manual preseed file is missing: $ROOT/preseed-manual.cfg" >&2
  exit 1
fi
for required_file in \
  scripts/select-kernel-deb.sh \
  scripts/installer-modules.txt \
  scripts/stage-installer-modules.sh \
  scripts/t2-target-setup.sh; do
  if [[ ! -f "$ROOT/$required_file" ]]; then
    echo "ERROR: required installer helper is missing: $ROOT/$required_file" >&2
    exit 1
  fi
done
if [[ ! -f "$ROOT/scripts/first-boot-proxmox.sh" ]]; then
  echo "ERROR: first-boot script is missing: $ROOT/scripts/first-boot-proxmox.sh" >&2
  exit 1
fi
if [[ ! -f "$ROOT/scripts/disable-pve-enterprise-source.sh" ]]; then
  echo "ERROR: PVE enterprise source helper is missing: $ROOT/scripts/disable-pve-enterprise-source.sh" >&2
  exit 1
fi
if [[ ! -f "$ROOT/scripts/first-boot-proxmox.service" ]]; then
  echo "ERROR: first-boot systemd unit is missing: $ROOT/scripts/first-boot-proxmox.service" >&2
  exit 1
fi
for required_file in \
  scripts/configure-pve-network.sh \
  scripts/sync-pve-mbp-hosts.sh \
  scripts/verify-pve-management-ready.sh \
  scripts/pve-management-ready.service \
  scripts/pve-cluster-hosts-sync.conf; do
  if [[ ! -f "$ROOT/$required_file" ]]; then
    echo "ERROR: management network payload is missing: $ROOT/$required_file" >&2
    exit 1
  fi
done
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

KERNEL_DEB="$("$ROOT/scripts/select-kernel-deb.sh" "$KERNEL_DEB_DIR")"
KERNEL_DEB_PACKAGE="$(dpkg-deb -f "$KERNEL_DEB" Package)"
echo "installer kernel package: $KERNEL_DEB_PACKAGE ($(basename "$KERNEL_DEB"))"

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

# --- 2. 選択したカーネル image .deb から vmlinuz / モジュールを取り出す ---
KEX="$WORK/kernel-extract"
mkdir -p "$KEX"
dpkg-deb -x "$KERNEL_DEB" "$KEX"
mapfile -t KERNEL_IMAGES < <(find "$KEX/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -print | sort)
if (( ${#KERNEL_IMAGES[@]} != 1 )); then
  echo "ERROR: expected exactly one boot/vmlinuz-* in selected kernel image deb, found ${#KERNEL_IMAGES[@]}" >&2
  exit 1
fi
KVMLINUZ="${KERNEL_IMAGES[0]}"
KVER_FULL="$(basename "$KVMLINUZ" | sed 's/^vmlinuz-//')"
EXPECTED_PVE_KVER="${T2_EXPECTED_PVE_KVER:-7.0.14-30-pve-t2}"
prepare_kernel_modules_path "$KEX" "$KVER_FULL"
MODULES_DIR="$KEX/lib/modules/$KVER_FULL"
if [[ ! -d "$MODULES_DIR" ]]; then
  echo "ERROR: kernel modules are missing from selected image deb; checked legacy layout $KEX/lib/modules/$KVER_FULL and usrmerge layout $KEX/usr/lib/modules/$KVER_FULL" >&2
  exit 1
fi
if [[ "$KERNEL_DEB_PACKAGE" == proxmox-kernel-* ]]; then
  [[ "$KERNEL_DEB_PACKAGE" == proxmox-kernel-*-pve-t2 && "$KVER_FULL" == "$EXPECTED_PVE_KVER" ]] || {
    echo "ERROR: selected PVE image kernel must be $EXPECTED_PVE_KVER, found $KERNEL_DEB_PACKAGE / $KVER_FULL" >&2
    exit 1
  }
fi
echo "installer kernel: $KVER_FULL"
# Keep the stock Debian kernel for the untouched GTK initrd, which contains
# Debian ABI modules. GTK entries are redirected before the T2 kernel replaces
# /install.amd/vmlinuz; text, T2-auto, and T2-manual entries use the T2 kernel.
if [[ ! -f "$TREE/install.amd/vmlinuz" ]]; then
  echo "ERROR: source ISO is missing /install.amd/vmlinuz" >&2
  exit 1
fi
cp -- "$TREE/install.amd/vmlinuz" "$TREE/install.amd/vmlinuz-debian"
cp -- "$KVMLINUZ" "$TREE/install.amd/vmlinuz"

# --- 3. initrd を必要な module のみで再構築 ---
# fakeroot supplies the root/device-node metadata cpio needs without requiring
# privileges from the Actions runner. Extraction and repacking share one
# fakeroot metadata session so cpio's fake device nodes retain their types.
fakeroot -- bash -c '
set -euo pipefail
initrd_dir="$1"
initrd_gz="$2"
kver="$4"
kernel_extract="$5"
stage_script="$6"

cd "$initrd_dir"
gzip -dc "$initrd_gz" | cpio -idm --quiet
rm -f -- preseed.cfg preseed-manual.cfg
"$stage_script" "$kernel_extract" "$kver" "$initrd_dir"

# brcm firmware is post-install payload only, never part of the installer initrd.
rm -rf -- lib/firmware/brcm

find . -print0 | cpio --null -o -H newc --quiet | gzip -9 > "$initrd_gz"
' bash "$INITRD_DIR" "$TREE/install.amd/initrd.gz" "$MODULES_DIR" "$KVER_FULL" "$KEX" "$ROOT/scripts/stage-installer-modules.sh"

INITRD_MAX_BYTES="${T2_INITRD_MAX_BYTES:-209715200}"
[[ "$INITRD_MAX_BYTES" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid T2_INITRD_MAX_BYTES: $INITRD_MAX_BYTES" >&2; exit 1; }
INITRD_SIZE="$(stat -c '%s' "$TREE/install.amd/initrd.gz")"
if (( INITRD_SIZE > INITRD_MAX_BYTES )); then
  echo "ERROR: rebuilt installer initrd is ${INITRD_SIZE} bytes, over the ${INITRD_MAX_BYTES}-byte cap" >&2
  exit 1
fi
gzip -t "$TREE/install.amd/initrd.gz"
echo "installer initrd size: $INITRD_SIZE bytes (limit $INITRD_MAX_BYTES)"

# Re-extract the packed archive and check device-node types while the same
# fakeroot metadata session is alive. A separate fakeroot invocation would
# not retain the fake device metadata created by cpio.
rm -rf -- "$INITRD_VERIFY_DIR"
mkdir -p "$INITRD_VERIFY_DIR"
if ! fakeroot -- bash -c 'set -euo pipefail; cd "$1"; gzip -dc "$2" | cpio -idm --quiet; test -c "$1/dev/console"; test -c "$1/dev/null"; test ! -e preseed.cfg; test ! -e preseed-manual.cfg' \
  bash "$INITRD_VERIFY_DIR" "$TREE/install.amd/initrd.gz"; then
  rm -rf -- "$INITRD_VERIFY_DIR"
  echo "ERROR: rebuilt initrd failed validation: device nodes must be character devices and both preseed files must be absent" >&2
  exit 1
fi
rm -rf -- "$INITRD_VERIFY_DIR"

# --- 3a. Both preseed files share one small cpio and one T2 initrd ---
PRESEED_STAGE="$(mktemp -d "$WORK/preseed-stage.XXXXXX")"
PRESEED_VERIFY_DIR="$(mktemp -d "$WORK/preseed-verify.XXXXXX")"
cp -- "$ROOT/preseed.cfg" "$PRESEED_STAGE/preseed.cfg"
cp -- "$ROOT/preseed-manual.cfg" "$PRESEED_STAGE/preseed-manual.cfg"
(cd "$PRESEED_STAGE" && printf '%s\n' preseed.cfg preseed-manual.cfg | cpio -o -H newc --owner=0:0 --quiet) > "$TREE/install.amd/preseed-initrd.cpio"
chmod 0644 "$TREE/install.amd/preseed-initrd.cpio"

PRESEED_MEMBERS="$(cpio -it < "$TREE/install.amd/preseed-initrd.cpio")"
if [[ "$PRESEED_MEMBERS" != $'preseed.cfg\npreseed-manual.cfg' && "$PRESEED_MEMBERS" != $'./preseed.cfg\n./preseed-manual.cfg' ]]; then
  echo "ERROR: preseed initrd must contain exactly preseed.cfg and preseed-manual.cfg, found: $PRESEED_MEMBERS" >&2
  exit 1
fi
(cd "$PRESEED_VERIFY_DIR" && cpio -idm --quiet < "$TREE/install.amd/preseed-initrd.cpio")
for preseed in preseed.cfg preseed-manual.cfg; do
  if ! cmp -s -- "$ROOT/$preseed" "$PRESEED_VERIFY_DIR/$preseed"; then
    echo "ERROR: preseed initrd contents differ from $ROOT/$preseed" >&2
    exit 1
  fi
done
if ! grep -q 'localechooser/languagelist select ja' "$PRESEED_VERIFY_DIR/preseed.cfg" ||
   ! grep -q 'debian-installer/language string ja' "$PRESEED_VERIFY_DIR/preseed.cfg" ||
   ! grep -q 'localechooser/languagelist select ja' "$PRESEED_VERIFY_DIR/preseed-manual.cfg" ||
   ! grep -q 'debian-installer/language string ja' "$PRESEED_VERIFY_DIR/preseed-manual.cfg"; then
  echo "ERROR: both preseeds must select Japanese in localechooser and debian-installer/language" >&2
  exit 1
fi
if grep -Eq '^d-i passwd/(root-password|root-password-again|user-password|user-password-again)[[:space:]]' \
  "$PRESEED_VERIFY_DIR/preseed.cfg" "$PRESEED_VERIFY_DIR/preseed-manual.cfg"; then
  echo "ERROR: root/user passwords must remain interactive and must not be embedded in preseed" >&2
  exit 1
fi
if ! grep -Fq '2048 2048 2048 ext4' "$PRESEED_VERIFY_DIR/preseed.cfg" ||
   ! grep -q '^d-i partman/early_command string' "$PRESEED_VERIFY_DIR/preseed.cfg"; then
  echo "ERROR: automatic preseed must use a fixed 2 GiB /boot and install the partman safety guard" >&2
  exit 1
fi
if grep -Eq '^d-i partman-auto/|^d-i partman/choose_partition select finish|^d-i partman/early_command' "$PRESEED_VERIFY_DIR/preseed-manual.cfg"; then
  echo "ERROR: manual preseed must not set partman-auto, finish partitioning, or install the auto guard" >&2
  exit 1
fi

cat -- "$TREE/install.amd/preseed-initrd.cpio" "$TREE/install.amd/initrd.gz" > "$TREE/install.amd/initrd-t2"
chmod 0644 "$TREE/install.amd/initrd-t2"
PRESEED_INITRD_SIZE="$(stat -c '%s' "$TREE/install.amd/preseed-initrd.cpio")"
T2_INITRD_SIZE="$(stat -c '%s' "$TREE/install.amd/initrd-t2")"
if [[ "$(head -c 6 "$TREE/install.amd/preseed-initrd.cpio")" != "070701" ]] ||
   [[ "$(head -c 6 "$TREE/install.amd/initrd-t2")" != "070701" ]] ||
   ! cmp -n "$PRESEED_INITRD_SIZE" -- "$TREE/install.amd/preseed-initrd.cpio" "$TREE/install.amd/initrd-t2" ||
   ! tail -c "+$((PRESEED_INITRD_SIZE + 1))" "$TREE/install.amd/initrd-t2" | cmp - "$TREE/install.amd/initrd.gz" ||
   (( T2_INITRD_SIZE != PRESEED_INITRD_SIZE + $(stat -c '%s' "$TREE/install.amd/initrd.gz") )); then
  echo "ERROR: combined T2 initrd is not the two-preseed cpio followed by the main initrd" >&2
  exit 1
fi
if (( T2_INITRD_SIZE > INITRD_MAX_BYTES + PRESEED_INITRD_SIZE )); then
  echo "ERROR: combined T2 initrd exceeds the configured size cap" >&2
  exit 1
fi
rm -rf -- "$PRESEED_STAGE" "$PRESEED_VERIFY_DIR"

# --- 4. GRUB / isolinux: preserve normal install as the safe default ---
# Debian 13.8.0 amd64's top-level entries start with Graphical install, Install.
# Put the final global settings after the source config so no later source line
# can override them, then append the explicitly-selected T2 entries.
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
    initrd   /install.amd/initrd-t2
}
menuentry --hotkey=m 'Manual partition install (T2 Proxmox)' {
    set background_color=black
    linux    /install.amd/vmlinuz auto=true priority=medium preseed/file=/preseed-manual.cfg --- quiet
    initrd   /install.amd/initrd-t2
}
"""
with open(path, "w", encoding="utf-8") as config:
    config.write(src.rstrip() + "\n" + entry.lstrip())
print("grub.cfg: default=Install, timeout=30, T2 auto/manual entries appended")
PYEOF

# Verify each preseed appears only in its explicit T2 menu entry and normal Install remains safe.
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
if (src.count("--hotkey=t"), src.count("--hotkey=m"), src.count("preseed/file"),
        src.count("/preseed.cfg"), src.count("/preseed-manual.cfg"), src.count("/install.amd/initrd-t2")) != (1, 1, 2, 1, 1, 2):
    raise SystemExit("ERROR: GRUB must contain one auto/manual hotkey, one path per preseed, and two references to the shared initrd")

t2_entries = [(entry, top_level) for entry, top_level in entries if "preseed/file" in entry or "/install.amd/initrd-t2" in entry]
auto_title = "Automated install (T2 Proxmox) - uses largest free space"
manual_title = "Manual partition install (T2 Proxmox)"
if len(t2_entries) != 2 or any(not top_level for _entry, top_level in t2_entries):
    raise SystemExit("ERROR: GRUB must contain exactly two top-level T2 preseed entries")
auto_entries = [entry for entry, _top_level in t2_entries if "preseed/file=/preseed.cfg" in entry]
manual_entries = [entry for entry, _top_level in t2_entries if "preseed/file=/preseed-manual.cfg" in entry]
if len(auto_entries) != 1 or len(manual_entries) != 1:
    raise SystemExit("ERROR: GRUB must contain exactly one auto and one manual preseed entry")
if (not re.search(r"(?m)^\s*menuentry\s+--hotkey=t\s+'" + re.escape(auto_title) + r"'\s*\{", auto_entries[0]) or
        "auto=true priority=critical preseed/file=/preseed.cfg --- quiet" not in auto_entries[0] or
        "/install.amd/initrd-t2" not in auto_entries[0]):
    raise SystemExit("ERROR: T2 automatic GRUB entry has incorrect title, boot arguments, or initrd")
if (not re.search(r"(?m)^\s*menuentry\s+--hotkey=m\s+'" + re.escape(manual_title) + r"'\s*\{", manual_entries[0]) or
        "auto=true priority=medium preseed/file=/preseed-manual.cfg --- quiet" not in manual_entries[0] or
        "/install.amd/initrd-t2" not in manual_entries[0]):
    raise SystemExit("ERROR: T2 manual GRUB entry has incorrect title, boot arguments, or shared initrd")

install_entries = [entry for entry, _top_level in entries if re.search(r"(?m)^\s*menuentry\s+--hotkey=i\s+'Install'", entry)]
if (len(install_entries) != 1 or not re.search(r"(?m)^\s*linux\s+/install\.amd/vmlinuz(?:\s|$)", install_entries[0]) or
        "/install.amd/vmlinuz-debian" in install_entries[0] or
        "/install.amd/initrd.gz" not in install_entries[0] or
        "preseed/file" in install_entries[0] or "initrd-t2" in install_entries[0]):
    raise SystemExit("ERROR: stock Install GRUB entry must keep the T2 kernel and main initrd")
gtk_entries = [entry for entry, _top_level in entries if "/install.amd/gtk/initrd.gz" in entry]
if not gtk_entries or any(
        re.findall(r"(?m)^\s*linux\s+(\S+)", entry) != ["/install.amd/vmlinuz-debian"]
        for entry in gtk_entries):
    raise SystemExit("ERROR: stock GRUB GTK entries must use the preserved Debian kernel")
if any("/install.amd/vmlinuz " not in entry for entry, _top_level in t2_entries):
    raise SystemExit("ERROR: T2 preseed entries must keep the T2 kernel")
if not re.search(r'(?m)^set default="Install"$', src) or not re.search(r"(?m)^set timeout=30$", src):
    raise SystemExit('ERROR: GRUB default must be Install with timeout=30')
print(f"grub.cfg: {gtk_rewrites} GTK entries use Debian kernel; stock Install/default and T2 auto/manual verified")
PYEOF

# BIOS (isolinux) fallback; deliberately leave its existing default unchanged.
if [[ ! -f "$TREE/isolinux/txt.cfg" ]]; then
  echo "ERROR: source ISO is missing /isolinux/txt.cfg" >&2
  exit 1
fi
cat >> "$TREE/isolinux/txt.cfg" <<'EOF'

label t2auto
 menu label ^T2 automated install (largest free space)
 kernel /install.amd/vmlinuz
 append auto=true priority=critical preseed/file=/preseed.cfg initrd=/install.amd/initrd-t2 --- quiet

label t2manual
 menu label ^Manual partition install (T2 Proxmox)
 kernel /install.amd/vmlinuz
 append auto=true priority=medium preseed/file=/preseed-manual.cfg initrd=/install.amd/initrd-t2 --- quiet
EOF

# Verify isolinux gates the shared initrd and each preseed to its matching T2 label.
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
t2manual_entries = [body for name, body in label_bodies if name == "t2manual"]
if len(t2auto_entries) != 1 or len(t2manual_entries) != 1:
    raise SystemExit("ERROR: isolinux t2auto and t2manual labels must each exist exactly once")
if (combined.count("preseed/file") != 2 or combined.count("/preseed.cfg") != 1 or
        combined.count("/preseed-manual.cfg") != 1 or combined.count("/install.amd/initrd-t2") != 2):
    raise SystemExit("ERROR: isolinux must have one path per preseed and two references to the shared initrd")
if ("preseed/file=/preseed.cfg" not in t2auto_entries[0] or
        "initrd=/install.amd/initrd-t2" not in t2auto_entries[0] or
        not re.search(r"(?m)^\s*kernel\s+/install\.amd/vmlinuz\s*$", t2auto_entries[0])):
    raise SystemExit("ERROR: isolinux t2auto label must keep its preseed and the shared T2 initrd")
if ("preseed/file=/preseed-manual.cfg" not in t2manual_entries[0] or
        "initrd=/install.amd/initrd-t2" not in t2manual_entries[0] or
        not re.search(r"(?m)^\s*kernel\s+/install\.amd/vmlinuz\s*$", t2manual_entries[0])):
    raise SystemExit("ERROR: isolinux t2manual label must keep its preseed and the shared T2 initrd")
if any("preseed/file" in body or "initrd-t2" in body for name, body in label_bodies if name not in ("t2auto", "t2manual")):
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
if "/install.amd/vmlinuz" not in t2auto_entries[0] or "/install.amd/vmlinuz" not in t2manual_entries[0]:
    raise SystemExit("ERROR: isolinux T2 entries must keep the T2 kernel")
print(f"isolinux: {gtk_count} GTK labels use Debian kernel; stock Install and T2 auto/manual verified")
PYEOF

# --- 5. /t2 post-install payload ---
mkdir -p "$TREE/t2/debs" "$TREE/t2/scripts" "$TREE/t2/systemd"
cp -- "$KERNEL_DEB" "$TREE/t2/debs/"
cp -- "$ROOT/scripts/first-boot-proxmox.sh" "$TREE/t2/scripts/first-boot-proxmox.sh"
chmod 0755 "$TREE/t2/scripts/first-boot-proxmox.sh"
cp -- "$ROOT/scripts/t2-target-setup.sh" "$TREE/t2/scripts/t2-target-setup.sh"
chmod 0755 "$TREE/t2/scripts/t2-target-setup.sh"
cp -- "$ROOT/scripts/disable-pve-enterprise-source.sh" "$TREE/t2/scripts/disable-pve-enterprise-source.sh"
chmod 0755 "$TREE/t2/scripts/disable-pve-enterprise-source.sh"
for helper in configure-pve-network.sh sync-pve-mbp-hosts.sh verify-pve-management-ready.sh; do
  cp -- "$ROOT/scripts/$helper" "$TREE/t2/scripts/$helper"
  chmod 0755 "$TREE/t2/scripts/$helper"
done
cp -- "$ROOT/scripts/partman-t2-guard.sh" "$TREE/t2/scripts/partman-t2-guard.sh"
chmod 0755 "$TREE/t2/scripts/partman-t2-guard.sh"
cp -- "$ROOT/scripts/t2-hardware-preflight.sh" "$TREE/t2/scripts/t2-hardware-preflight.sh"
chmod 0755 "$TREE/t2/scripts/t2-hardware-preflight.sh"
cp -- "$ROOT/scripts/first-boot-proxmox.service" "$TREE/t2/systemd/first-boot-proxmox.service"
cp -- "$ROOT/scripts/pve-management-ready.service" "$TREE/t2/systemd/pve-management-ready.service"
cp -- "$ROOT/scripts/pve-cluster-hosts-sync.conf" "$TREE/t2/systemd/pve-cluster-hosts-sync.conf"

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
