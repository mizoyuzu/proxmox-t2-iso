#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"

cat > "$BIN/id" <<'EOF'
#!/bin/sh
[ "${1:-}" = -u ] || exit 2
printf '0\n'
EOF
cat > "$BIN/lsblk" <<'EOF'
#!/bin/sh
case " $* " in
  *' -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT '*)
    printf 'NAME SIZE TYPE FSTYPE MOUNTPOINT\nnvme0n1 1T disk\n'
    ;;
  *' -dnpo NAME,TYPE '*)
    printf '/dev/nvme0n1 disk\n'
    ;;
  *)
    echo "unexpected lsblk arguments: $*" >&2
    exit 99
    ;;
esac
EOF
cat > "$BIN/blkid" <<'EOF'
#!/bin/sh
[ "$1" = -p ] && [ "$2" = -o ] && [ "$3" = value ] &&
  [ "$4" = -s ] && [ "$5" = TYPE ] && [ "$6" = /dev/nvme0n1 ] || {
    echo "unexpected blkid arguments: $*" >&2
    exit 99
  }
exit 2
EOF
cat > "$BIN/ip" <<'EOF'
#!/bin/sh
case " $* " in
  *' -o -4 addr show dev enx-test '*)
    printf '2: enx-test    inet 192.0.2.10/24 brd 192.0.2.255 scope global enx-test\n'
    ;;
  *' -4 route show default '*)
    printf 'default via 192.0.2.1 dev enx-test\n'
    ;;
  *) exit 0 ;;
esac
EOF
chmod 0755 "$BIN"/*

make_fixture() {
  local root=$1 secureboot=${2:-0} modules=${3:-1} wired=${4:-1}
  mkdir -p "$root/sys/class/dmi/id" "$root/sys/firmware/efi/efivars" \
    "$root/proc/bus/input" "$root/sys/class/nvme/nvme0" \
    "$root/sys/class/net/wlan0/wireless" "$root/lib/firmware"
  printf 'MacBookPro15,1\n' > "$root/sys/class/dmi/id/product_name"
  if [[ $secureboot == 1 ]]; then
    printf '\001\000\000\000\001' > "$root/sys/firmware/efi/efivars/SecureBoot-1234"
  else
    printf '\001\000\000\000\000' > "$root/sys/firmware/efi/efivars/SecureBoot-1234"
  fi
  if [[ $modules == 1 ]]; then
    mkdir -p "$root/sys/module/t2bce_core" "$root/sys/module/t2bce_vhci"
  else
    mkdir -p "$root/sys/module/t2bce_core"
  fi
  cat > "$root/proc/bus/input/devices" <<'EOF'
I: Bus=0018 Vendor=0000 Product=0000 Version=0000
N: Name="Apple Internal Keyboard / Trackpad"
H: Handlers=sysrq kbd event0

I: Bus=0018 Vendor=0000 Product=0000 Version=0000
N: Name="Apple Internal Trackpad"
H: Handlers=mouse0 event1

EOF
  if [[ $wired == 1 ]]; then
    mkdir -p "$root/sys/class/net/enx-test/device"
    printf '1\n' > "$root/sys/class/net/enx-test/carrier"
    ln -s ../../../../bus/usb/drivers/r8152 "$root/sys/class/net/enx-test/device/driver"
  fi
  printf '1\n' > "$root/sys/class/net/wlan0/carrier"
}

run_preflight() {
  local fixture=$1
  shift
  (
    cd "$fixture"
    env PATH="$BIN:$PATH" T2_PREFLIGHT_ROOT="$fixture" \
      "$ROOT/scripts/t2-hardware-preflight.sh" "$@"
  )
}

mkdir -p "$WORK/normal/root"
make_fixture "$WORK/normal/root"
if ! run_preflight "$WORK/normal/root" > "$WORK/normal.log" 2>&1; then
  cat "$WORK/normal.log" >&2
  echo 'FAIL: healthy T2 fixture should pass.' >&2
  exit 1
fi
grep -q '^PASS: DMI product_name is MacBookPro15,1' "$WORK/normal.log"
grep -q '^PASS: Required T2 module t2bce_core is loaded' "$WORK/normal.log"
grep -q '^PASS: Wired interface enx-test reports carrier=1' "$WORK/normal.log"
grep -q '^SUMMARY: PASS:' "$WORK/normal.log"
test ! -e "$WORK/normal/root/t2-hardware-preflight.txt"

mkdir -p "$WORK/no-modules/root"
make_fixture "$WORK/no-modules/root" 0 0
if run_preflight "$WORK/no-modules/root" > "$WORK/no-modules.log" 2>&1; then
  cat "$WORK/no-modules.log" >&2
  echo 'FAIL: fixture without both required T2 modules should fail.' >&2
  exit 1
fi
grep -q '^FAIL: Required T2 module t2bce_vhci is not loaded; try: modprobe t2bce_core t2bce_vhci' "$WORK/no-modules.log"
grep -q '^SUMMARY: FAIL:' "$WORK/no-modules.log"

mkdir -p "$WORK/wifi-only/root"
make_fixture "$WORK/wifi-only/root" 0 1 0
if run_preflight "$WORK/wifi-only/root" > "$WORK/wifi-only.log" 2>&1; then
  cat "$WORK/wifi-only.log" >&2
  echo 'FAIL: Wi-Fi-only fixture should fail the wired-network check.' >&2
  exit 1
fi
grep -q '^INFO: Ignoring wireless interface wlan0' "$WORK/wifi-only.log"
grep -q '^FAIL: No non-wireless network interface was found' "$WORK/wifi-only.log"

mkdir -p "$WORK/secureboot/root"
make_fixture "$WORK/secureboot/root" 1
if ! run_preflight "$WORK/secureboot/root" > "$WORK/secureboot.log" 2>&1; then
  cat "$WORK/secureboot.log" >&2
  echo 'FAIL: SecureBoot warning alone should not fail preflight.' >&2
  exit 1
fi
grep -q '^WARN: Secure Boot is enabled (SecureBoot efivar value 1)' "$WORK/secureboot.log"
grep -q '^SUMMARY: PASS:' "$WORK/secureboot.log"

mkdir -p "$WORK/report/root"
make_fixture "$WORK/report/root"
report_file="$WORK/report/preflight.txt"
if ! run_preflight "$WORK/report/root" --report "$report_file" > "$WORK/report.stdout" 2>&1; then
  cat "$WORK/report.stdout" >&2
  echo 'FAIL: --report run on healthy fixture should pass.' >&2
  exit 1
fi
test -s "$report_file"
grep -q '^SUMMARY: PASS:' "$report_file"
grep -q '^PASS: DMI product_name is MacBookPro15,1' "$WORK/report.stdout"
test ! -e "$WORK/no-report.txt"

echo 'PASS: hardware preflight checks T2 modules, wired Ethernet, SecureBoot warnings, and opt-in report output.'
