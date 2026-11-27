#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"

cat > "$BIN/dpkg-query" <<'EOF'
#!/bin/sh
if [ "$1" != -W ]; then
  echo "unexpected dpkg-query invocation: $*" >&2
  exit 99
fi
for package in ${T2_TEST_PACKAGES-proxmox-kernel-7.0.14-30-pve-t2}; do
  printf '%s\tinstalled\n' "$package"
done
EOF
cat > "$BIN/apt-mark" <<'EOF'
#!/bin/sh
if [ "$1" != showhold ]; then
  echo "unexpected apt-mark invocation: $*" >&2
  exit 99
fi
if [ -r "$T2_TEST_HOLDS" ]; then
  cat "$T2_TEST_HOLDS"
fi
EOF
cat > "$BIN/uname" <<'EOF'
#!/bin/sh
[ "$1" = -r ] || exit 99
printf '%s\n' "${T2_TEST_UNAME:-7.0.14-30-pve-t2}"
EOF
chmod 0755 "$BIN"/*

make_case() {
  local name=$1 case_root=$WORK/$1
  mkdir -p "$case_root"
  printf 'GRUB_DEFAULT=gnulinux-advanced-fixture-root\\>gnulinux-7.0.14-30-pve-t2-advanced-fixture-root\n' \
    > "$case_root/grub-default"
  cat > "$case_root/grub.cfg" <<'EOF'
submenu 'Advanced options for Proxmox VE GNU/Linux' $menuentry_id_option 'gnulinux-advanced-fixture-root' {
  menuentry 'Proxmox VE GNU/Linux, with Linux 7.0.14-30-pve-t2' $menuentry_id_option 'gnulinux-7.0.14-30-pve-t2-advanced-fixture-root' {
    linux /vmlinuz-7.0.14-30-pve-t2 root=UUID=test ro quiet
  }
}
EOF
  : > "$case_root/holds"
}

run_state() {
  local case_root=$1
  shift
  env PATH="$BIN:$PATH" T2_GRUB_DEFAULT_FILE="$case_root/grub-default" \
    T2_GRUB_CFG="$case_root/grub.cfg" T2_TEST_HOLDS="$case_root/holds" "$@" \
    "$ROOT/scripts/t2-kernel-state.sh"
}

# All required lifecycle checks pass for the single installed, held package.
make_case normal
printf '%s\n' 'proxmox-kernel-7.0.14-30-pve-t2' > "$WORK/normal/holds"
run_state "$WORK/normal" > "$WORK/normal/output"
grep -Fq 'PASS: running kernel is T2: 7.0.14-30-pve-t2' "$WORK/normal/output"
grep -Fq 'PASS: exactly one T2 kernel package is installed: proxmox-kernel-7.0.14-30-pve-t2' "$WORK/normal/output"
grep -Fq 'PASS: T2 kernel package is held: proxmox-kernel-7.0.14-30-pve-t2' "$WORK/normal/output"
grep -Fq 'PASS: GRUB config contains the selected T2 submenu, entry, and kernel' "$WORK/normal/output"

# A missing apt hold is an audit failure.
make_case no-hold
if run_state "$WORK/no-hold" > "$WORK/no-hold/output"; then
  echo 'FAIL: kernel-state audit accepted an unheld T2 package.' >&2
  exit 1
fi
grep -Fq 'FAIL: T2 kernel package is not held' "$WORK/no-hold/output"

# Zero and multiple installed T2 packages are both rejected.
make_case zero-kernels
if run_state "$WORK/zero-kernels" T2_TEST_PACKAGES= > "$WORK/zero-kernels/output"; then
  echo 'FAIL: kernel-state audit accepted zero installed T2 packages.' >&2
  exit 1
fi
grep -Fq 'expected exactly one installed T2 kernel package, found 0' "$WORK/zero-kernels/output"

make_case two-kernels
printf '%s\n' 'proxmox-kernel-7.0.14-30-pve-t2' 'linux-image-6.18.56-t2-pve' > "$WORK/two-kernels/holds"
if run_state "$WORK/two-kernels" T2_TEST_PACKAGES='proxmox-kernel-7.0.14-30-pve-t2 linux-image-6.18.56-t2-pve' > "$WORK/two-kernels/output"; then
  echo 'FAIL: kernel-state audit accepted two installed T2 packages.' >&2
  exit 1
fi
grep -Fq 'expected exactly one installed T2 kernel package, found 2' "$WORK/two-kernels/output"

# A numeric/non-T2 GRUB default is not a version-specific T2 pin.
make_case non-t2-grub
printf 'GRUB_DEFAULT=0\n' > "$WORK/non-t2-grub/grub-default"
printf '%s\n' 'proxmox-kernel-7.0.14-30-pve-t2' > "$WORK/non-t2-grub/holds"
if run_state "$WORK/non-t2-grub" > "$WORK/non-t2-grub/output"; then
  echo 'FAIL: kernel-state audit accepted a non-T2 GRUB default.' >&2
  exit 1
fi
grep -Fq 'FAIL: GRUB_DEFAULT is not a version-specific submenu>entry ID path' "$WORK/non-t2-grub/output"

printf 'PASS: kernel-state audit verifies the running T2 kernel, unique held package, and version-specific GRUB entry; rejects missing/duplicate state.\n'
