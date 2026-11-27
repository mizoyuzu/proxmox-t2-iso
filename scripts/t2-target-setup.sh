#!/bin/sh
# Complete the T2-specific target setup from Debian Installer's late_command.
set -eu

MODE=${1:-}
case "$MODE" in
  auto|manual) ;;
  *) echo "usage: $0 auto|manual" >&2; exit 2 ;;
esac

TARGET=${T2_TARGET_ROOT:-/target}
CDROM=${T2_CDROM_ROOT:-/cdrom}
IN_TARGET=${T2_IN_TARGET_BIN:-in-target}
AUTO_DISK=${T2_AUTO_DISK:-/dev/nvme0n1}
UDEV_DIR=${T2_UDEV_DIR:-/run/udev/data}
SYS_CLASS_BLOCK=${T2_SYS_CLASS_BLOCK:-/sys/class/block}
PROC_MOUNTS=${T2_PROC_MOUNTS:-/proc/mounts}
LOG_FILE="$TARGET/var/log/t2-target-setup.log"

mkdir -p "$TARGET/var/log"
exec >>"$LOG_FILE" 2>&1

log() { printf '[t2-target-setup:%s] %s\n' "$MODE" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

for required_tool in mountpoint awk wipefs vgs pvs lvs pvcreate vgcreate; do
  command -v "$required_tool" >/dev/null 2>&1 || fail "required installer command is missing: $required_tool"
done
command -v "$IN_TARGET" >/dev/null 2>&1 || fail "in-target command is missing: $IN_TARGET"

is_block_device() {
  if [ -n "${T2_TEST_BLOCK_DEVICES:-}" ]; then
    case " $T2_TEST_BLOCK_DEVICES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
  fi
  [ -b "$1" ]
}

assert_not_mounted() {
  device=$1
  if [ -r "$PROC_MOUNTS" ] && awk -v wanted="$device" '$1 == wanted { found=1 } END { exit !found }' "$PROC_MOUNTS"; then
    fail "$device is mounted; refusing to use it as an LVM PV."
  fi
}

target_layout_check() {
  for mount_path in "$TARGET" "$TARGET/boot" "$TARGET/boot/efi"; do
    mountpoint -q "$mount_path" || fail "required target mount is missing: $mount_path"
  done
  [ -r "$TARGET/etc/fstab" ] || fail 'target /etc/fstab is missing.'
  awk '$0 !~ /^[[:space:]]*#/ && NF >= 3 && $3 == "swap" { found=1 } END { exit !found }' "$TARGET/etc/fstab" ||
    fail 'target /etc/fstab has no swap entry; configure swap in partman before continuing.'
}

create_auto_vg() {
  diskno_file="$SYS_CLASS_BLOCK/${AUTO_DISK##*/}/dev"
  [ -r "$diskno_file" ] || fail "cannot identify the target disk $AUTO_DISK."
  diskno=$(cat "$diskno_file")
  candidates=
  existing=

  for record in "$UDEV_DIR"/b*; do
    [ -f "$record" ] || continue
    part_type=$(sed -n 's/^E:ID_PART_ENTRY_TYPE=//p' "$record" | sed -n '1p' | tr '[:upper:]' '[:lower:]')
    [ "$part_type" = e6d6d379-f507-44c2-a23c-238f2a3df928 ] || continue
    part_disk=$(sed -n 's/^E:ID_PART_ENTRY_DISK=//p' "$record" | sed -n '1p')
    [ "$part_disk" = "$diskno" ] || continue
    part_number=$(sed -n 's/^E:ID_PART_ENTRY_NUMBER=//p' "$record" | sed -n '1p')
    [ -n "$part_number" ] || fail "no partition number in udev record $record."
    part_fs=$(sed -n 's/^E:ID_FS_TYPE=//p' "$record" | sed -n '1p')
    partition="${AUTO_DISK}p${part_number}"
    if [ -z "$part_fs" ]; then
      log "Unused LVM reservation candidate: $partition"
      candidates="$candidates $partition"
    else
      log "Skipping signed partition $partition (ID_FS_TYPE=$part_fs)."
      existing="$existing $partition"
    fi
  done

  # Intentional word splitting: the udev values above are numeric partition names.
  set -- $candidates
  [ "$#" -eq 1 ] || fail "expected exactly one unused LVM reservation on $AUTO_DISK, found $# (candidates=[$candidates], signed=[$existing])."
  pv=$1
  is_block_device "$pv" || fail "$pv is not a block device."
  assert_not_mounted "$pv"
  raw_signatures=$(wipefs -n --noheadings -o TYPE "$pv" 2>/dev/null) || fail "could not safely inspect signatures on $pv."
  signatures=$(printf '%s\n' "$raw_signatures" | awk 'NF { print $1 }')
  [ -z "$signatures" ] || fail "filesystem or PV signature ($signatures) found on $pv; refusing to overwrite it."
  all_vgs=$(vgs --noheadings -o vg_name 2>/dev/null) || fail 'could not safely inspect existing volume groups.'
  if printf '%s\n' "$all_vgs" | awk '$1 == "pve" { found=1 } END { exit !found }'; then
    fail 'VG pve already exists; refusing to reuse it in automatic mode.'
  fi
  log "Creating PV and VG pve on $pv."
  pvcreate --yes "$pv"
  vgcreate pve "$pv"
}

create_or_check_manual_vg() {
  all_vgs=$(vgs --noheadings -o vg_name 2>/dev/null) || fail 'could not safely inspect existing volume groups.'
  if printf '%s\n' "$all_vgs" | awk '$1 == "pve" { found=1 } END { exit !found }'; then
    lv_names=$(lvs --noheadings -o lv_name pve 2>/dev/null) || fail 'could not safely inspect logical volumes in VG pve.'
    if printf '%s\n' "$lv_names" | awk '$1 == "data" { found=1 } END { exit !found }'; then
      fail 'VG pve already contains pve/data; manual install requires the thin pool to be absent.'
    fi
    free_output=$(vgs --noheadings -o vg_free_count pve 2>/dev/null) || fail 'could not safely read free extents in VG pve.'
    free_extents=$(printf '%s\n' "$free_output" | tr -d '[:space:]')
    case "$free_extents" in ''|*[!0-9]*) fail "could not read free extents in VG pve: $free_extents" ;; esac
    [ "$free_extents" -gt 0 ] || fail 'VG pve has no free extents for the first-boot thin pool.'
    log "Existing VG pve is valid with $free_extents free extents."
    return
  fi

  pv_output=$(pvs --noheadings --separator '|' -o pv_name,vg_name 2>/dev/null) ||
    fail 'could not inspect physical volumes for manual LVM setup.'
  unassigned=$(printf '%s\n' "$pv_output" |
    awk -F '|' '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if ($1 != "" && $2 == "") print $1 }')
  set -- $unassigned
  [ "$#" -eq 1 ] || fail "VG pve is absent; expected exactly one VG-unassigned PV, found $# ($unassigned). Create VG pve manually or resolve the PV layout."
  pv=$1
  is_block_device "$pv" || fail "$pv is not a block device."
  assert_not_mounted "$pv"
  raw_signatures=$(wipefs -n --noheadings -o TYPE "$pv" 2>/dev/null) || fail "could not safely inspect signatures on PV $pv."
  signatures=$(printf '%s\n' "$raw_signatures" | awk 'NF { print $1 }')
  case "$signatures" in
    ''|LVM2_member) ;;
    *) fail "filesystem signature ($signatures) found on PV $pv; refusing to modify it." ;;
  esac
  log "Creating VG pve on the single unassigned PV $pv."
  vgcreate pve "$pv"
}

log 'Validating target mounts and swap configuration.'
target_layout_check
case "$MODE" in
  auto) create_auto_vg ;;
  manual) create_or_check_manual_vg ;;
esac

DEB_DIR="$CDROM/t2/debs"
STAGING_DIR="$TARGET/tmp/t2-debs"
set -- "$DEB_DIR"/*.deb
[ -f "$1" ] || fail "no kernel image deb found in $DEB_DIR."
[ "$#" -eq 1 ] || fail "expected one kernel image deb in $DEB_DIR, found $#; remaster must stage only the image package."
case "${1##*/}" in
  proxmox-kernel-*-pve-t2_*.deb|linux-image-*.deb) ;;
  *) fail "unexpected kernel package in ISO payload: ${1##*/}" ;;
esac
mkdir -p "$STAGING_DIR"
cp -- "$1" "$STAGING_DIR/"
log "Installing kernel package ${1##*/}."
"$IN_TARGET" sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/t2-debs/*.deb'

kernel_count=0
KERNEL_IMAGE=
for kernel_image in "$TARGET"/boot/vmlinuz-*-pve-t2 "$TARGET"/boot/vmlinuz-*-t2-pve; do
  [ -f "$kernel_image" ] || continue
  kernel_count=$((kernel_count + 1))
  KERNEL_IMAGE=$kernel_image
done
[ "$kernel_count" -eq 1 ] || fail "expected exactly one T2 kernel image (-pve-t2 or legacy -t2-pve), found $kernel_count."
KVER=${KERNEL_IMAGE##*/vmlinuz-}

initrd_count=0
INITRD_IMAGE=
for initrd_image in "$TARGET"/boot/initrd.img-*-pve-t2 "$TARGET"/boot/initrd.img-*-t2-pve; do
  [ -f "$initrd_image" ] || continue
  initrd_count=$((initrd_count + 1))
  INITRD_IMAGE=$initrd_image
done
[ "$initrd_count" -eq 1 ] || fail "expected exactly one T2 initrd (-pve-t2 or legacy -t2-pve), found $initrd_count."
[ "$INITRD_IMAGE" = "$TARGET/boot/initrd.img-$KVER" ] ||
  fail "T2 kernel/initrd versions do not match: $KVER and ${INITRD_IMAGE##*/initrd.img-}."
log "Validated installed T2 kernel $KVER and matching initrd."

MODULES_FILE="$TARGET/etc/initramfs-tools/modules"
mkdir -p "${MODULES_FILE%/*}"
touch "$MODULES_FILE"
for module in t2bce_core t2bce_vhci t2bce_audio applesmc apple_gmux hid_appletb_bl hid_appletb_kbd; do
  grep -Fxq "$module" "$MODULES_FILE" || printf '%s\n' "$module" >> "$MODULES_FILE"
done
"$IN_TARGET" update-initramfs -u -k "$KVER"

GRUB_DEFAULT_FILE="$TARGET/etc/default/grub"
[ -f "$GRUB_DEFAULT_FILE" ] || fail 'target /etc/default/grub is missing.'
cmdline_line=$(grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT_FILE" | sed -n '1p')
[ -n "$cmdline_line" ] || fail 'GRUB_CMDLINE_LINUX_DEFAULT is missing from target /etc/default/grub.'
cmdline_value=${cmdline_line#*=}
case "$cmdline_value" in
  \"*\") cmdline_value=${cmdline_value#\"}; cmdline_value=${cmdline_value%\"} ;;
  \'*\') cmdline_value=${cmdline_value#\'}; cmdline_value=${cmdline_value%\'} ;;
esac
case "$cmdline_value" in *'$'*|*'`'*) fail 'dynamic shell expansion in GRUB_CMDLINE_LINUX_DEFAULT is not supported.' ;; esac
for argument in intel_iommu=on iommu=pt pcie_ports=compat; do
  case " $cmdline_value " in *" $argument "*) ;; *) cmdline_value="${cmdline_value:+$cmdline_value }$argument" ;; esac
done
grub_tmp="$GRUB_DEFAULT_FILE.t2tmp"
awk -v replacement="GRUB_CMDLINE_LINUX_DEFAULT=\"$cmdline_value\"" '
  /^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=/ { print replacement; found++; next }
  { print }
  END { if (found != 1) exit 2 }
' "$GRUB_DEFAULT_FILE" > "$grub_tmp" || fail 'could not safely update GRUB_CMDLINE_LINUX_DEFAULT.'
chmod 0644 "$grub_tmp"
mv -f "$grub_tmp" "$GRUB_DEFAULT_FILE"
"$IN_TARGET" update-grub

mkdir -p "$TARGET/usr/local/sbin" "$TARGET/etc/systemd/system/pve-cluster.service.d" \
  "$TARGET/etc/ssh/sshd_config.d"
for script in first-boot-proxmox.sh configure-pve-network.sh sync-pve-mbp-hosts.sh \
  verify-pve-management-ready.sh disable-pve-enterprise-source.sh; do
  [ -f "$CDROM/t2/scripts/$script" ] || fail "required script payload is missing: $script"
  cp -- "$CDROM/t2/scripts/$script" "$TARGET/usr/local/sbin/$script"
  chmod 0755 "$TARGET/usr/local/sbin/$script"
done
for unit in first-boot-proxmox.service pve-management-ready.service; do
  [ -f "$CDROM/t2/systemd/$unit" ] || fail "required systemd payload is missing: $unit"
  cp -- "$CDROM/t2/systemd/$unit" "$TARGET/etc/systemd/system/$unit"
done
[ -f "$CDROM/t2/systemd/pve-cluster-hosts-sync.conf" ] || fail 'pve-cluster hosts-sync drop-in is missing.'
cp -- "$CDROM/t2/systemd/pve-cluster-hosts-sync.conf" \
  "$TARGET/etc/systemd/system/pve-cluster.service.d/10-pve-mbp-hosts-sync.conf"

printf '%s\n' 'PermitRootLogin yes' 'PasswordAuthentication yes' > "$TARGET/etc/ssh/sshd_config.d/10-t2.conf"
chmod 0644 "$TARGET/etc/ssh/sshd_config.d/10-t2.conf"
if [ -f "$CDROM/t2/ssh/authorized_keys" ]; then
  mkdir -p "$TARGET/root/.ssh"
  chmod 0700 "$TARGET/root/.ssh"
  cp -- "$CDROM/t2/ssh/authorized_keys" "$TARGET/root/.ssh/authorized_keys"
  chmod 0600 "$TARGET/root/.ssh/authorized_keys"
  log 'Optional SSH authorized_keys installed.'
else
  log 'No optional SSH key supplied; use the root password entered in the installer.'
fi
if [ -d "$CDROM/t2/firmware/brcm" ]; then
  mkdir -p "$TARGET/lib/firmware/brcm"
  cp -a "$CDROM/t2/firmware/brcm/." "$TARGET/lib/firmware/brcm/"
  log 'Optional Broadcom firmware copied.'
else
  log 'No optional Broadcom firmware supplied.'
fi

"$IN_TARGET" systemctl enable ssh.service first-boot-proxmox.service pve-management-ready.service
rm -f "$STAGING_DIR"/*.deb
rmdir "$STAGING_DIR"
log "Target setup completed successfully for mode=$MODE, kernel=$KVER."
