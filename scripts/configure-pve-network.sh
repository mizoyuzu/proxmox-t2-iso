#!/usr/bin/env bash
# Stage a PVE-managed vmbr0 on the wired device carrying the IPv4 default route.
set -euo pipefail

# PVE_NETWORK_TEST_ROOT is used only by the repository regression test harness.
readonly ROOT=${PVE_NETWORK_TEST_ROOT:-}
readonly NET_CLASS="${ROOT}/sys/class/net"
readonly NETWORK_DIR="${ROOT}/etc/network"
readonly INTERFACES_FILE="${NETWORK_DIR}/interfaces"
readonly INTERFACES_D="${NETWORK_DIR}/interfaces.d"
readonly BACKUP_FILE="${NETWORK_DIR}/interfaces.first-boot-proxmox.bak"
readonly OLD_BRIDGE_FILE="${INTERFACES_D}/vmbr0"
readonly OLD_BRIDGE_BACKUP="${NETWORK_DIR}/interfaces.d-vmbr0.first-boot-proxmox.bak"
readonly IP_BIN=${PVE_IP_BIN:-ip}
readonly IFQUERY_BIN=${PVE_IFQUERY_BIN:-ifquery}

log() { printf '[configure-pve-network] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

is_wired_physical_nic() {
  local nic=$1
  case "$nic" in en*|eth*) ;; *) return 1 ;; esac
  case "$nic" in lo|wl*|vmbr*|veth*|tap*|br*|docker*|t2bce*) return 1 ;; esac
  [[ -d "${NET_CLASS}/${nic}/device" ]] || return 1
  if [[ -r "${NET_CLASS}/${nic}/address" ]]; then
    local mac
    read -r mac < "${NET_CLASS}/${nic}/address" || true
    [[ ${mac,,} != ac:de:48:00:11:22 ]] || return 1
  fi
  return 0
}

has_ip() {
  "$IP_BIN" -o -4 addr show dev "$1" scope global 2>/dev/null |
    awk -v wanted="$2" '{ split($4, address, "/"); if (address[1] == wanted) found=1 } END { exit !found }'
}

bridge_port_in_file() {
  [[ -f $1 ]] || return 0
  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $1 == "iface" { in_vmbr = ($2 == "vmbr0"); next }
    in_vmbr && $1 == "bridge-ports" { if (NF == 2) print $2; exit }
  ' "$1"
}

resolve_vmbr0_port() {
  local path configured port='' sys_ports=()
  if [[ -d "${NET_CLASS}/vmbr0/brif" ]]; then
    for path in "${NET_CLASS}"/vmbr0/brif/*; do
      [[ -e $path ]] || continue
      port=${path##*/}
      is_wired_physical_nic "$port" && sys_ports+=("$port")
    done
  fi
  configured=$(bridge_port_in_file "$INTERFACES_FILE")
  [[ -n $configured ]] || configured=$(bridge_port_in_file "$OLD_BRIDGE_FILE")
  if (( ${#sys_ports[@]} > 1 )); then
    die 'vmbr0 has multiple wired physical ports; refusing to choose one automatically.'
  fi
  if (( ${#sys_ports[@]} == 1 )); then
    if [[ -n $configured && $configured != "${sys_ports[0]}" ]]; then
      die "active vmbr0 port ${sys_ports[0]} conflicts with configured port ${configured}."
    fi
    port=${sys_ports[0]}
  else
    port=$configured
  fi
  [[ -n $port ]] && is_wired_physical_nic "$port" ||
    die 'the IPv4 default route uses vmbr0, but its wired physical bridge port could not be resolved.'
  printf '%s\n' "$port"
}

selected_route() {
  local route_line defaults route_dev='' route_ip='' token i
  route_line=$("$IP_BIN" -4 route get 1.1.1.1 2>/dev/null | head -n 1) || true
  [[ -n $route_line ]] || die 'could not resolve a usable IPv4 route to the Internet.'
  read -r -a fields <<< "$route_line"
  for ((i=0; i<${#fields[@]}; i++)); do
    token=${fields[$i]}
    case "$token" in
      dev) (( i+1 < ${#fields[@]} )) && route_dev=${fields[$((i+1))]} ;;
      src) (( i+1 < ${#fields[@]} )) && route_ip=${fields[$((i+1))]} ;;
    esac
  done
  [[ $route_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'the selected IPv4 route has no valid source address.'
  defaults=$("$IP_BIN" -4 route show default 2>/dev/null || true)
  [[ -n $defaults ]] || die 'there is no IPv4 default route.'
  awk -v dev="$route_dev" '$1 == "default" { for (i=1; i<NF; i++) if ($i == "dev" && $(i+1) == dev) found=1 } END { exit !found }' <<< "$defaults" ||
    die "the selected route device ${route_dev} does not own an IPv4 default route."
  has_ip "$route_dev" "$route_ip" || die "route source ${route_ip} is not configured on ${route_dev}."

  if [[ $route_dev == vmbr0 ]]; then
    SELECTED_NIC=$(resolve_vmbr0_port)
  else
    is_wired_physical_nic "$route_dev" || die "default route uses ${route_dev}, not a wired physical Ethernet device."
    SELECTED_NIC=$route_dev
  fi
  SELECTED_IP=$route_ip
}

# Accept only the exact old generated file or the normal main-file PVE bridge
# stanza. A custom vmbr0 is left alone and reported instead of overwritten.
bridge_is_compatible() {
  local file=$1 expected_nic=$2 old_style=${3:-0}
  [[ -f $file ]] || return 1
  awk -v nic="$expected_nic" -v old_style="$old_style" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $1 == "auto" && $2 == "vmbr0" { if (NF != 2) bad=1; auto_seen++; next }
    $1 == "iface" && $2 == "vmbr0" { if ($3 != "inet" || $4 != "dhcp" || NF != 4) bad=1; iface_seen++; in_vmbr=1; next }
    $1 == "iface" { if (in_vmbr) in_vmbr=0 }
    in_vmbr && $0 !~ /^[[:space:]]/ { in_vmbr=0 }
    in_vmbr && $1 == "bridge-ports" { if (NF != 2 || $2 != nic) bad=1; ports_seen++; next }
    in_vmbr && $1 == "bridge-stp" { if (NF != 2 || $2 != "off") bad=1; stp_seen++; next }
    in_vmbr && $1 == "bridge-fd" { if (NF != 2 || $2 != "0") bad=1; fd_seen++; next }
    in_vmbr && $1 == "hwaddress" {
      if (old_style || NF != 3 || $2 != "ether" || $3 !~ /^([[:xdigit:]][[:xdigit:]]:){5}[[:xdigit:]][[:xdigit:]]$/) bad=1
      next
    }
    in_vmbr { bad=1 }
    END { exit (bad || auto_seen != 1 || iface_seen != 1 || ports_seen != 1 || stp_seen != 1 || fd_seen != 1) }
  ' "$file"
}

bridge_mac() {
  local mac
  [[ -r ${NET_CLASS}/vmbr0/address ]] || return 0
  read -r mac < "${NET_CLASS}/vmbr0/address" || true
  [[ $mac =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] && printf '%s\n' "$mac"
}

nic_stanza_is_safe() {
  local nic=$1
  awk -v nic="$nic" '
    $1 == "iface" && $2 == nic && $3 == "inet" && $4 != "dhcp" && $4 != "manual" { bad=1 }
    $1 == "iface" && $2 == nic && $3 == "inet6" { bad=1 }
    END { exit bad }
  ' "$INTERFACES_FILE"
}

write_candidate() {
  local output=$1 nic=$2 mac=$3
  awk -v nic="$nic" '
    function flush_manual() { if (manual_needed) print "iface " nic " inet manual"; manual_needed=0 }
    {
      if (in_nic_dhcp && $0 !~ /^[[:space:]]/ && $0 !~ /^[[:space:]]*$/ && $0 !~ /^#/) {
        in_nic_dhcp=0
      }
      if (in_nic_dhcp) next
      if (($1 == "auto" || $1 == "allow-hotplug") && NF > 1) {
        line=$1; removed=0
        for (i=2; i<=NF; i++) { if ($i == nic) removed=1; else line=line " " $i }
        if (removed) { flush_manual(); if (line == $1) next; print line; next }
      }
      if ($1 == "iface" && $2 == nic && $3 == "inet" && $4 == "dhcp") {
        in_nic_dhcp=1; manual_needed=1; next
      }
      flush_manual()
      print
    }
    END { flush_manual() }
  ' "$INTERFACES_FILE" > "$output"

  if ! grep -Eq '^[[:space:]]*iface[[:space:]]+vmbr0[[:space:]]' "$INTERFACES_FILE"; then
    {
      printf '\n# first-boot-proxmox: management bridge\nauto vmbr0\niface vmbr0 inet dhcp\n    bridge-ports %s\n    bridge-stp off\n    bridge-fd 0' "$nic"
      [[ -z $mac ]] || printf '\n    hwaddress ether %s' "$mac"
      printf '\n'
    } >> "$output"
  fi
}

main() {
  [[ -f $INTERFACES_FILE ]] || die "${INTERFACES_FILE} is missing; cannot safely configure vmbr0."
  selected_route
  if [[ ${1:-} == --route-only ]]; then
    printf '%s %s\n' "$SELECTED_NIC" "$SELECTED_IP"
    return 0
  fi
  nic_stanza_is_safe "$SELECTED_NIC" || die "${SELECTED_NIC} has a custom non-DHCP address configuration; refusing to bridge it."

  local main_has_vmbr0=0 migrate_old=0 mac candidate
  grep -Eq '^[[:space:]]*iface[[:space:]]+vmbr0[[:space:]]' "$INTERFACES_FILE" && main_has_vmbr0=1 || true
  if (( ! main_has_vmbr0 )) && grep -Eq '^[[:space:]]*(auto|allow-hotplug)[[:space:]].*\bvmbr0\b' "$INTERFACES_FILE"; then
    die 'vmbr0 is listed for automatic activation without a compatible iface stanza; leaving it unchanged.'
  fi
  if (( main_has_vmbr0 )); then
    bridge_is_compatible "$INTERFACES_FILE" "$SELECTED_NIC" ||
      die 'an existing vmbr0 stanza is not the expected one-port DHCP bridge; leaving it unchanged.'
  elif [[ -f $OLD_BRIDGE_FILE ]]; then
    bridge_is_compatible "$OLD_BRIDGE_FILE" "$SELECTED_NIC" 1 ||
      die "${OLD_BRIDGE_FILE} is not the exact previously generated DHCP bridge; leaving it unchanged."
    [[ ! -e $OLD_BRIDGE_BACKUP ]] || die "old bridge file backup already exists: ${OLD_BRIDGE_BACKUP}."
    migrate_old=1
  fi

  [[ -e $BACKUP_FILE ]] || cp -a "$INTERFACES_FILE" "$BACKUP_FILE"
  candidate=$(mktemp "${NETWORK_DIR}/interfaces.XXXXXX")
  mac=''
  if (( migrate_old )); then mac=$(bridge_mac); fi
  write_candidate "$candidate" "$SELECTED_NIC" "$mac"
  chmod --reference="$INTERFACES_FILE" "$candidate"
  chown --reference="$INTERFACES_FILE" "$candidate"

  # Move the old source-directory stanza out of its wildcard before parsing the
  # main-file candidate, so ifquery sees one bridge definition.
  if (( migrate_old )); then mv -- "$OLD_BRIDGE_FILE" "$OLD_BRIDGE_BACKUP"; fi
  if ! "$IFQUERY_BIN" -i "$candidate" vmbr0 >&2; then
    rm -f "$candidate"
    if (( migrate_old )); then mv -- "$OLD_BRIDGE_BACKUP" "$OLD_BRIDGE_FILE"; fi
    die 'ifquery rejected the candidate vmbr0 stanza; /etc/network/interfaces was not changed.'
  fi
  mv -f -- "$candidate" "$INTERFACES_FILE"
  if ! "$IFQUERY_BIN" vmbr0 >&2 || ! "$IFQUERY_BIN" --list | grep -Fxq vmbr0; then
    die 'ifquery could not reread vmbr0 from /etc/network/interfaces.'
  fi
  log "PVE-managed vmbr0 uses ${SELECTED_NIC} (routed IPv4 ${SELECTED_IP}); it will activate at the next reboot."
  printf '%s %s\n' "$SELECTED_NIC" "$SELECTED_IP"
}

main "$@"
