#!/usr/bin/env bash
# Stage only the installer-required modules from an extracted kernel package.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  printf 'usage: %s KERNEL_EXTRACT KVER INITRD_ROOT\n' "$0" >&2
  exit 2
fi

KEX=$(cd -- "$1" && pwd -P)
KVER=$2
INITRD_DIR=$3
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
MODULE_LIST=${T2_INSTALLER_MODULE_LIST:-$SCRIPT_DIR/installer-modules.txt}
SOURCE_MODULES="$KEX/lib/modules/$KVER"
(( ${#KVER} > 0 )) || { echo 'ERROR: empty kernel version' >&2; exit 1; }
[[ -d $SOURCE_MODULES ]] || { echo "ERROR: missing kernel modules: $SOURCE_MODULES" >&2; exit 1; }
[[ -r $MODULE_LIST ]] || { echo "ERROR: missing module list: $MODULE_LIST" >&2; exit 1; }
for tool in modprobe depmod; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required command not found: $tool" >&2; exit 1; }
done

# Ensure modprobe has a dependency database for the extracted package.
depmod -b "$KEX" "$KVER"
rm -rf -- "$INITRD_DIR/lib/modules"
mkdir -p "$INITRD_DIR/lib/modules/$KVER"

while IFS= read -r metadata; do
  [[ -f "$SOURCE_MODULES/$metadata" ]] && cp -a -- "$SOURCE_MODULES/$metadata" "$INITRD_DIR/lib/modules/$KVER/"
done <<'EOF'
modules.builtin
modules.builtin.modinfo
EOF

module_paths=$(mktemp)
trap 'rm -f "$module_paths"' EXIT
while IFS= read -r module || [[ -n $module ]]; do
  module=${module%%#*}
  module=$(printf '%s' "$module" | tr -d '[:space:]')
  [[ -n $module ]] || continue
  output=$(modprobe --show-depends -d "$KEX" -S "$KVER" "$module") || {
    echo "ERROR: cannot resolve installer module: $module" >&2
    exit 1
  }
  while IFS= read -r path; do
    [[ -n $path ]] && printf '%s\n' "$path" >> "$module_paths"
  done < <(awk '$1 == "insmod" { print $2 }' <<< "$output")
done < "$MODULE_LIST"

sort -u -o "$module_paths" "$module_paths"
if [[ ! -s $module_paths ]]; then
  echo 'ERROR: no loadable installer modules resolved' >&2
  exit 1
fi

while IFS= read -r module_path; do
  case "$module_path" in
    "/lib/modules/$KVER/"*) ;;
    *) echo "ERROR: modprobe returned an unexpected module path: $module_path" >&2; exit 1 ;;
  esac
  source_path="$KEX$module_path"
  target_path="$INITRD_DIR$module_path"
  [[ -f $source_path ]] || { echo "ERROR: resolved module is absent: $source_path" >&2; exit 1; }
  mkdir -p -- "$(dirname -- "$target_path")"
  cp -a -- "$source_path" "$target_path"
done < "$module_paths"

depmod -b "$INITRD_DIR" "$KVER"
while IFS= read -r module || [[ -n $module ]]; do
  module=${module%%#*}
  module=$(printf '%s' "$module" | tr -d '[:space:]')
  [[ -n $module ]] || continue
  modprobe --show-depends -d "$INITRD_DIR" -S "$KVER" "$module" >/dev/null || {
    echo "ERROR: staged initrd cannot resolve installer module: $module" >&2
    exit 1
  }
done < "$MODULE_LIST"

staged_count=$(find "$INITRD_DIR/lib/modules/$KVER" -type f \( -name '*.ko' -o -name '*.ko.*' \) | wc -l)
(( staged_count > 0 )) || { echo 'ERROR: no kernel modules were staged' >&2; exit 1; }
printf 'Staged %s module files for %s\n' "$staged_count" "$KVER"
