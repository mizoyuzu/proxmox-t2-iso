#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER=$ROOT/scripts/disable-pve-enterprise-source.sh
FIXTURE=$ROOT/tests/fixtures/pve-manager-9.2.32-pve-enterprise.sources
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

source_dir=$TEST_ROOT/sources.list.d
mkdir -p "$source_dir"
cp "$FIXTURE" "$source_dir/pve-enterprise.sources"
cat > "$source_dir/proxmox.sources" <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
cat > "$source_dir/custom.sources" <<'EOF'
Types: deb
URIs: https://packages.example.invalid/debian
Suites: stable
Components: main
EOF
printf '%s\n' 'deb https://enterprise.proxmox.com/debian/pve trixie pve-enterprise' > "$source_dir/pve-enterprise.list"

PVE_APT_SOURCES_DIR=$source_dir "$HELPER"
grep -qx 'Enabled: no' "$source_dir/pve-enterprise.sources"
cmp -s "$source_dir/proxmox.sources" <(cat <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
)
cmp -s "$source_dir/custom.sources" <(cat <<'EOF'
Types: deb
URIs: https://packages.example.invalid/debian
Suites: stable
Components: main
EOF
)
[[ $(cat "$source_dir/pve-enterprise.list") == 'deb https://enterprise.proxmox.com/debian/pve trixie pve-enterprise' ]]

cp "$source_dir/pve-enterprise.sources" "$TEST_ROOT/disabled.once"
PVE_APT_SOURCES_DIR=$source_dir "$HELPER"
cmp -s "$TEST_ROOT/disabled.once" "$source_dir/pve-enterprise.sources"

# A canonical filename alone is not enough to touch unrelated repository data.
cat > "$source_dir/pve-enterprise.sources" <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/ceph-squid
Suites: trixie
Components: ceph-enterprise
EOF
cp "$source_dir/pve-enterprise.sources" "$TEST_ROOT/unrelated.before"
PVE_APT_SOURCES_DIR=$source_dir "$HELPER"
cmp -s "$TEST_ROOT/unrelated.before" "$source_dir/pve-enterprise.sources"

# Malformed deb822 at the package path fails closed and remains unmodified.
printf '  orphaned continuation\nTypes: deb\n' > "$source_dir/pve-enterprise.sources"
cp "$source_dir/pve-enterprise.sources" "$TEST_ROOT/malformed.before"
if PVE_APT_SOURCES_DIR=$source_dir "$HELPER"; then
  printf 'FAIL: malformed canonical deb822 source was accepted.\n' >&2
  exit 1
fi
cmp -s "$TEST_ROOT/malformed.before" "$source_dir/pve-enterprise.sources"

printf 'PASS: disables only the PVE enterprise deb822 stanza, idempotently; leaves unrelated and legacy sources unchanged\n'
