#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

MOCK_BIN="$WORK/mock-bin"
MINIMAL_BIN="$WORK/minimal-bin"
FIXTURE="$WORK/iso-tree"
mkdir -p "$MOCK_BIN" "$MINIMAL_BIN" \
  "$FIXTURE/install.amd" "$FIXTURE/boot/grub" "$FIXTURE/t2/debs"
printf 'synthetic ISO fixture\n' > "$WORK/test.iso"
python3 - "$FIXTURE/install.amd/initrd.gz" <<'PY'
import gzip
import sys
with gzip.open(sys.argv[1], 'wb') as initrd:
    initrd.write(b'synthetic cpio fixture')
PY
printf 'fixture kernel\n' > "$FIXTURE/install.amd/vmlinuz"
printf 'package fixture\n' > "$FIXTURE/t2/debs/proxmox-kernel-7.0.14-30-pve-t2_7.0.14-30_amd64.deb"
cat > "$FIXTURE/boot/grub/grub.cfg" <<'GRUB'
set default="Install"
menuentry --hotkey=i 'Install' {
  linux /install.amd/vmlinuz --- quiet
  initrd /install.amd/initrd.gz
}
menuentry --hotkey=t 'Automated install (T2)' {
  linux /install.amd/vmlinuz auto=true preseed/file=/preseed.cfg --- quiet
  initrd /install.amd/initrd.gz
}
menuentry --hotkey=m 'Manual install (T2)' {
  linux /install.amd/vmlinuz auto=true preseed/file=/preseed-manual.cfg --- quiet
  initrd /install.amd/initrd.gz
}
GRUB
cat > "$WORK/cpio-members" <<'MEMBERS'
preseed.cfg
preseed-manual.cfg
lib/modules/7.0.14-30-pve-t2/modules.dep
lib/modules/7.0.14-30-pve-t2/kernel/drivers/platform/apple/t2bce/t2bce_core.ko
MEMBERS

cat > "$MOCK_BIN/xorriso" <<'XORRISO'
#!/usr/bin/env bash
set -Eeuo pipefail
dest=${@: -1}
mkdir -p "$dest"
cp -a "$FIXTURE_ISO_TREE/." "$dest/"
XORRISO
cat > "$MOCK_BIN/cpio" <<'CPIO'
#!/usr/bin/env bash
cat "$FIXTURE_CPIO_MEMBERS"
CPIO
cat > "$MOCK_BIN/strings" <<'STRINGS'
#!/usr/bin/env bash
printf '%s\n' 'Linux version 7.0.14-30-pve-t2 (fixture)'
STRINGS
chmod +x "$MOCK_BIN/xorriso" "$MOCK_BIN/cpio" "$MOCK_BIN/strings"
ln -s "$(command -v bash)" "$MINIMAL_BIN/bash"
ln -s "$(command -v stat)" "$MINIMAL_BIN/stat"

if ! PATH="$MOCK_BIN:$PATH" FIXTURE_ISO_TREE="$FIXTURE" \
  FIXTURE_CPIO_MEMBERS="$WORK/cpio-members" \
  "$ROOT/tests/inspect-iso.sh" --require-tools --max-initrd-mib 1 --max-iso-mib 1 \
  "$WORK/test.iso" > "$WORK/pass.log" 2>&1; then
  cat "$WORK/pass.log" >&2
  echo 'FAIL: synthetic ISO should pass inspection' >&2
  exit 1
fi
grep -q 'PASS: GRUB has one stock Install, one auto and one manual entry' "$WORK/pass.log"
grep -q 'PASS: initrd cpio contains t2bce_core.ko, modules.dep, and both preseed files.' "$WORK/pass.log"

sed -i "/menuentry --hotkey=m 'Manual install (T2)'/,/^}/d" "$FIXTURE/boot/grub/grub.cfg"
if PATH="$MOCK_BIN:$PATH" FIXTURE_ISO_TREE="$FIXTURE" \
  FIXTURE_CPIO_MEMBERS="$WORK/cpio-members" \
  "$ROOT/tests/inspect-iso.sh" "$WORK/test.iso" > "$WORK/fail.log" 2>&1; then
  cat "$WORK/fail.log" >&2
  echo 'FAIL: inspector accepted an ISO fixture without its manual GRUB entry' >&2
  exit 1
fi
grep -q 'expected one top-level T2 manual entry, found 0' "$WORK/fail.log"

skip_output=$(PATH="$MINIMAL_BIN" "$ROOT/tests/inspect-iso.sh" "$WORK/test.iso" 2>&1)
grep -q '^SKIP: ISO inspection needs: xorriso cpio' <<< "$skip_output"
if PATH="$MINIMAL_BIN" "$ROOT/tests/inspect-iso.sh" --require-tools "$WORK/test.iso" > "$WORK/strict.log" 2>&1; then
  echo 'FAIL: --require-tools accepted a missing xorriso/cpio environment' >&2
  exit 1
fi
grep -q 'xorriso cpio (--require-tools is set)' "$WORK/strict.log"

echo 'PASS: ISO inspector checks expected content, rejects a missing GRUB mode, and supports optional/strict tool requirements.'
