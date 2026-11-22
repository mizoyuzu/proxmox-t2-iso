#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/scripts/first-boot-proxmox.sh"
FIXTURE="$ROOT/tests/fixtures/grub-pve-distributor.cfg"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Load the production functions without running first-boot provisioning.
eval "$(sed -n '/^grub_t2_default() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^grub_default_matches() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^write_grub_defaults() {/,/^}/p' "$SCRIPT")"

expected='Advanced options for Proxmox VE GNU/Linux>Proxmox VE GNU/Linux, with Linux 6.18.56-t2-pve'
actual=$(grub_t2_default "$FIXTURE")
[[ "$actual" == "$expected" ]] || {
  printf 'FAIL: expected PVE T2 menu path %q, got %q\n' "$expected" "$actual" >&2
  exit 1
}
[[ "$actual" != *'(recovery mode)'* ]] || {
  printf 'FAIL: selected a recovery entry: %s\n' "$actual" >&2
  exit 1
}
if grub_default_matches "$actual" "$FIXTURE"; then
  printf 'FAIL: stale Debian default unexpectedly matched the PVE menu.\n' >&2
  exit 1
fi

defaults="$TMPDIR/grub-defaults"
cat > "$defaults" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Proxmox VE GNU/Linux"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
EOF
write_grub_defaults "$defaults" "$actual"
# shellcheck disable=SC1090
source "$defaults"
[[ "$GRUB_DEFAULT" == "$expected" ]] || {
  printf 'FAIL: generated GRUB_DEFAULT is %q, expected %q\n' "$GRUB_DEFAULT" "$expected" >&2
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

# Model update-grub consuming GRUB_DEFAULT and writing it as `set default`.
generated="$TMPDIR/grub.cfg"
awk -v wanted="$GRUB_DEFAULT" '
  /^[[:space:]]*set[[:space:]]+default=/ {
    print "   set default=\"" wanted "\""
    next
  }
  { print }
' "$FIXTURE" > "$generated"
regenerated_t2=$(grub_t2_default "$generated")
[[ "$regenerated_t2" == "$expected" ]] || {
  printf 'FAIL: regenerated menu has T2 path %q, expected %q\n' "$regenerated_t2" "$expected" >&2
  exit 1
}
grub_default_matches "$expected" "$generated" || {
  printf 'FAIL: generated set default does not match the PVE T2 entry.\n' >&2
  exit 1
}

printf 'PASS: PVE distributor menu selects the non-recovery T2 entry with GRUB_TIMEOUT=10.\n'
