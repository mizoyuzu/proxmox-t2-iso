#!/usr/bin/env bash
# Offline tests for the PVE T2 image package/config/module verifier.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$repo_root/scripts/verify-pve-kernel.sh"
required_config="$repo_root/config-pve-t2-required.txt"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

command -v dpkg-deb >/dev/null || {
  echo "dpkg-deb is required for the offline package verifier test" >&2
  exit 1
}

make_package() {
  local case_name="$1"
  local package_name="$2"
  local variant="$3"
  local module_layout="${4:-usr}"
  local root="$fixture/$case_name/root"
  local deb="$fixture/$case_name/proxmox-kernel-7.0.14-30-pve-t2_7.0.14-30_amd64.deb"
  local modules_root="$root/usr/lib/modules/7.0.14-30-pve-t2"
  if [[ "$module_layout" == legacy ]]; then
    modules_root="$root/lib/modules/7.0.14-30-pve-t2"
  fi
  mkdir -p "$root/DEBIAN" "$root/boot" "$modules_root/kernel/fixture"
  cat > "$root/DEBIAN/control" <<CONTROL
Package: $package_name
Version: 7.0.14-30
Architecture: amd64
Maintainer: Offline test <test@example.invalid>
Description: verifier fixture
CONTROL

  while IFS= read -r symbol || [[ -n "$symbol" ]]; do
    [[ -z "$symbol" || "$symbol" == \#* ]] && continue
    value=m
    [[ "$symbol" == CONFIG_STAGING ]] && value=y
    if [[ "$variant" == "missing-config" && "$symbol" == CONFIG_KVM ]]; then
      continue
    fi
    if [[ "$variant" == "wrong-t2-mode" && "$symbol" == CONFIG_T2BCE_CORE ]]; then
      value=y
    fi
    printf '%s=%s\n' "$symbol" "$value"
  done < "$required_config" > "$root/boot/config-7.0.14-30-pve-t2"

  local module
  for module in \
    t2bce_core.ko t2bce_vhci.ko t2bce_audio.ko t2bce_dma.ko t2bce_ave.ko \
    applesmc.ko apple_gmux.ko hid-appletb-kbd.ko hid-appletb-bl.ko appletbdrm.ko \
    zfs.ko spl.ko r8152.ko softdog.ko; do
    if [[ "$variant" == "missing-module" && "$module" == zfs.ko ]]; then
      continue
    fi
    : > "$modules_root/kernel/fixture/$module"
  done

  mkdir -p "$(dirname -- "$deb")"
  dpkg-deb --root-owner-group --build "$root" "$deb" >/dev/null
  printf '%s\n' "$deb"
}

expect_failure() {
  local deb="$1"
  local expected="$2"
  local log="$fixture/failure.log"
  if "$verifier" "$deb" >"$log" 2>&1; then
    echo "expected verifier failure for $deb" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected" "$log"; then
    cat "$log" >&2
    echo "failure did not mention expected reason: $expected" >&2
    exit 1
  fi
}

valid_deb="$(make_package valid proxmox-kernel-7.0.14-30-pve-t2 valid)"
"$verifier" "$valid_deb"

legacy_deb="$(make_package legacy proxmox-kernel-7.0.14-30-pve-t2 valid legacy)"
"$verifier" "$legacy_deb"

missing_config_deb="$(make_package missing-config proxmox-kernel-7.0.14-30-pve-t2 missing-config)"
expect_failure "$missing_config_deb" "CONFIG_KVM is not enabled"

wrong_t2_mode_deb="$(make_package wrong-t2-mode proxmox-kernel-7.0.14-30-pve-t2 wrong-t2-mode)"
expect_failure "$wrong_t2_mode_deb" "CONFIG_T2BCE_CORE must be built as a module"

missing_module_deb="$(make_package missing-module proxmox-kernel-7.0.14-30-pve-t2 missing-module)"
expect_failure "$missing_module_deb" "required kernel module is missing: zfs.ko"

headers_deb="$(make_package headers proxmox-headers-7.0.14-30-pve-t2 valid)"
expect_failure "$headers_deb" "unexpected Debian Package field"
headers_named_deb="${headers_deb/proxmox-kernel-/proxmox-headers-}"
mv -- "$headers_deb" "$headers_named_deb"
expect_failure "$headers_named_deb" "not a proxmox-kernel-*-pve-t2 image package"

meta_deb="$(make_package meta proxmox-kernel-7.0 valid)"
expect_failure "$meta_deb" "unexpected Debian Package field"

signed_deb="$(make_package signed-template proxmox-kernel-7.0.14-30-pve-t2-signed-template valid)"
# The filename intentionally looks like the image package: inspect package metadata too.
expect_failure "$signed_deb" "unexpected Debian Package field"

echo "PASS: offline PVE T2 verifier checks package type, config symbols, T2BCE module mode, and modules."
