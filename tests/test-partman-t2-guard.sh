#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE="$ROOT/tests/fixtures/partman-t2-guard"
GUARD="$ROOT/scripts/partman-t2-guard.sh"
WORK=$(mktemp -d /tmp/partman-t2-guard-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

PARTMAN_ROOT="$WORK/partman"
DEVICES="$PARTMAN_ROOT/devices"
TARGET_DIR="$DEVICES/=dev=nvme0n1"
OTHER_DIR="$DEVICES/=dev=sda"
STATE_DIR="$WORK/state"
mkdir -p "$PARTMAN_ROOT" "$TARGET_DIR" "$OTHER_DIR" "$STATE_DIR"
cp -R "$FIXTURE/." "$PARTMAN_ROOT/"
chmod 0755 "$PARTMAN_ROOT/lib/partman/automatically_partition/20biggest_free/choices"
printf '%s\n' /dev/nvme0n1 > "$TARGET_DIR/device"
printf '%s\n' gpt > "$TARGET_DIR/label"
printf '%s\n' /dev/sda > "$OTHER_DIR/device"
printf '%s\n' gpt > "$OTHER_DIR/label"

run_guard() {
  T2_PARTMAN_ROOT="$PARTMAN_ROOT" T2_PARTMAN_STATE_DIR="$STATE_DIR" \
    PARTMAN_DEVICE_DIR="$1" PARTMAN_FREE_ID=free PARTMAN_FREE_BYTES="$2" \
    "$GUARD" > "$WORK/output" 2>&1
}

if run_guard "$OTHER_DIR" 40000000000; then
  echo "FAIL: guard accepted the global biggest_free candidate on /dev/sda" >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 255 ] || { cat "$WORK/output" >&2; echo "FAIL: wrong-disk guard exit was $status, expected 255" >&2; exit 1; }
grep -q 'selected /dev/sda instead of /dev/nvme0n1' "$WORK/output"
grep -q 'No disk has been partitioned' "$WORK/output"

# pve-final has 26,113 MB minimum plus 512 MB /boot growth and a 36 MiB PV reserve.
if run_guard "$TARGET_DIR" 26662748735; then
  echo "FAIL: guard accepted an area without the required final PV reserve" >&2
  exit 1
else
  status=$?
fi
[ "$status" -eq 255 ] || { cat "$WORK/output" >&2; echo "FAIL: size guard exit was $status, expected 255" >&2; exit 1; }
grep -q '512 MB finite growth and 36 MiB for the final pve PV' "$WORK/output"

if ! run_guard "$TARGET_DIR" 26662748736; then
  cat "$WORK/output" >&2
  echo "FAIL: guard rejected the exact recipe fit, expansion, and reserve fixture" >&2
  exit 1
fi

echo "PASS: guard exits 255 on wrong-device or undersized candidates; accepts the safe target fixture"
