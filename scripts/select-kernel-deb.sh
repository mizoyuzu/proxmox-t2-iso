#!/usr/bin/env bash
# Select one installable kernel image package, preferring the PVE T2 build.
set -euo pipefail

if [[ $# -ne 1 || ! -d $1 ]]; then
  printf 'usage: %s KERNEL_DEB_DIR\n' "$0" >&2
  exit 2
fi

deb_dir=$(cd -- "$1" && pwd -P)
shopt -s nullglob
pve_candidates=()
legacy_candidates=()

for deb in "$deb_dir"/proxmox-kernel-*-pve-t2_*.deb; do
  [[ -f $deb ]] || continue
  package=$(dpkg-deb -f "$deb" Package)
  if [[ $package =~ ^proxmox-kernel-[0-9][A-Za-z0-9.+~:-]*-pve-t2$ ]] &&
     [[ ! $package =~ (headers|signed-template|meta) ]]; then
    pve_candidates+=("$deb")
  fi
done

if (( ${#pve_candidates[@]} > 0 )); then
  candidates=("${pve_candidates[@]}")
else
  for deb in "$deb_dir"/linux-image-*.deb; do
    [[ -f $deb ]] || continue
    package=$(dpkg-deb -f "$deb" Package)
    if [[ $package =~ ^linux-image-[0-9][A-Za-z0-9.+~:-]*$ ]] &&
       [[ ! $package =~ (headers|signed-template|meta|dbg|unsigned)$ ]]; then
      legacy_candidates+=("$deb")
    fi
  done
  candidates=("${legacy_candidates[@]}")
fi

if (( ${#candidates[@]} != 1 )); then
  printf 'ERROR: expected exactly one usable kernel image deb (PVE T2 preferred, legacy linux-image fallback), found %d\n' \
    "${#candidates[@]}" >&2
  printf 'Candidates: %s\n' "${candidates[*]:-none}" >&2
  exit 1
fi

printf '%s\n' "${candidates[0]}"
