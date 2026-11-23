#!/bin/sh
# Runs as display.d/09t2guard before Debian's 10initial_auto chooses and writes
# the globally largest free partition area.

reject() {
  reason=$1
  logger -t partman-t2-guard "REFUSING automatic partitioning: $reason" 2>/dev/null || true
  printf 'T2 partition safety guard: %s\nNo disk has been partitioned. Return to the installer menu, correct the disk layout, and retry.\n' "$reason" >&2
  exit 255
}

# The hook is revisited when the installer returns to partman after the first
# automatic pass. That pass has already created this marker; only guard before
# the first autopartition attempt.
partman_state_dir=${T2_PARTMAN_STATE_DIR:-/var/lib/partman}
if [ -f "$partman_state_dir/initial_auto" ]; then
  exit 0
fi

target_disk=/dev/nvme0n1
partman_root=${T2_PARTMAN_ROOT:-}
if [ -n "$partman_root" ]; then
  partman_lib="$partman_root/lib/partman/lib"
  partman_choices="$partman_root/lib/partman/automatically_partition/20biggest_free/choices"
else
  partman_lib=/lib/partman/lib
  partman_choices=/lib/partman/automatically_partition/20biggest_free/choices
fi

if [ ! -r "$partman_lib/base.sh" ] || [ ! -r "$partman_lib/recipes.sh" ]; then
  reject 'Debian partman libraries are not available; automatic partitioning was stopped.'
fi
. "$partman_lib/base.sh" || reject 'could not load Debian partman base functions.'
. "$partman_lib/recipes.sh" || reject 'could not load Debian partman recipe functions.'

if ! db_get partman-auto/disk || [ "$RET" != "$target_disk" ]; then
  reject "preseed target must be $target_disk. Check the target disk before retrying."
fi
if ! db_get partman-auto/init_automatically_partition || [ "$RET" != biggest_free ]; then
  reject 'expected Debian biggest_free partitioning; check the T2 preseed before retrying.'
fi
if db_get partman-auto/method && [ -n "$RET" ]; then
  reject 'partman-auto/method must remain unset so the guarded biggest_free flow is used.'
fi
if ! db_get partman-auto/choose_recipe || [ "$RET" != pve-final ]; then
  reject 'the pve-final partition recipe is not selected; automatic partitioning was stopped.'
fi

if [ ! -x "$partman_choices" ]; then
  reject 'Debian biggest_free selector is missing; automatic partitioning was stopped.'
fi
choice_output=$("$partman_choices") || reject 'Debian biggest_free could not inspect the available disk space.'
tab=$(printf '\t')
candidate=${choice_output%%"$tab"*}
if [ -z "$candidate" ] || [ "$candidate" = "$choice_output" ]; then
  reject 'Debian biggest_free found no usable free partition area.'
fi

selected_dir=${candidate%//*}
free_id=${candidate##*//}
if [ "$selected_dir" = "$candidate" ] || [ -z "$free_id" ] || [ ! -d "$selected_dir" ]; then
  reject 'Debian biggest_free returned an invalid free-space identifier.'
fi
if [ -n "${DEVICES:-}" ]; then
  case "$selected_dir" in
    "$DEVICES"/*) ;;
    *) reject 'Debian biggest_free returned a device outside its partman device list.' ;;
  esac
fi

selected_disk=$(cat "$selected_dir/device" 2>/dev/null || true)
selected_label=$(cat "$selected_dir/label" 2>/dev/null || true)
if [ "$selected_disk" != "$target_disk" ]; then
  reject "Debian biggest_free selected $selected_disk instead of $target_disk. Remove or resize other drives so the T2 NVMe is the largest-free target, then retry."
fi
if [ "$selected_label" != gpt ]; then
  reject "$target_disk is labeled '$selected_label', not GPT. Check the target layout before retrying."
fi

# Confirm the selected identifier is still free and get its exact byte size.
cd "$selected_dir" || reject 'could not enter the selected partman disk directory.'
open_dialog PARTITION_INFO "$free_id" || reject 'could not inspect the selected free partition area.'
read_line _part_num returned_id free_bytes _part_type free_fs _part_path _part_name || {
  close_dialog || true
  reject 'could not read the selected free partition area.'
}
close_dialog || reject 'could not close the partman partition query.'
if [ "$returned_id" != "$free_id" ] || [ "$free_fs" != free ]; then
  reject 'Debian biggest_free selection is no longer a free partition area.'
fi
case "$free_bytes" in
  ''|*[!0-9]*) reject 'Debian returned an invalid free-space size.' ;;
esac

# Decode the same preseeded recipe and mode that partman-auto's choose_recipe
# and perform_recipe use. The device directory is the current directory so
# $iflabel{ gpt } is handled by Debian's own decoder.
if ! db_get partman-auto/expert_recipe || [ -z "$RET" ]; then
  reject 'the pve-final expert recipe is missing; automatic partitioning was stopped.'
fi
recipe_file=$(mktemp /tmp/partman-t2-guard.XXXXXX) || reject 'could not stage the expert recipe for validation.'
trap 'rm -f "$recipe_file"' 0
trap 'reject "interrupted while validating the partition layout."' HUP INT TERM
printf '%s\n' "$RET" > "$recipe_file" || reject 'could not stage the expert recipe for validation.'
decode_recipe "$recipe_file" default reuse || reject 'Debian could not decode the pve-final recipe.'
filter_reused || reject 'Debian could not inspect the pve-final recipe.'
[ -n "$scheme" ] || reject 'the decoded pve-final recipe is empty.'

recipe_min_mb=$(min_size) || reject 'Debian could not calculate the recipe minimum size.'
case "$recipe_min_mb" in
  ''|*[!0-9]*) reject 'Debian returned an invalid recipe minimum size.' ;;
esac

# Calculate all finite expansion ahead of the final PV. Current pve-final has
# 512 MB of /boot headroom (1536 max minus 1024 min); partman consumes that
# before the final max=-1 PV receives remaining space. Keep this calculation
# driven by Debian's decoded recipe so future edits cannot silently under-size
# the pve VG.
expand_headroom_mb=0
lvm_count=0
lvm_last=no
lvm_valid=yes
unbounded_non_lvm=no
foreach_partition '
  part_min=$1
  part_factor=$2
  part_max=$3
  if echo "$*" | grep -Fq "method{ lvm }"; then
    lvm_count=$((lvm_count + 1))
    if [ "$last" = yes ]; then lvm_last=yes; fi
    if [ "$part_max" != -1 ] || [ "$part_factor" -gt "$part_min" ] ||
       ! echo "$*" | grep -Fq "vg_name{ pve }"; then
      lvm_valid=no
    fi
  elif [ "$part_max" = -1 ]; then
    if [ "$part_factor" -gt "$part_min" ]; then
      unbounded_non_lvm=yes
    fi
  elif [ "$part_factor" -gt "$part_min" ]; then
    expand_headroom_mb=$((expand_headroom_mb + part_max - part_min))
  fi
'
if [ "$lvm_count" -ne 1 ] || [ "$lvm_last" != yes ] || [ "$lvm_valid" != yes ] || [ "$unbounded_non_lvm" = yes ]; then
  reject 'pve-final must end with one unbounded pve PV and have no earlier unbounded expansion.'
fi
last_partition=$(printf '%s\n' "$scheme" | sed -n '$p')
set -- $last_partition
if [ "${3:-}" != -1 ]; then
  reject 'the final pve PV must have max=-1 so it receives remaining free space.'
fi

# Recipe sizes use decimal MB. Reserve 32 MiB (eight default 4 MiB LVM extents)
# for PV and thin-pool metadata/data, plus one 4 MiB extent for final-partition
# alignment. Earlier finite recipe growth is accounted separately above.
required_bytes=$((recipe_min_mb * 1000000 + expand_headroom_mb * 1000000 + 37748736))
if ! longint_le "$required_bytes" "$free_bytes"; then
  reject "largest free area on $target_disk is ${free_bytes} bytes; pve-final needs ${recipe_min_mb} MB minimum plus ${expand_headroom_mb} MB finite growth and 36 MiB for the final pve PV. Free more space or review the disk layout, then retry."
fi

logger -t partman-t2-guard "PASS: biggest_free targets $target_disk with ${free_bytes} bytes; recipe minimum=${recipe_min_mb} MB, finite growth=${expand_headroom_mb} MB, pve reserve=36 MiB" 2>/dev/null || true
exit 0
