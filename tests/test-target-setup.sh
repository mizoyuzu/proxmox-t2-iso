#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"

cat > "$BIN/mountpoint" <<'EOF'
#!/bin/sh
mount_path=$2
[ "${T2_TEST_MISSING_MOUNT:-}" != "$mount_path" ] || exit 1
case "$mount_path" in
  "$T2_TARGET_ROOT"|"$T2_TARGET_ROOT/boot"|"$T2_TARGET_ROOT/boot/efi") exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat > "$BIN/wipefs" <<'EOF'
#!/bin/sh
printf '%s\n' "${T2_TEST_WIPED_SIGS:-}"
EOF
cat > "$BIN/vgs" <<'EOF'
#!/bin/sh
case " $* " in
  *" vg_free_count "*) printf '%s\n' "${T2_TEST_FREE_EXTENTS:-32}" ;;
  *" vg_name "*) if [ "${T2_TEST_VG_PRESENT:-0}" = 1 ]; then printf 'pve\n'; fi ;;
  *) exit 2 ;;
esac
exit 0
EOF
cat > "$BIN/lvs" <<'EOF'
#!/bin/sh
[ "${T2_TEST_LV_PRESENT:-0}" = 1 ] && printf 'data\n'
exit 0
EOF
cat > "$BIN/pvs" <<'EOF'
#!/bin/sh
printf '%s\n' "${T2_TEST_UNASSIGNED_PVS:-}"
EOF
cat > "$BIN/pvcreate" <<'EOF'
#!/bin/sh
printf 'pvcreate %s\n' "$*" >> "$T2_TEST_COMMAND_LOG"
EOF
cat > "$BIN/vgcreate" <<'EOF'
#!/bin/sh
printf 'vgcreate %s\n' "$*" >> "$T2_TEST_COMMAND_LOG"
EOF
cat > "$BIN/in-target" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'in-target %s\n' "$*" >> "$T2_TEST_COMMAND_LOG"
if [[ ${1:-} == sh && ${2:-} == -c ]]; then
  mkdir -p "$T2_TARGET_ROOT/boot"
  for version in ${T2_TEST_INSTALLED_KERNELS:-7.0.14-30-pve-t2}; do
    touch "$T2_TARGET_ROOT/boot/vmlinuz-$version" "$T2_TARGET_ROOT/boot/initrd.img-$version"
  done
fi
EOF
chmod 0755 "$BIN"/*

make_case() {
  local name=$1 case_root=$WORK/$1
  mkdir -p "$case_root/target/boot/efi" "$case_root/target/etc/default" \
    "$case_root/target/etc/initramfs-tools" "$case_root/cdrom/t2/debs" \
    "$case_root/cdrom/t2/scripts" "$case_root/cdrom/t2/systemd" \
    "$case_root/udev" "$case_root/sys/class/block/nvme0n1"
  printf 'UUID=root / ext4 defaults 0 1\nUUID=boot /boot ext4 defaults 0 2\nUUID=efi /boot/efi vfat defaults 0 2\nUUID=swap none swap sw 0 0\n' > "$case_root/target/etc/fstab"
  printf 'GRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' > "$case_root/target/etc/default/grub"
  printf 't2bce_core\n' > "$case_root/target/etc/initramfs-tools/modules"
  touch "$case_root/cdrom/t2/debs/proxmox-kernel-7.0.14-30-pve-t2_7.0.14-30_amd64.deb"
  for script in first-boot-proxmox.sh configure-pve-network.sh sync-pve-mbp-hosts.sh \
    verify-pve-management-ready.sh disable-pve-enterprise-source.sh; do
    cp "$ROOT/scripts/$script" "$case_root/cdrom/t2/scripts/$script"
  done
  cp "$ROOT/scripts/first-boot-proxmox.service" "$ROOT/scripts/pve-management-ready.service" \
    "$case_root/cdrom/t2/systemd/"
  cp "$ROOT/scripts/pve-cluster-hosts-sync.conf" "$case_root/cdrom/t2/systemd/"
  printf '259:0\n' > "$case_root/sys/class/block/nvme0n1/dev"
  : > "$case_root/commands.log"
}

run_setup() {
  local case_root=$1 mode=$2
  shift 2
  env PATH="$BIN:$PATH" T2_TARGET_ROOT="$case_root/target" T2_CDROM_ROOT="$case_root/cdrom" \
    T2_IN_TARGET_BIN="$BIN/in-target" T2_AUTO_DISK=/dev/nvme0n1 \
    T2_UDEV_DIR="$case_root/udev" T2_SYS_CLASS_BLOCK="$case_root/sys/class/block" \
    T2_PROC_MOUNTS="$case_root/proc-mounts" T2_TEST_BLOCK_DEVICES='/dev/nvme0n1p9 /dev/fakepv' \
    T2_TEST_COMMAND_LOG="$case_root/commands.log" "$@" \
    "$ROOT/scripts/t2-target-setup.sh" "$mode"
}

assert_common_setup() {
  local case_root=$1
  grep -Fq 'GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt pcie_ports=compat"' "$case_root/target/etc/default/grub"
  for module in t2bce_core t2bce_vhci t2bce_audio applesmc apple_gmux hid_appletb_bl hid_appletb_kbd; do
    grep -Fxq "$module" "$case_root/target/etc/initramfs-tools/modules"
  done
  test -f "$case_root/target/usr/local/sbin/first-boot-proxmox.sh"
  test -f "$case_root/target/etc/systemd/system/first-boot-proxmox.service"
  test -f "$case_root/target/etc/systemd/system/pve-management-ready.service"
  test -f "$case_root/target/etc/systemd/system/pve-cluster.service.d/10-pve-mbp-hosts-sync.conf"
  grep -Fxq 'PermitRootLogin yes' "$case_root/target/etc/ssh/sshd_config.d/10-t2.conf"
  grep -Fq 'systemctl enable ssh.service first-boot-proxmox.service pve-management-ready.service' "$case_root/commands.log"
  test ! -e "$case_root/target/tmp/t2-debs"
  grep -q 'Target setup completed successfully' "$case_root/target/var/log/t2-target-setup.log"
}

# Automatic layout: exactly one unsigned LVM reservation is initialized.
make_case auto-valid
cat > "$WORK/auto-valid/udev/b259:0:9" <<'EOF'
E:ID_PART_ENTRY_TYPE=e6d6d379-f507-44c2-a23c-238f2a3df928
E:ID_PART_ENTRY_DISK=259:0
E:ID_PART_ENTRY_NUMBER=9
EOF
run_setup "$WORK/auto-valid" auto
grep -Fq 'pvcreate --yes /dev/nvme0n1p9' "$WORK/auto-valid/commands.log"
grep -Fq 'vgcreate pve /dev/nvme0n1p9' "$WORK/auto-valid/commands.log"
assert_common_setup "$WORK/auto-valid"

# Automatic layout refuses ambiguous candidates before any PV write.
make_case auto-ambiguous
cp "$WORK/auto-valid/udev/b259:0:9" "$WORK/auto-ambiguous/udev/b259:0:9"
sed 's/NUMBER=9/NUMBER=10/' "$WORK/auto-valid/udev/b259:0:9" > "$WORK/auto-ambiguous/udev/b259:0:10"
if run_setup "$WORK/auto-ambiguous" auto >/dev/null 2>&1; then
  echo 'FAIL: auto accepted multiple unused LVM reservations' >&2
  exit 1
fi
! grep -q '^pvcreate\|^vgcreate' "$WORK/auto-ambiguous/commands.log"
grep -q 'expected exactly one unused LVM reservation' "$WORK/auto-ambiguous/target/var/log/t2-target-setup.log"

make_case auto-signed
cp "$WORK/auto-valid/udev/b259:0:9" "$WORK/auto-signed/udev/b259:0:9"
if run_setup "$WORK/auto-signed" auto T2_TEST_WIPED_SIGS=ext4 >/dev/null 2>&1; then
  echo 'FAIL: auto mode accepted an LVM reservation with a filesystem signature' >&2
  exit 1
fi
! grep -q '^pvcreate\|^vgcreate' "$WORK/auto-signed/commands.log"

# Manual layout accepts an existing pve VG only with no thin pool and free extents.
make_case manual-existing-vg
run_setup "$WORK/manual-existing-vg" manual T2_TEST_VG_PRESENT=1 T2_TEST_FREE_EXTENTS=16
! grep -q '^vgcreate' "$WORK/manual-existing-vg/commands.log"
assert_common_setup "$WORK/manual-existing-vg"

make_case manual-existing-thinpool
if run_setup "$WORK/manual-existing-thinpool" manual T2_TEST_VG_PRESENT=1 T2_TEST_LV_PRESENT=1 >/dev/null 2>&1; then
  echo 'FAIL: manual mode accepted an existing pve/data thin pool' >&2
  exit 1
fi
! grep -q '^vgcreate' "$WORK/manual-existing-thinpool/commands.log"

make_case manual-no-free-extents
if run_setup "$WORK/manual-no-free-extents" manual T2_TEST_VG_PRESENT=1 T2_TEST_FREE_EXTENTS=0 >/dev/null 2>&1; then
  echo 'FAIL: manual mode accepted pve with no free extents' >&2
  exit 1
fi
! grep -q '^vgcreate' "$WORK/manual-no-free-extents/commands.log"

# If pve is absent, exactly one unassigned LVM PV is enough to create it.
make_case manual-one-pv
run_setup "$WORK/manual-one-pv" manual T2_TEST_UNASSIGNED_PVS='/dev/fakepv |' T2_TEST_WIPED_SIGS=LVM2_member
grep -Fq 'vgcreate pve /dev/fakepv' "$WORK/manual-one-pv/commands.log"
assert_common_setup "$WORK/manual-one-pv"

# The legacy linux-image fallback installs the former -t2-pve suffix.
make_case manual-legacy-kernel
rm -f "$WORK/manual-legacy-kernel/cdrom/t2/debs"/*.deb
touch "$WORK/manual-legacy-kernel/cdrom/t2/debs/linux-image-6.18.56-t2-pve_6.18.56_amd64.deb"
run_setup "$WORK/manual-legacy-kernel" manual T2_TEST_UNASSIGNED_PVS='/dev/fakepv |' \
  T2_TEST_WIPED_SIGS=LVM2_member T2_TEST_INSTALLED_KERNELS=6.18.56-t2-pve
grep -Fq 'update-initramfs -u -k 6.18.56-t2-pve' "$WORK/manual-legacy-kernel/commands.log"
grep -q 'Validated installed T2 kernel 6.18.56-t2-pve and matching initrd' \
  "$WORK/manual-legacy-kernel/target/var/log/t2-target-setup.log"
assert_common_setup "$WORK/manual-legacy-kernel"

# Never guess when more than one supported T2 kernel is present.
make_case manual-multiple-kernels
if run_setup "$WORK/manual-multiple-kernels" manual T2_TEST_VG_PRESENT=1 \
  T2_TEST_INSTALLED_KERNELS='7.0.14-30-pve-t2 6.18.56-t2-pve' >/dev/null 2>&1; then
  echo 'FAIL: manual mode accepted multiple installed T2 kernels' >&2
  exit 1
fi
grep -q 'expected exactly one T2 kernel image.*found 2' \
  "$WORK/manual-multiple-kernels/target/var/log/t2-target-setup.log"
! grep -q '^vgcreate' "$WORK/manual-multiple-kernels/commands.log"

# Do not use multiple unassigned PVs or overwrite a filesystem signature.
make_case manual-many-pv
if run_setup "$WORK/manual-many-pv" manual T2_TEST_UNASSIGNED_PVS=$'/dev/fakepv |\n/dev/nvme0n1p9 |' >/dev/null 2>&1; then
  echo 'FAIL: manual mode accepted multiple unassigned PVs' >&2
  exit 1
fi
! grep -q '^vgcreate' "$WORK/manual-many-pv/commands.log"

make_case manual-fs-signature
if run_setup "$WORK/manual-fs-signature" manual T2_TEST_UNASSIGNED_PVS='/dev/fakepv |' T2_TEST_WIPED_SIGS=ext4 >/dev/null 2>&1; then
  echo 'FAIL: manual mode accepted a filesystem signature on its candidate PV' >&2
  exit 1
fi
! grep -q '^vgcreate' "$WORK/manual-fs-signature/commands.log"

make_case manual-bad-layout
if run_setup "$WORK/manual-bad-layout" manual T2_TEST_MISSING_MOUNT="$WORK/manual-bad-layout/target/boot/efi" >/dev/null 2>&1; then
  echo 'FAIL: manual mode accepted a target without /boot/efi mounted' >&2
  exit 1
fi
! grep -q '^vgcreate' "$WORK/manual-bad-layout/commands.log"

printf 'PASS: target setup validates auto/manual LVM and mounts, installs the T2 kernel, and stages first-boot configuration.\n'
