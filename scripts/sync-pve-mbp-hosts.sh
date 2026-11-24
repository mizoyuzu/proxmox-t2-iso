#!/usr/bin/env bash
# Keep PVE's local hostname mapping aligned with the wired default-route lease.
set -euo pipefail

# PVE_MANAGEMENT_TEST_ROOT is used only by the repository regression tests.
readonly ROOT=${PVE_MANAGEMENT_TEST_ROOT:-}
readonly HOSTS_FILE="${ROOT}/etc/hosts"
readonly HOSTNAME_FILE="${ROOT}/etc/hostname"
readonly DONE_FILE="${ROOT}/var/lib/first-boot-proxmox.done"
readonly NET_CLASS="${ROOT}/sys/class/net"
readonly IP_BIN=${PVE_IP_BIN:-ip}
readonly WAIT_SECONDS=${PVE_HOST_SYNC_WAIT_SECONDS:-30}
readonly POLL_SECONDS=${PVE_HOST_SYNC_POLL_SECONDS:-2}

die() { printf '[sync-pve-mbp-hosts] ERROR: %s\n' "$*" >&2; exit 1; }

vmbr0_ip() {
  { "$IP_BIN" -o -4 addr show dev vmbr0 scope global 2>/dev/null || true; } |
    awk '$4 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\// { split($4, address, "/"); print address[1]; exit }'
}

main() {
  [[ -f $HOSTS_FILE ]] || die "${HOSTS_FILE} is missing."
  if [[ -f $HOSTNAME_FILE ]]; then
    local current_hostname
    read -r current_hostname < "$HOSTNAME_FILE" || true
    if [[ ${current_hostname%%.*} != pve-mbp ]]; then
      printf '[sync-pve-mbp-hosts] Hostname is now %s; leaving its hosts entries unchanged.\n' "${current_hostname:-unknown}" >&2
      return 0
    fi
  else
    printf '[sync-pve-mbp-hosts] No /etc/hostname is present; leaving hosts entries unchanged.\n' >&2
    return 0
  fi
  local ip_addr=${1:-}
  if [[ -z $ip_addr ]]; then
    # During package installation the bridge is not active yet. Do not block
    # those early pve-cluster starts; on later boots wait briefly for DHCP and
    # retain the last working hostname mapping if the bridge has no lease.
    [[ -f $DONE_FILE ]] || { printf '[sync-pve-mbp-hosts] First-boot setup is not complete; deferring to the wired DHCP lease.\n' >&2; return 0; }
    local elapsed=0
    while (( elapsed <= WAIT_SECONDS )); do
      ip_addr=$(vmbr0_ip)
      [[ -n $ip_addr ]] && break
      sleep "$POLL_SECONDS"
      elapsed=$((elapsed + POLL_SECONDS))
    done
    if [[ -z $ip_addr ]]; then
      printf '[sync-pve-mbp-hosts] vmbr0 has no global IPv4 lease after %s seconds; preserving the previous /etc/hosts mapping.\n' "$WAIT_SECONDS" >&2
      return 0
    fi
  fi
  [[ $ip_addr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "invalid IPv4 address: ${ip_addr}."

  local hosts_tmp
  hosts_tmp=$(mktemp "${HOSTS_FILE}.XXXXXX")
  awk '
    /^#/ { print; next }
    {
      output = $1
      for (i = 2; i <= NF; i++)
        if ($i != "pve-mbp" && $i != "pve-mbp.local") output = output " " $i
      if (output != "") print output
    }
  ' "$HOSTS_FILE" > "$hosts_tmp"
  chmod --reference="$HOSTS_FILE" "$hosts_tmp"
  chown --reference="$HOSTS_FILE" "$hosts_tmp"
  printf '%s pve-mbp.local pve-mbp\n' "$ip_addr" >> "$hosts_tmp"
  mv -f -- "$hosts_tmp" "$HOSTS_FILE"
  printf '[sync-pve-mbp-hosts] /etc/hosts now maps %s to pve-mbp.local and pve-mbp.\n' "$ip_addr"
  printf '%s\n' "$ip_addr"
}

main "$@"
