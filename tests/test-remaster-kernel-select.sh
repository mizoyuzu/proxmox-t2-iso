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
[ "${1:-}" = -f ] && [ "${3:-}" = Package ] || exit 2
cat "$2.package"
EOF
chmod 0755 "$BIN/dpkg-deb"

make_deb() {
  local name=$1 package=$2
  : > "$DEBS/$name"
  printf '%s\n' "$package" > "$DEBS/$name.package"
}
select_deb() { PATH="$BIN:$PATH" "$ROOT/scripts/select-kernel-deb.sh" "$DEBS"; }

make_deb proxmox-kernel-7.0.14-30-pve-t2_7.0.14-30_amd64.deb proxmox-kernel-7.0.14-30-pve-t2
make_deb proxmox-kernel-headers-7.0.14-30-pve-t2_7.0.14-30_amd64.deb proxmox-kernel-headers-7.0.14-30-pve-t2
make_deb proxmox-kernel-7.0.14-30-pve-t2-signed-template_7.0.14-30_all.deb proxmox-kernel-7.0.14-30-pve-t2-signed-template
make_deb proxmox-kernel-meta_7.0.14-30_all.deb proxmox-kernel-meta
make_deb linux-image-6.18.56-t2-pve_6.18.56_amd64.deb linux-image-6.18.56-t2-pve

selected=$(select_deb)
[[ $selected == "$DEBS/proxmox-kernel-7.0.14-30-pve-t2_7.0.14-30_amd64.deb" ]] || {
  printf 'FAIL: did not prefer the PVE T2 image: %s\n' "$selected" >&2
  exit 1
}

rm -f "$DEBS"/proxmox-kernel-*.deb "$DEBS"/*.package
make_deb linux-image-amd64_6.18_all.deb linux-image-amd64
make_deb linux-image-6.18.56-t2-pve_6.18.56_amd64.deb linux-image-6.18.56-t2-pve
selected=$(select_deb)
[[ $selected == "$DEBS/linux-image-6.18.56-t2-pve_6.18.56_amd64.deb" ]] || {
  printf 'FAIL: legacy linux-image fallback was not selected: %s\n' "$selected" >&2
  exit 1
}

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

printf 'PASS: remaster selects one PVE T2 image preferentially, excludes non-image packages, and uses the legacy fallback safely.\n'
