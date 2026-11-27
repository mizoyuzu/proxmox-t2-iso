#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/scripts/first-boot-proxmox.sh"
FIXTURE="$ROOT/tests/fixtures/grub-pve-distributor.cfg"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Load the production functions without running first-boot provisioning.
eval "$(sed -n '/^grub_t2_id_path() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^grub_default_matches() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^write_grub_defaults() {/,/^}/p' "$SCRIPT")"

expected_latest='gnulinux-advanced-fixture-root>gnulinux-7.0.14-30-pve-t2-advanced-fixture-root'
expected_running='gnulinux-advanced-fixture-root>gnulinux-7.0.13-29-pve-t2-advanced-fixture-root'
actual=$(grub_t2_id_path "$FIXTURE" 7.0.14-30-pve)
[[ "$actual" == "$expected_latest" ]] || {
  printf 'FAIL: expected first ordered T2 GRUB ID path %q, got %q\n' "$expected_latest" "$actual" >&2
  exit 1
}

# Multiple T2 kernels are valid. Keep the running T2 version when it is
# present; a stock running kernel falls back to the first (newest ordered) T2.
actual_running=$(grub_t2_id_path "$FIXTURE" 7.0.13-29-pve-t2)
[[ "$actual_running" == "$expected_running" ]] || {
  printf 'FAIL: expected the running T2 GRUB ID path %q, got %q\n' "$expected_running" "$actual_running" >&2
  exit 1
}

# Keep compatibility with the former -t2-pve release suffix as well.
legacy_suffix="$TMPDIR/grub-legacy-t2-suffix.cfg"
cat > "$legacy_suffix" <<'EOF'
if [ "${feature_menuentry_id}" = y ]; then
  set menuentry_id_option="--id"
else
  set menuentry_id_option=""
fi
submenu 'Advanced options' $menuentry_id_option 'gnulinux-advanced-fixture-root' {
  menuentry 'Linux 6.18.56-t2-pve' $menuentry_id_option 'gnulinux-6.18.56-t2-pve-advanced-fixture-root' {
    linux /vmlinuz-6.18.56-t2-pve root=UUID=test ro quiet
  }
}
EOF
legacy_expected='gnulinux-advanced-fixture-root>gnulinux-6.18.56-t2-pve-advanced-fixture-root'
[[ $(grub_t2_id_path "$legacy_suffix" 6.18.56-t2-pve) == "$legacy_expected" ]] || {
  printf 'FAIL: legacy -t2-pve GRUB suffix was not recognized.\n' >&2
  exit 1
}

simple_t2="$TMPDIR/grub-simple-t2.cfg"
cat > "$simple_t2" <<'EOF'
if [ "${feature_menuentry_id}" = y ]; then
  set menuentry_id_option="--id"
else
  set menuentry_id_option=""
fi
menuentry 'T2 kernel with generic ID' $menuentry_id_option 'gnulinux-simple-fixture-root' {
  linux /vmlinuz-6.18.56-t2-pve root=UUID=test ro quiet
}
EOF
if grub_t2_id_path "$simple_t2" 7.0.14-30-pve >/dev/null 2>&1; then
  printf 'FAIL: generic gnulinux-simple-* ID was accepted as a version-specific T2 entry.\n' >&2
  exit 1
fi

if grub_default_matches "$expected_latest" "$FIXTURE"; then
  printf 'FAIL: stale Debian title default unexpectedly matched the new ID path.\n' >&2
  exit 1
fi

defaults="$TMPDIR/grub-defaults"
cat > "$defaults" <<'EOF'
GRUB_DEFAULT=Advanced\ options\ for\ Debian\ GNU/Linux\>Debian\ GNU/Linux,\ with\ Linux\ 6.18.56-t2-pve
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Proxmox VE GNU/Linux"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
EOF
write_grub_defaults "$defaults" "$expected_latest"
# shellcheck disable=SC1090
source "$defaults"
[[ "$GRUB_DEFAULT" == "$expected_latest" ]] || {
  printf 'FAIL: generated GRUB_DEFAULT is %q, expected %q\n' "$GRUB_DEFAULT" "$expected_latest" >&2
  exit 1
}
[[ "$GRUB_TIMEOUT" == 10 ]] || {
  printf 'FAIL: generated GRUB_TIMEOUT is %q, expected 10\n' "$GRUB_TIMEOUT" >&2
  exit 1
}
[[ $(grep -c '^GRUB_DEFAULT=' "$defaults") == 1 ]] || {
  printf 'FAIL: expected exactly one GRUB_DEFAULT setting.\n' >&2
  exit 1
}
[[ $(grep -c '^GRUB_TIMEOUT=' "$defaults") == 1 ]] || {
  printf 'FAIL: expected exactly one GRUB_TIMEOUT setting.\n' >&2
  exit 1
}

# Model update-grub consuming the ID path while PVE has changed the visible
# titles. The stable submenu/entry IDs still identify the chosen T2 version.
generated="$TMPDIR/grub.cfg"
awk -v wanted="$GRUB_DEFAULT" '
  /^[[:space:]]*set default=/ {
    print "   set default=\"" wanted "\""
    next
  }
  { print }
' "$FIXTURE" | sed 's/Advanced options for Proxmox VE GNU\/Linux/Advanced options for Renamed PVE Menu/g; s/Proxmox VE GNU\/Linux/Renamed PVE Menu/g' > "$generated"
regenerated_t2=$(grub_t2_id_path "$generated" 7.0.14-30-pve)
[[ "$regenerated_t2" == "$expected_latest" ]] || {
  printf 'FAIL: renamed menu titles changed ID resolution to %q\n' "$regenerated_t2" >&2
  exit 1
}
grub_default_matches "$expected_latest" "$generated" || {
  printf 'FAIL: generated set default does not match the version-specific T2 ID path.\n' >&2
  exit 1
}
grep -q "'gnulinux-simple-fixture-root'" "$generated" || {
  printf 'FAIL: manual stock Proxmox menu entry was removed.\n' >&2
  exit 1
}

printf 'PASS: GRUB selects version-specific -pve-t2 IDs, accepts legacy -t2-pve, handles multiple kernels, and keeps stock entries.\n'
