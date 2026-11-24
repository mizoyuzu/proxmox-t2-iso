#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
BIN="$TEST_ROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
route_dev=${PVE_TEST_ROUTE_DEV:-enp2s0}
route_ip=${PVE_TEST_ROUTE_IP:-192.0.2.25}
case "$*" in
  '-4 route get 1.1.1.1') printf '1.1.1.1 via 192.0.2.1 dev %s src %s uid 0\n' "$route_dev" "$route_ip" ;;
  '-4 route show default') printf 'default via 192.0.2.1 dev %s proto dhcp src %s metric 100\n' "$route_dev" "$route_ip" ;;
  '-o -4 addr show dev '*)
    [[ ${PVE_TEST_NO_VM_ADDR:-0} == 1 ]] && exit 0
    printf '2: %s inet %s/24 scope global dynamic %s\n' "${6:-$route_dev}" "$route_ip" "${6:-$route_dev}"
    ;;
  *) printf 'unexpected ip args: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
cat > "$BIN/ifquery" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=${PVE_NETWORK_TEST_ROOT:?}
printf '%s\n' "$*" >> "$root/ifquery.log"
case "${1:-}" in
  -i)
    file=${2:?}; iface=${3:?}
    [[ $iface == vmbr0 ]] && grep -Eq '^[[:space:]]*iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+dhcp' "$file"
    ;;
  vmbr0)
    grep -Eq '^[[:space:]]*iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+dhcp' "$root/etc/network/interfaces"
    ;;
  --list)
    if grep -Eq '^[[:space:]]*iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+dhcp' "$root/etc/network/interfaces"; then
      printf 'lo\nvmbr0\n'
    else
      printf 'lo\n'
    fi
    ;;
  *) printf 'unexpected ifquery args: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
chmod 0755 "$BIN/ip" "$BIN/ifquery"

new_root() {
  local name=$1 root
  root=$TEST_ROOT/$name
  mkdir -p "$root/etc/network/interfaces.d" "$root/sys/class/net/enp1s0/device" "$root/sys/class/net/enp2s0/device"
  printf 'auto lo\niface lo inet loopback\n\nallow-hotplug enp1s0 enp2s0\niface enp1s0 inet dhcp\n    metric 100\niface enp2s0 inet dhcp\n    metric 200\n\nsource /etc/network/interfaces.d/*\n\nauto eth9\niface eth9 inet manual\n' > "$root/etc/network/interfaces"
  printf '127.0.0.1 localhost\n192.0.2.10 pve-mbp.local pve-mbp\n' > "$root/etc/hosts"
  printf '02:00:00:00:00:01\n' > "$root/sys/class/net/enp1s0/address"
  printf '02:00:00:00:00:02\n' > "$root/sys/class/net/enp2s0/address"
}

run_configure() {
  env PATH="$BIN:$PATH" PVE_NETWORK_TEST_ROOT="$1" PVE_TEST_ROUTE_DEV="$2" PVE_TEST_ROUTE_IP="$3" \
    PVE_IP_BIN="$BIN/ip" PVE_IFQUERY_BIN="$BIN/ifquery" "$ROOT/scripts/configure-pve-network.sh"
}

# Two NICs are present; select the one owning the usable default route.
new_root routed
output=$(run_configure "$TEST_ROOT/routed" enp2s0 192.0.2.25)
[[ $output == 'enp2s0 192.0.2.25' ]]
grep -Fxq 'iface enp2s0 inet manual' "$TEST_ROOT/routed/etc/network/interfaces"
! grep -Eq '^iface enp2s0 inet dhcp' "$TEST_ROOT/routed/etc/network/interfaces"
grep -Fxq 'iface enp1s0 inet dhcp' "$TEST_ROOT/routed/etc/network/interfaces"
grep -Fxq 'iface eth9 inet manual' "$TEST_ROOT/routed/etc/network/interfaces"
grep -Fxq '    bridge-ports enp2s0' "$TEST_ROOT/routed/etc/network/interfaces"
grep -Fxq 'vmbr0' <(env PATH="$BIN:$PATH" PVE_NETWORK_TEST_ROOT="$TEST_ROOT/routed" "$BIN/ifquery" --list)
grep -Fq -- '-i ' "$TEST_ROOT/routed/ifquery.log"
test -f "$TEST_ROOT/routed/etc/network/interfaces.first-boot-proxmox.bak"

# Rerun after the bridge has its lease and refresh /etc/hosts to the new address.
mkdir -p "$TEST_ROOT/routed/sys/class/net/vmbr0/brif/enp2s0"
printf '02:00:00:00:00:02\n' > "$TEST_ROOT/routed/sys/class/net/vmbr0/address"
printf 'pve-mbp\n' > "$TEST_ROOT/routed/etc/hostname"
mkdir -p "$TEST_ROOT/routed/var/lib"
touch "$TEST_ROOT/routed/var/lib/first-boot-proxmox.done"
before=$(cat "$TEST_ROOT/routed/etc/network/interfaces")
output=$(run_configure "$TEST_ROOT/routed" vmbr0 192.0.2.99)
[[ $output == 'enp2s0 192.0.2.99' ]]
[[ $(cat "$TEST_ROOT/routed/etc/network/interfaces") == "$before" ]]
env PATH="$BIN:$PATH" PVE_MANAGEMENT_TEST_ROOT="$TEST_ROOT/routed" PVE_TEST_ROUTE_IP=192.0.2.99 \
  PVE_IP_BIN="$BIN/ip" "$ROOT/scripts/sync-pve-mbp-hosts.sh" >/dev/null
grep -Fxq '192.0.2.99 pve-mbp.local pve-mbp' "$TEST_ROOT/routed/etc/hosts"
! grep -q '^192\.0\.2\.10 .*pve-mbp' "$TEST_ROOT/routed/etc/hosts"
cp "$TEST_ROOT/routed/etc/hosts" "$TEST_ROOT/routed/hosts.before-timeout"
env PATH="$BIN:$PATH" PVE_MANAGEMENT_TEST_ROOT="$TEST_ROOT/routed" PVE_TEST_NO_VM_ADDR=1 PVE_HOST_SYNC_WAIT_SECONDS=0 PVE_HOST_SYNC_POLL_SECONDS=1 \
  PVE_IP_BIN="$BIN/ip" "$ROOT/scripts/sync-pve-mbp-hosts.sh" >/dev/null 2>&1
cmp -s "$TEST_ROOT/routed/hosts.before-timeout" "$TEST_ROOT/routed/etc/hosts"
printf 'pve-renamed\n' > "$TEST_ROOT/routed/etc/hostname"
cp "$TEST_ROOT/routed/etc/hosts" "$TEST_ROOT/routed/hosts.before-rename"
env PATH="$BIN:$PATH" PVE_MANAGEMENT_TEST_ROOT="$TEST_ROOT/routed" PVE_TEST_ROUTE_IP=198.51.100.15 \
  PVE_IP_BIN="$BIN/ip" "$ROOT/scripts/sync-pve-mbp-hosts.sh" 198.51.100.15 >/dev/null 2>&1
cmp -s "$TEST_ROOT/routed/hosts.before-rename" "$TEST_ROOT/routed/etc/hosts"
printf 'pve-mbp\n' > "$TEST_ROOT/routed/etc/hostname"

# Migrate the exact previous interfaces.d stanza and keep its live bridge MAC.
new_root legacy
mkdir -p "$TEST_ROOT/legacy/sys/class/net/vmbr0/brif/enp2s0"
printf '02:00:00:00:00:02\n' > "$TEST_ROOT/legacy/sys/class/net/vmbr0/address"
printf 'auto vmbr0\niface vmbr0 inet dhcp\n    bridge-ports enp2s0\n    bridge-stp off\n    bridge-fd 0\n' > "$TEST_ROOT/legacy/etc/network/interfaces.d/vmbr0"
run_configure "$TEST_ROOT/legacy" enp2s0 192.0.2.25 >/dev/null
grep -Fxq '    hwaddress ether 02:00:00:00:00:02' "$TEST_ROOT/legacy/etc/network/interfaces"
test ! -e "$TEST_ROOT/legacy/etc/network/interfaces.d/vmbr0"
test -f "$TEST_ROOT/legacy/etc/network/interfaces.d-vmbr0.first-boot-proxmox.bak"

# A configured custom bridge and the internal T2 NCM interface fail safely.
new_root custom
printf '\nauto vmbr0\niface vmbr0 inet static\n    address 192.0.2.77/24\n    bridge-ports enp1s0\n' >> "$TEST_ROOT/custom/etc/network/interfaces"
cp "$TEST_ROOT/custom/etc/network/interfaces" "$TEST_ROOT/custom/before"
if run_configure "$TEST_ROOT/custom" enp2s0 192.0.2.25 >/dev/null 2>&1; then
  printf 'FAIL: accepted a custom vmbr0 stanza.\n' >&2
  exit 1
fi
cmp -s "$TEST_ROOT/custom/before" "$TEST_ROOT/custom/etc/network/interfaces"

new_root internal
mkdir -p "$TEST_ROOT/internal/sys/class/net/enp3s0/device"
printf 'ac:de:48:00:11:22\n' > "$TEST_ROOT/internal/sys/class/net/enp3s0/address"
cp "$TEST_ROOT/internal/etc/network/interfaces" "$TEST_ROOT/internal/before"
if run_configure "$TEST_ROOT/internal" enp3s0 198.51.100.8 >/dev/null 2>&1; then
  printf 'FAIL: accepted a T2 internal NCM interface as the uplink.\n' >&2
  exit 1
fi
cmp -s "$TEST_ROOT/internal/before" "$TEST_ROOT/internal/etc/network/interfaces"

# Readiness is scoped to the current boot and checks vmbr0, name resolution,
# SSH, PVE services, local-lvm and HTTPS reachability after a reboot.
mkdir -p "$TEST_ROOT/routed/var/lib" "$TEST_ROOT/routed/proc/sys/kernel/random"
printf 'old-boot\n' > "$TEST_ROOT/routed/var/lib/first-boot-proxmox.staged-boot-id"
printf 'awaiting-reboot old-boot\n' > "$TEST_ROOT/routed/var/lib/first-boot-proxmox.status"
printf 'new-boot\n' > "$TEST_ROOT/routed/proc/sys/kernel/random/boot_id"
printf '#!/usr/bin/env bash\n[[ $1 == is-active && $2 == --quiet ]] && exit 0\nexit 2\n' > "$BIN/systemctl"
printf '#!/usr/bin/env bash\nprintf "Name Type Status Total Used Available\\nlocal-lvm lvmthin active 100 1 99\\n"\n' > "$BIN/pvesm"
printf '#!/usr/bin/env bash\n[[ " $* " == *" https://127.0.0.1:8006/ "* ]] && [[ " $* " == *" --insecure "* ]]\n' > "$BIN/curl"
printf '#!/usr/bin/env bash\nprintf "192.0.2.99 STREAM pve-mbp\\n"\n' > "$BIN/getent"
chmod 0755 "$BIN/systemctl" "$BIN/pvesm" "$BIN/curl" "$BIN/getent"
env PATH="$BIN:$PATH" PVE_MANAGEMENT_TEST_ROOT="$TEST_ROOT/routed" PVE_IP_BIN="$BIN/ip" \
  PVE_SYSTEMCTL_BIN="$BIN/systemctl" PVE_STORAGE_BIN="$BIN/pvesm" PVE_CURL_BIN="$BIN/curl" PVE_GETENT_BIN="$BIN/getent" \
  PVE_TEST_ROUTE_DEV=vmbr0 PVE_TEST_ROUTE_IP=192.0.2.99 "$ROOT/scripts/verify-pve-management-ready.sh" >/dev/null
grep -Fxq 'ready new-boot 192.0.2.99' "$TEST_ROOT/routed/var/lib/first-boot-proxmox.status"

# A later boot without vmbr0 must replace the old ready result with its failure.
printf 'later-boot\n' > "$TEST_ROOT/routed/proc/sys/kernel/random/boot_id"
if env PATH="$BIN:$PATH" PVE_MANAGEMENT_TEST_ROOT="$TEST_ROOT/routed" PVE_IP_BIN="$BIN/ip" \
  PVE_SYSTEMCTL_BIN="$BIN/systemctl" PVE_STORAGE_BIN="$BIN/pvesm" PVE_CURL_BIN="$BIN/curl" PVE_GETENT_BIN="$BIN/getent" \
  PVE_TEST_ROUTE_DEV=enp2s0 PVE_TEST_ROUTE_IP=192.0.2.99 "$ROOT/scripts/verify-pve-management-ready.sh" >/dev/null 2>&1; then
  printf 'FAIL: kept stale ready state after a boot without vmbr0.\n' >&2
  exit 1
fi
grep -Fxq 'not-ready later-boot' "$TEST_ROOT/routed/var/lib/first-boot-proxmox.status"

grep -Fq 'ExecStartPre=/usr/local/sbin/sync-pve-mbp-hosts.sh' "$ROOT/scripts/pve-cluster-hosts-sync.conf"
if grep -Fq 'pvecm updatecerts --force' "$ROOT/scripts"/pve-* 2>/dev/null; then
  printf 'FAIL: a management script forces PVE certificate regeneration.\n' >&2
  exit 1
fi

printf 'PASS: wired-route selection, PVE-managed bridge migration/reread, DHCP IP refresh, and post-reboot readiness\n'
