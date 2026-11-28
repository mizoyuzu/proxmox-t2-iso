#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
STAGE="$ROOT/scripts/stage-installer-modules.sh"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"

cat > "$BIN/depmod" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$BIN/modprobe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == --show-depends ]] || exit 2
shift
root=
kver=
module=
while (($#)); do
  case "$1" in
    -d) root=${2:?}; shift 2 ;;
    -S) kver=${2:?}; shift 2 ;;
    *) module=$1; shift ;;
  esac
done
[[ $module == fake && -n $root && -n $kver ]]
if [[ $root == "$T2_TEST_KEX" ]]; then
  case "$T2_TEST_MODE" in
    usrmerge-prefixed) path="$root/lib/modules/$kver/kernel/drivers/fake.ko" ;;
    usrmerge-resolved) path="$root/usr/lib/modules/$kver/kernel/drivers/fake.ko" ;;
    legacy) path="/lib/modules/$kver/kernel/drivers/fake.ko" ;;
    unexpected) path=/opt/elsewhere/fake.ko ;;
    *) exit 3 ;;
  esac
else
  path="/lib/modules/$kver/kernel/drivers/fake.ko"
fi
printf 'insmod %s\n' "$path"
EOF
chmod 0755 "$BIN/depmod" "$BIN/modprobe"

make_case() {
  local name=$1 layout=$2 mode=$3
  local case_root="$WORK/$name"
  local kex="$case_root/kernel-extract"
  local initrd="$case_root/initrd"
  local kver=1.2.3-test
  local module_dir

  if [[ $layout == usrmerge ]]; then
    module_dir="$kex/usr/lib/modules/$kver"
    mkdir -p "$kex/lib"
    ln -s ../usr/lib/modules "$kex/lib/modules"
  else
    module_dir="$kex/lib/modules/$kver"
    mkdir -p "$module_dir"
  fi
  mkdir -p "$module_dir/kernel/drivers" "$initrd"
  printf 'fake module %s\n' "$name" > "$module_dir/kernel/drivers/fake.ko"
  : > "$module_dir/modules.builtin"
  : > "$module_dir/modules.builtin.modinfo"
  printf 'fake\n' > "$case_root/modules.txt"

  T2_TEST_KEX="$kex" T2_TEST_MODE="$mode" T2_INSTALLER_MODULE_LIST="$case_root/modules.txt" \
    PATH="$BIN:$PATH" "$STAGE" "$kex" "$kver" "$initrd" > "$case_root/output" 2>&1

  [[ -f "$initrd/lib/modules/$kver/kernel/drivers/fake.ko" ]]
  grep -Fxq "fake module $name" "$initrd/lib/modules/$kver/kernel/drivers/fake.ko"
  [[ ! -e "$initrd$kex" ]]
  [[ $(find "$initrd/lib/modules/$kver" -type f -name '*.ko' | wc -l | tr -d '[:space:]') == 1 ]]
}

make_case usrmerge-prefixed usrmerge usrmerge-prefixed
make_case usrmerge-resolved usrmerge usrmerge-resolved
make_case legacy legacy legacy

unexpected_root="$WORK/unexpected/kernel-extract"
unexpected_initrd="$WORK/unexpected/initrd"
unexpected_kver=1.2.3-test
mkdir -p "$unexpected_root/lib/modules/$unexpected_kver/kernel/drivers" "$unexpected_initrd"
: > "$unexpected_root/lib/modules/$unexpected_kver/kernel/drivers/fake.ko"
: > "$unexpected_root/lib/modules/$unexpected_kver/modules.builtin"
: > "$unexpected_root/lib/modules/$unexpected_kver/modules.builtin.modinfo"
printf 'fake\n' > "$WORK/unexpected/modules.txt"
if T2_TEST_KEX="$unexpected_root" T2_TEST_MODE=unexpected \
  T2_INSTALLER_MODULE_LIST="$WORK/unexpected/modules.txt" PATH="$BIN:$PATH" \
  "$STAGE" "$unexpected_root" "$unexpected_kver" "$unexpected_initrd" > "$WORK/unexpected/output" 2>&1; then
  echo 'FAIL: accepted a modprobe path outside the supported module roots.' >&2
  exit 1
fi
grep -Fq 'ERROR: modprobe returned an unexpected module path: /opt/elsewhere/fake.ko' \
  "$WORK/unexpected/output"

printf 'PASS: stages usrmerge-prefixed, usrmerge-resolved, and legacy module paths; rejects unexpected paths.\n'
