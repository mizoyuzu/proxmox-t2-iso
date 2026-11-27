#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
BIN="$WORK/bin"
DEBS="$WORK/debs"
mkdir -p "$BIN" "$DEBS"

cat > "$BIN/dpkg-deb" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -f)
    [ "${3:-}" = Package ] || exit 2
    cat "$2.package"
    ;;
  -x)
    package=$(cat "$2.package")
    modules_layout=$(cat "$2.layout")
    case "$package" in
      proxmox-kernel-*) kver=${package#proxmox-kernel-} ;;
      linux-image-*) kver=${package#linux-image-} ;;
      *) exit 2 ;;
    esac
    mkdir -p "$3/boot" "$3/$modules_layout/modules/$kver"
    touch "$3/boot/vmlinuz-$kver"
    ;;
  *) exit 2 ;;
esac
EOF
chmod 0755 "$BIN/dpkg-deb"

make_deb() {
  local name=$1 package=$2 modules_layout=${3:-lib}
  : > "$DEBS/$name"
  printf '%s\n' "$package" > "$DEBS/$name.package"
  printf '%s\n' "$modules_layout" > "$DEBS/$name.layout"
}
select_deb() { PATH="$BIN:$PATH" "$ROOT/scripts/select-kernel-deb.sh" "$DEBS"; }

eval "$(sed -n '/^prepare_kernel_modules_path() {/,/^}/p' "$ROOT/scripts/remaster-iso.sh")"

make_deb proxmox-kernel-7.0.14-30-pve-t2_7.0.14-30_amd64.deb \
  proxmox-kernel-7.0.14-30-pve-t2 usr/lib
make_deb proxmox-kernel-headers-7.0.14-30-pve-t2_7.0.14-30_amd64.deb proxmox-kernel-headers-7.0.14-30-pve-t2
make_deb proxmox-kernel-7.0.14-30-pve-t2-signed-template_7.0.14-30_all.deb proxmox-kernel-7.0.14-30-pve-t2-signed-template
make_deb proxmox-kernel-meta_7.0.14-30_all.deb proxmox-kernel-meta
make_deb linux-image-6.18.56-t2-pve_6.18.56_amd64.deb linux-image-6.18.56-t2-pve

selected=$(select_deb)
[[ $selected == "$DEBS/proxmox-kernel-7.0.14-30-pve-t2_7.0.14-30_amd64.deb" ]] || {
  printf 'FAIL: did not prefer the PVE T2 image: %s\n' "$selected" >&2
  exit 1
}
PVE_EXTRACT="$WORK/pve-extract"
PATH="$BIN:$PATH" dpkg-deb -x "$selected" "$PVE_EXTRACT"
[[ -d "$PVE_EXTRACT/usr/lib/modules/7.0.14-30-pve-t2" ]]
prepare_kernel_modules_path "$PVE_EXTRACT" 7.0.14-30-pve-t2
[[ -L "$PVE_EXTRACT/lib/modules" ]]
[[ $(readlink "$PVE_EXTRACT/lib/modules") == ../usr/lib/modules ]]
[[ -d "$PVE_EXTRACT/lib/modules/7.0.14-30-pve-t2" ]]

rm -f "$DEBS"/proxmox-kernel-*.deb "$DEBS"/*.package "$DEBS"/*.layout
make_deb linux-image-amd64_6.18_all.deb linux-image-amd64
make_deb linux-image-6.18.56-t2-pve_6.18.56_amd64.deb linux-image-6.18.56-t2-pve
selected=$(select_deb)
[[ $selected == "$DEBS/linux-image-6.18.56-t2-pve_6.18.56_amd64.deb" ]] || {
  printf 'FAIL: legacy linux-image fallback was not selected: %s\n' "$selected" >&2
  exit 1
}
LEGACY_EXTRACT="$WORK/legacy-extract"
PATH="$BIN:$PATH" dpkg-deb -x "$selected" "$LEGACY_EXTRACT"
[[ -d "$LEGACY_EXTRACT/lib/modules/6.18.56-t2-pve" ]]
prepare_kernel_modules_path "$LEGACY_EXTRACT" 6.18.56-t2-pve
[[ -d "$LEGACY_EXTRACT/lib/modules/6.18.56-t2-pve" && ! -L "$LEGACY_EXTRACT/lib/modules" ]]

make_deb linux-image-6.18.57-t2-pve_6.18.57_amd64.deb linux-image-6.18.57-t2-pve
if select_deb >/dev/null 2>&1; then
  echo 'FAIL: selector silently chose between multiple fallback image packages' >&2
  exit 1
fi

rm -f "$DEBS"/*.deb "$DEBS"/*.package
if select_deb >/dev/null 2>&1; then
  echo 'FAIL: selector succeeded without a kernel image package' >&2
  exit 1
fi

printf 'PASS: remaster selects PVE T2 first, handles usr/lib and legacy lib module layouts, excludes non-image packages, and uses the legacy fallback safely.\n'
