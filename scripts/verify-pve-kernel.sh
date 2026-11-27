#!/usr/bin/env bash
# Verify a built Proxmox T2 kernel image package without installing it.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REQUIRED_CONFIG="$SCRIPT_DIR/../config-pve-t2-required.txt"
MODULES=(
  t2bce_core.ko
  t2bce_vhci.ko
  t2bce_audio.ko
  t2bce_dma.ko
  t2bce_ave.ko
  applesmc.ko
  apple-gmux.ko
  hid-appletb-kbd.ko
  hid-appletb-bl.ko
  appletbdrm.ko
  zfs.ko
  spl.ko
  r8152.ko
  softdog.ko
)

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: $0 IMAGE.deb"
deb="$1"
[[ -f "$deb" ]] || fail "image package does not exist: $deb"
[[ -f "$REQUIRED_CONFIG" ]] || fail "required config list is missing: $REQUIRED_CONFIG"
command -v dpkg-deb >/dev/null || fail "dpkg-deb is required to inspect the image package"

deb_name="$(basename -- "$deb")"
case "$deb_name" in
  proxmox-kernel-*-pve-t2_*.deb) ;;
  *) fail "not a proxmox-kernel-*-pve-t2 image package: $deb_name" ;;
esac

package_name="$(dpkg-deb -f "$deb" Package)" || fail "cannot read package metadata: $deb"
case "$package_name" in
  proxmox-kernel-*-pve-t2) ;;
  *) fail "unexpected Debian Package field: $package_name" ;;
esac
case "$package_name" in
  *headers*|*meta*|*signed-template*)
    fail "expected an image package, not headers/meta/signed-template: $package_name"
    ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
root="$tmp/root"
dpkg-deb --extract "$deb" "$root"
[[ -d "$root/boot" ]] || fail "image package has no /boot directory"
module_roots=()
for candidate in "$root/lib/modules" "$root/usr/lib/modules"; do
  [[ -d "$candidate" ]] && module_roots+=("$candidate")
done
(( ${#module_roots[@]} > 0 )) || \
  fail "image package has neither /lib/modules nor /usr/lib/modules directory"

mapfile -d '' -t configs < <(find "$root/boot" -maxdepth 1 -type f -name 'config-*' -print0)
(( ${#configs[@]} > 0 )) || fail "image package has no boot/config-* file"

for config in "${configs[@]}"; do
  while IFS= read -r symbol || [[ -n "$symbol" ]]; do
    [[ -z "$symbol" || "$symbol" == \#* ]] && continue
    [[ "$symbol" =~ ^CONFIG_[A-Z0-9_]+$ ]] || fail "invalid symbol in required config list: $symbol"
    if [[ "$symbol" == CONFIG_T2BCE_* ]]; then
      grep -Fqx -- "$symbol=m" "$config" || \
        fail "$symbol must be built as a module (=m) in $(basename -- "$config")"
    else
      grep -Eq "^${symbol}=(y|m)$" "$config" || \
        fail "$symbol is not enabled (=y or =m) in $(basename -- "$config")"
    fi
  done < "$REQUIRED_CONFIG"
done

for module in "${MODULES[@]}"; do
  module_base="${module%.ko}"
  found=0
  for modules_root in "${module_roots[@]}"; do
    if find "$modules_root" -type f \
      \( -name "$module" -o -name "$module.*" \) -print -quit | grep -q .; then
      found=1
      break
    fi
  done
  if (( found == 0 )); then
    fail "required kernel module is missing: $module_base.ko"
  fi
done

echo "PASS: $deb_name has the required PVE/T2 config and modules."
