#!/usr/bin/env bash
# Mark management ready only after it has been observed on a later boot.
set -euo pipefail

# PVE_MANAGEMENT_TEST_ROOT is used only by the repository regression tests.
readonly ROOT=${PVE_MANAGEMENT_TEST_ROOT:-}
readonly STATE_DIR="${ROOT}/var/lib"
readonly STATUS_FILE="${STATE_DIR}/first-boot-proxmox.status"
readonly STAGED_BOOT_FILE="${STATE_DIR}/first-boot-proxmox.staged-boot-id"
readonly IP_BIN=${PVE_IP_BIN:-ip}
readonly CURL_BIN=${PVE_CURL_BIN:-curl}
readonly SYSTEMCTL_BIN=${PVE_SYSTEMCTL_BIN:-systemctl}
readonly STORAGE_BIN=${PVE_STORAGE_BIN:-pvesm}
readonly GETENT_BIN=${PVE_GETENT_BIN:-getent}

log() { printf '[verify-pve-management-ready] %s\n' "$*"; }
fail() {
  local boot_id=$1 reason=$2
  printf 'not-ready %s\n' "$boot_id" > "${STATUS_FILE}.tmp"
  mv -f -- "${STATUS_FILE}.tmp" "$STATUS_FILE"
  log "Not ready: ${reason}"
  exit 1
}

route_ip() {
  local route_line route_dev='' route_src='' token i
  route_line=$("$IP_BIN" -4 route get 1.1.1.1 2>/dev/null | head -n 1) || true
  [[ -n $route_line ]] || return 1
  read -r -a fields <<< "$route_line"
  for ((i=0; i<${#fields[@]}; i++)); do
    token=${fields[$i]}
    case "$token" in
      dev) (( i+1 < ${#fields[@]} )) && route_dev=${fields[$((i+1))]} ;;
      src) (( i+1 < ${#fields[@]} )) && route_src=${fields[$((i+1))]} ;;
    esac
  done
  [[ $route_dev == vmbr0 && $route_src =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  "$IP_BIN" -o -4 addr show dev vmbr0 scope global 2>/dev/null |
    awk -v wanted="$route_src" '{ split($4, address, "/"); if (address[1] == wanted) found=1 } END { exit !found }' || return 1
  printf '%s\n' "$route_src"
}

main() {
  local boot_id staged_boot current_status ip_addr status_tmp configured_hostname
  if [[ -n $ROOT ]]; then
    boot_id=$(cat "${ROOT}/proc/sys/kernel/random/boot_id")
  else
    boot_id=$(cat /proc/sys/kernel/random/boot_id)
  fi
  [[ -f $STATUS_FILE && -f $STAGED_BOOT_FILE ]] || { log 'No completed first-boot setup is staged yet.'; return 0; }
  configured_hostname=$(cat "${ROOT}/etc/hostname" 2>/dev/null || true)
  if [[ ${configured_hostname%%.*} != pve-mbp ]]; then
    printf 'not-applicable %s hostname-changed\n' "$boot_id" > "${STATUS_FILE}.tmp"
    mv -f -- "${STATUS_FILE}.tmp" "$STATUS_FILE"
    log "The node hostname is ${configured_hostname:-unknown}; skipping pve-mbp readiness checks."
    return 0
  fi
  staged_boot=$(cat "$STAGED_BOOT_FILE")
  current_status=$(cat "$STATUS_FILE")
  if [[ $boot_id == "$staged_boot" ]]; then
    log 'First-boot configuration is staged and awaits a reboot.'
    return 0
  fi
  if [[ $current_status == "ready ${boot_id} "* ]]; then
    log "Management readiness is current for boot ${boot_id}."
    return 0
  fi
  printf 'checking %s\n' "$boot_id" > "${STATUS_FILE}.tmp"
  mv -f -- "${STATUS_FILE}.tmp" "$STATUS_FILE"

  ip_addr=$(route_ip) || fail "$boot_id" 'vmbr0 has no active global IPv4 default-route source.'
  "$GETENT_BIN" ahostsv4 pve-mbp 2>/dev/null |
    awk -v wanted="$ip_addr" '$1 == wanted { found=1 } END { exit !found }' ||
    fail "$boot_id" "name resolution for pve-mbp does not include the vmbr0 lease ${ip_addr}."
  "$SYSTEMCTL_BIN" is-active --quiet ssh || fail "$boot_id" 'ssh.service is not active.'
  "$SYSTEMCTL_BIN" is-active --quiet pve-cluster || fail "$boot_id" 'pve-cluster.service is not active.'
  "$SYSTEMCTL_BIN" is-active --quiet pvedaemon || fail "$boot_id" 'pvedaemon.service is not active.'
  "$SYSTEMCTL_BIN" is-active --quiet pveproxy || fail "$boot_id" 'pveproxy.service is not active.'
  "$SYSTEMCTL_BIN" is-active --quiet pvestatd || fail "$boot_id" 'pvestatd.service is not active.'
  "$STORAGE_BIN" status 2>/dev/null | awk 'NR > 1 && $1 == "local-lvm" && $3 == "active" { found=1 } END { exit !found }' ||
    fail "$boot_id" 'local-lvm is not active.'
  "$CURL_BIN" --silent --show-error --insecure --fail --output /dev/null --max-time 10 https://127.0.0.1:8006/ ||
    fail "$boot_id" 'the local HTTPS management endpoint did not respond.'

  status_tmp="${STATUS_FILE}.tmp"
  printf 'ready %s %s\n' "$boot_id" "$ip_addr" > "$status_tmp"
  mv -f -- "$status_tmp" "$STATUS_FILE"
  log "SSH, vmbr0 (${ip_addr}), local-lvm, and the HTTPS endpoint were observed after reboot."
  log 'HTTPS reachability was checked without validating the certificate name against the current DHCP address.'
}

main "$@"
