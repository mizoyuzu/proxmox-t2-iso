#!/usr/bin/env bash
# First boot provisioning for Debian 13 on the T2 MacBookPro15,1.
set -euo pipefail

readonly MARKER=/var/lib/first-boot-proxmox.done
readonly LOG_FILE=/var/log/first-boot-proxmox.log
readonly GRUB_CFG=/boot/grub/grub.cfg
readonly DISABLE_PVE_ENTERPRISE_SOURCE=/usr/local/sbin/disable-pve-enterprise-source.sh

if [[ $(id -u) -ne 0 ]]; then
  printf 'ERROR: run this script as root.\n' >&2
  exit 1
fi

mkdir -p /var/log /var/lib
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  printf '[first-boot-proxmox] %s\n' "$*"
}

die() {
  log "ERROR: $*"
  rm -f "$MARKER"
  exit 1
}

on_error() {
  local status=$?
  rm -f "$MARKER"
  log "ERROR: command failed at line ${BASH_LINENO[0]} (exit ${status})."
  exit "$status"
}
trap on_error ERR

# network-online.target can precede DHCP completion, so wait for actual IPv4/DNS.
wait_for_network() {
  local timeout=120 interval=2 elapsed=0 default_route
  log 'Waiting for IPv4 connectivity and DNS before provisioning.'
  while (( elapsed <= timeout )); do
    default_route=$(ip route show default 2>/dev/null || true)
    if ip -o -4 addr show scope global 2>/dev/null | grep -q 'inet ' &&
       [[ -n "$default_route" ]] &&
       getent ahostsv4 enterprise.proxmox.com >/dev/null 2>&1; then
      log 'Network is ready.'
      return 0
    fi
    if (( elapsed >= timeout )); then
      break
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  die 'timed out after 120 seconds waiting for IPv4 connectivity and DNS; check the wired NIC, DHCP, and DNS, then rerun.'
}

# A manual rerun is a fresh attempt. The marker is committed only after every
# provisioning step succeeds, so a failed rerun must not leave stale success.
rm -f "$MARKER"
export DEBIAN_FRONTEND=noninteractive

grub_t2_id_path() {
  local grub_cfg=$1 running_kernel=${2:-$(uname -r)}
  awk -v running_kernel="$running_kernel" '
    function delta(line,    i, c, quote, escaped, result) {
      quote = ""
      escaped = 0
      result = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (escaped) {
          escaped = 0
          continue
        }
        if (c == "\\") {
          escaped = 1
          continue
        }
        if (quote != "") {
          if (c == quote) quote = ""
          continue
        }
        if (c == "\"" || c == sprintf("%c", 39)) {
          quote = c
          continue
        }
        if (c == "#") break
        if (c == "{") result++
        if (c == "}") result--
      }
      return result
    }
    function title_of(rest,    quote, i, c, fields) {
      if (substr(rest, 1, 1) == "\"" || substr(rest, 1, 1) == sprintf("%c", 39)) {
        quote = substr(rest, 1, 1)
        for (i = 2; i <= length(rest); i++) {
          c = substr(rest, i, 1)
          if (c == quote && substr(rest, i - 1, 1) != "\\")
            return substr(rest, 2, i - 2)
        }
        return ""
      }
      split(rest, fields, /[[:space:]]+/)
      return fields[1]
    }
    function id_of(line,    marker, rest, quote, i, c) {
      marker = "$menuentry_id_option"
      i = index(line, marker)
      if (!i) return ""
      rest = substr(line, i + length(marker))
      sub(/^[[:space:]]+/, "", rest)
      quote = substr(rest, 1, 1)
      if (quote != "\"" && quote != sprintf("%c", 39)) return ""
      for (i = 2; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c == quote && substr(rest, i - 1, 1) != "\\")
          return substr(rest, 2, i - 2)
      }
      return ""
    }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next

      while (submenu_count > 0 && depth <= submenu_depth[submenu_count])
        submenu_count--
      if (in_menuentry && depth <= menuentry_depth)
        in_menuentry = 0

      if (line ~ /^(submenu|menuentry)[[:space:]]+/) {
        kind = line
        sub(/[[:space:]].*$/, "", kind)
        rest = line
        sub(/^[^[:space:]]+[[:space:]]+/, "", rest)
        title = title_of(rest)
        if (title != "") {
          if (kind == "submenu") {
            submenu_count++
            submenu_id[submenu_count] = id_of(line)
            submenu_depth[submenu_count] = depth
          } else {
            entry_title = title
            entry_id = id_of(line)
            menuentry_depth = depth
            in_menuentry = 1
            menuentry_checked = 0
          }
        }
      }

      if (in_menuentry && !menuentry_checked && submenu_count > 0 &&
          tolower(entry_title) !~ /\(recovery mode\)$/ &&
          line ~ /^[[:space:]]*linux(efi|16|efi16)?[[:space:]]/ && tolower(line) ~ /t2-pve/ &&
          tolower(line) !~ /[[:space:]]single([[:space:]]|$)/) {
        menuentry_checked = 1
        kernel_line = line
        sub(/^[[:space:]]*linux(efi|16|efi16)?[[:space:]]+/, "", kernel_line)
        split(kernel_line, kernel_args, /[[:space:]]+/)
        kernel_path = kernel_args[1]
        sub(/^.*\//, "", kernel_path)
        if (kernel_path !~ /^vmlinuz-[^/]+$/) next
        kernel_version = kernel_path
        sub(/^vmlinuz-/, "", kernel_version)
        if (kernel_version == "" || tolower(kernel_version) !~ /-t2-pve$/ ||
            entry_id == "" || submenu_count != 1) next

        # Debian 10_linux emits a version-specific advanced entry as
        # gnulinux-${version}-advanced-${bootid} under
        # gnulinux-advanced-${bootid}. Require this exact pairing so a
        # generic gnulinux-simple-* ID can never silently select another
        # kernel.
        submenu_boot_id = submenu_id[1]
        sub(/^gnulinux-advanced-/, "", submenu_boot_id)
        expected_entry_id = "gnulinux-" kernel_version "-advanced-" submenu_boot_id
        if (submenu_id[1] !~ /^gnulinux-advanced-.+/ ||
            submenu_boot_id == "" || entry_id != expected_entry_id) next

        candidate = submenu_id[1] ">" entry_id
        if (!(candidate in matches)) {
          matches[candidate] = kernel_version
          match_count++
          if (match_count == 1) first_candidate = candidate
          # Prefer the running T2 kernel when it is represented in GRUB.
          # Otherwise the first valid 10_linux T2 entry is the newest ordered
          # candidate and remains a deterministic choice if several exist.
          if (kernel_version == running_kernel && running_candidate == "")
            running_candidate = candidate
        }
      }
      depth += delta($0)
    }
    END {
      if (match_count == 0) exit 1
      if (running_candidate != "") print running_candidate
      else print first_candidate
    }
  ' "$grub_cfg"
}

grub_default_matches() {
  local wanted=$1 config=$2
  awk -v wanted="$wanted" '
    /^[[:space:]]*set[[:space:]]+default=/ {
      value = $0
      sub(/^[[:space:]]*set[[:space:]]+default=/, "", value)
      sub(/[[:space:]]*;?[[:space:]]*$/, "", value)
      if ((substr(value, 1, 1) == "\"" && substr(value, length(value), 1) == "\"") ||
          (substr(value, 1, 1) == sprintf("%c", 39) && substr(value, length(value), 1) == sprintf("%c", 39)))
        value = substr(value, 2, length(value) - 2)
      if (value == wanted) found = 1
    }
    END { exit !found }
  ' "$config"
}

write_grub_defaults() {
  local defaults_file=$1 wanted=$2 quoted defaults_line defaults_tmp
  printf -v quoted '%q' "$wanted"
  defaults_line="GRUB_DEFAULT=${quoted}"
  defaults_tmp=$(mktemp "${defaults_file}.XXXXXX") || return 1
  if ! GRUB_DEFAULT_LINE="$defaults_line" awk '
    BEGIN { default_done = 0; timeout_done = 0 }
    /^[[:space:]]*GRUB_DEFAULT=/ {
      if (!default_done) print ENVIRON["GRUB_DEFAULT_LINE"]
      default_done = 1
      next
    }
    /^[[:space:]]*GRUB_TIMEOUT=/ {
      if (!timeout_done) print "GRUB_TIMEOUT=10"
      timeout_done = 1
      next
    }
    { print }
    END {
      if (!default_done) print ENVIRON["GRUB_DEFAULT_LINE"]
      if (!timeout_done) print "GRUB_TIMEOUT=10"
    }
  ' "$defaults_file" > "$defaults_tmp"; then
    rm -f "$defaults_tmp"
    return 1
  fi
  if ! chmod --reference="$defaults_file" "$defaults_tmp" ||
     ! chown --reference="$defaults_file" "$defaults_tmp" ||
     ! mv "$defaults_tmp" "$defaults_file"; then
    rm -f "$defaults_tmp"
    return 1
  fi
}

pin_t2_grub_default() {
  local phase=$1 grub_cfg=${2:-$GRUB_CFG} defaults_file=${3:-/etc/default/grub}
  local t2_id_path current_grub_default current_grub_timeout quoted generated_id_path

  log "Pinning the version-specific T2 kernel GRUB ID ${phase}."
  if ! update-grub; then
    die "update-grub failed ${phase} while refreshing ${grub_cfg}."
    return 1
  fi
  if [[ ! -r "$grub_cfg" ]] || ! t2_id_path=$(grub_t2_id_path "$grub_cfg"); then
    die "no resolvable version-specific, non-recovery T2 GRUB ID path was found in ${grub_cfg} ${phase}."
    return 1
  fi

  current_grub_default=$(sed -n 's/^GRUB_DEFAULT=//p' "$defaults_file" | head -n 1)
  current_grub_timeout=$(sed -n 's/^GRUB_TIMEOUT=//p' "$defaults_file" | head -n 1)
  printf -v quoted '%q' "$t2_id_path"
  if [[ "$current_grub_default" == "$quoted" && "$current_grub_timeout" == 10 ]] &&
     grub_default_matches "$t2_id_path" "$grub_cfg"; then
    log "GRUB_DEFAULT already resolves to T2 ID path ${t2_id_path}."
  else
    if ! write_grub_defaults "$defaults_file" "$t2_id_path"; then
      die 'could not write the stable T2 GRUB ID path and timeout settings.'
      return 1
    fi
    if ! update-grub; then
      die "update-grub failed after pinning T2 ID path ${t2_id_path}."
      return 1
    fi
  fi

  if ! generated_id_path=$(grub_t2_id_path "$grub_cfg"); then
    die "regenerated ${grub_cfg} has no resolvable version-specific T2 GRUB ID path ${phase}."
    return 1
  fi
  if [[ "$generated_id_path" != "$t2_id_path" ]]; then
    die "T2 GRUB ID path changed during regeneration ${phase} (expected '${t2_id_path}', found '${generated_id_path}')."
    return 1
  fi
  if ! grub_default_matches "$t2_id_path" "$grub_cfg"; then
    grep -n 'set default=' "$grub_cfg" || true
    die "generated ${grub_cfg} does not resolve GRUB default to T2 ID path '${t2_id_path}' ${phase}."
    return 1
  fi
  log "Verified generated GRUB default and T2 ID path ${phase}: ${t2_id_path}."
}

# Pin locally before networking or APT. A rerun can repair the default even if
# the active kernel currently lacks a working wired network driver.
pin_t2_grub_default 'before network and APT'
wait_for_network

log 'Setting the system hostname to pve-mbp (FQDN pve-mbp.local).'
printf 'pve-mbp\n' > /etc/hostname
hostname pve-mbp
SHORT_HOSTNAME=$(hostname -s)
FQDN="${SHORT_HOSTNAME}.local"
IP_ADDR=$(ip -o -4 addr show scope global 2>/dev/null | awk 'NR == 1 { sub(/\/.*/, "", $4); print $4; exit }')
if [[ -n "$IP_ADDR" ]]; then
  hosts_tmp=$(mktemp /etc/hosts.XXXXXX)
  awk '
    {
      output = $1
      for (i = 2; i <= NF; i++)
        if ($i != "pve-mbp" && $i != "pve-mbp.local") output = output " " $i
      if (output != "") print output
    }
  ' /etc/hosts > "$hosts_tmp"
  chmod --reference=/etc/hosts "$hosts_tmp"
  chown --reference=/etc/hosts "$hosts_tmp"
  mv "$hosts_tmp" /etc/hosts
  printf '%s %s %s\n' "$IP_ADDR" "$FQDN" "$SHORT_HOSTNAME" >> /etc/hosts
  log "/etc/hosts maps ${IP_ADDR} to ${FQDN} and ${SHORT_HOSTNAME}."
else
  log 'WARNING: no global IPv4 address yet; cannot map pve-mbp.local to a real IP. Continuing.'
fi

log 'Configuring the Proxmox VE Trixie no-subscription repository.'
install -d -m 0755 /usr/share/keyrings
key_tmp=$(mktemp)
if ! curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -o "$key_tmp"; then
  rm -f "$key_tmp"
  die 'could not download the Proxmox archive keyring.'
fi
key_size=$(stat -c '%s' "$key_tmp")
if (( key_size < 1000 || key_size > 1048576 )); then
  rm -f "$key_tmp"
  die "Proxmox keyring size looks invalid (${key_size} bytes)."
fi
if head -c 64 "$key_tmp" | grep -Eiq '<!doctype[[:space:]]+html|<html'; then
  rm -f "$key_tmp"
  die 'Proxmox keyring download contains HTML instead of key data.'
fi
first_byte=$(od -An -tu1 -N1 "$key_tmp" | tr -d '[:space:]')
if [[ -z "$first_byte" ]] || (( first_byte < 128 )); then
  rm -f "$key_tmp"
  die 'Proxmox keyring does not begin with a plausible OpenPGP packet.'
fi
if command -v gpg >/dev/null 2>&1 && ! gpg --batch --show-keys "$key_tmp" >/dev/null 2>&1; then
  rm -f "$key_tmp"
  die 'Proxmox keyring failed OpenPGP content validation.'
fi
install -o root -g root -m 0644 "$key_tmp" /usr/share/keyrings/proxmox-archive-keyring.gpg
rm -f "$key_tmp"
cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

# pve-manager installs its enterprise deb822 source. Disable that canonical
# package stanza before every update so a retry remains usable without a
# subscription. The helper edits only pve-enterprise.sources.
if [[ ! -x "$DISABLE_PVE_ENTERPRISE_SOURCE" ]]; then
  die "PVE enterprise source helper is missing or not executable: ${DISABLE_PVE_ENTERPRISE_SOURCE}."
fi
"$DISABLE_PVE_ENTERPRISE_SOURCE"

apt-get update
packages=(proxmox-ve postfix open-iscsi chrony ifupdown2)
packages_missing=0
for package in "${packages[@]}"; do
  if ! dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
    packages_missing=1
  fi
done
if (( packages_missing )); then
  log 'Installing Proxmox VE and required services.'
  if command -v debconf-set-selections >/dev/null 2>&1; then
    printf 'postfix postfix/main_mailer_type select Local only\npostfix postfix/mailname string %s\n' "$FQDN" |
      debconf-set-selections
  fi
  if ! apt-get install -y "${packages[@]}"; then
    die 'package installation failed; inspect apt output and resolve the repository/dependency issue.'
  fi
  # pve-manager may have created its enterprise source during this install.
  "$DISABLE_PVE_ENTERPRISE_SOURCE"
else
  log 'Proxmox VE and required service packages are already installed; skipping package installation.'
fi

log 'Creating and registering the local-lvm thin pool.'
if ! vgs pve >/dev/null 2>&1; then
  die 'LVM volume group pve is missing. Verify the installer created VG pve before first boot.'
fi
if lvs pve/data >/dev/null 2>&1; then
  lv_attr=$(lvs --noheadings -o lv_attr pve/data | tr -d '[:space:]')
  if [[ ${lv_attr:0:1} != t ]]; then
    die "pve/data exists but is not a thin pool (lv_attr=${lv_attr}). Resolve it manually before rerunning."
  fi
  log 'Thin pool pve/data already exists; skipping creation.'
else
  free_extents=$(vgs --noheadings -o vg_free_count pve | tr -d '[:space:]')
  if [[ ! "$free_extents" =~ ^[0-9]+$ ]] || (( free_extents == 0 )); then
    die 'VG pve has no free extents for the thin pool. Reduce root LV size or repair the installer LVM layout, then rerun.'
  fi
  if ! lvcreate --type thin-pool -n data -l 100%FREE pve; then
    die 'could not create pve/data from the free VG extents; inspect LVM state and free space.'
  fi
fi
systemctl start pve-cluster
if ! pvesm status 2>/dev/null | awk 'NR > 1 && $1 == "local-lvm" { found = 1 } END { exit !found }'; then
  if ! pvesm add lvmthin local-lvm --vgname pve --thinpool data --content rootdir,images; then
    die 'could not register local-lvm in Proxmox storage configuration.'
  fi
else
  log 'Proxmox storage local-lvm already exists; skipping registration.'
fi

if dpkg-query -W -f='${db:Status-Status}' linux-image-amd64 2>/dev/null | grep -qx installed; then
  log 'Removing only the Debian linux-image-amd64 metapackage.'
  apt-get remove -y linux-image-amd64
else
  log 'Debian linux-image-amd64 metapackage is absent; skipping removal.'
fi

# This final pass follows every package operation, since package hooks can
# regenerate GRUB or install another kernel. The earlier pass already pinned
# the T2 entry before any network or APT work, protecting an interrupted boot.
pin_t2_grub_default 'after all package operations'

configure_vmbr0() {
  local nic=$1 backup=/etc/network/interfaces.first-boot-proxmox.bak
  local config_tmp desired interfaces_file=/etc/network/interfaces

  if [[ ! -f "$interfaces_file" ]]; then
    die '/etc/network/interfaces is missing; cannot safely configure vmbr0.'
  fi
  if [[ ! -e "$backup" ]]; then
    cp -a "$interfaces_file" "$backup"
    log "Backed up ${interfaces_file} to ${backup}."
  fi

  config_tmp=$(mktemp /etc/network/interfaces.XXXXXX)
  awk -v nic="$nic" '
    function comment_line(line) { print "# first-boot-proxmox: " line }
    {
      if (in_dhcp_stanza && $0 !~ /^[[:space:]]/ && $0 !~ /^[[:space:]]*$/ && $0 !~ /^#/) in_dhcp_stanza = 0
      if (in_dhcp_stanza) {
        comment_line($0)
        next
      }
      if ($1 == "auto" || $1 == "allow-hotplug") {
        output = $1
        removed = 0
        for (i = 2; i <= NF; i++) {
          if ($i == nic) removed = 1
          else output = output " " $i
        }
        if (removed) {
          if (output == $1) comment_line($0)
          else print output
          next
        }
      }
      if ($1 == "iface" && $2 == nic && $3 == "inet" && $4 == "dhcp") {
        in_dhcp_stanza = 1
        comment_line($0)
        next
      }
      print
    }
  ' "$interfaces_file" > "$config_tmp"
  if ! cmp -s "$config_tmp" "$interfaces_file"; then
    chmod --reference="$interfaces_file" "$config_tmp"
    chown --reference="$interfaces_file" "$config_tmp"
    mv "$config_tmp" "$interfaces_file"
    log "Moved the installer's DHCP configuration for ${nic} out of the active interfaces file."
  else
    rm -f "$config_tmp"
  fi

  if ! grep -Eq '^[[:space:]]*source(-directory)?[[:space:]]+/etc/network/interfaces\.d' "$interfaces_file"; then
    printf '\n# Load first-boot bridge configuration.\nsource /etc/network/interfaces.d/*\n' >> "$interfaces_file"
  fi
  install -d -m 0755 /etc/network/interfaces.d
  desired=$(printf 'auto vmbr0\niface vmbr0 inet dhcp\n    bridge-ports %s\n    bridge-stp off\n    bridge-fd 0' "$nic")
  if [[ ! -f /etc/network/interfaces.d/vmbr0 ]] || [[ $(cat /etc/network/interfaces.d/vmbr0) != "$desired" ]]; then
    printf '%s\n' "$desired" > /etc/network/interfaces.d/vmbr0
  else
    log "vmbr0 configuration for ${nic} already exists; leaving it unchanged."
  fi
  if ! ifquery vmbr0; then
    die 'ifquery vmbr0 rejected the generated configuration; inspect /etc/network/interfaces and interfaces.d/vmbr0.'
  fi
  log "Validated vmbr0 bridge configuration using wired NIC ${nic}. It will activate at the next reboot; no live reload was run."
}

log 'Looking for a wired Ethernet interface for vmbr0.'
shopt -s nullglob
wired_nics=()
for nic_path in /sys/class/net/en* /sys/class/net/eth*; do
  nic=${nic_path##*/}
  case "$nic" in
    lo|wl*|vmbr*|veth*|tap*|br*|docker*|t2bce*) continue ;;
  esac
  [[ -d "/sys/class/net/${nic}/device" ]] || continue
  wired_nics+=("$nic")
done
shopt -u nullglob
selected_nic=''
for nic in "${wired_nics[@]}"; do
  if [[ -r "/sys/class/net/${nic}/carrier" ]] && read -r carrier < "/sys/class/net/${nic}/carrier" && [[ "$carrier" == 1 ]]; then
    selected_nic=$nic
    break
  fi
done
if [[ -z "$selected_nic" && ${#wired_nics[@]} -gt 0 ]]; then
  selected_nic=${wired_nics[0]}
fi
if [[ -n "$selected_nic" ]]; then
  configure_vmbr0 "$selected_nic"
else
  log 'WARNING: no wired Ethernet NIC (en*/eth*) with a device path was found; skipping vmbr0 configuration.'
fi

log 'Enabling SSH and Proxmox management services.'
systemctl enable ssh
systemctl enable pve-cluster pvedaemon pveproxy pvestatd

if [[ -n "$IP_ADDR" ]]; then
  log "Proxmox Web UI: https://${IP_ADDR}:8006/"
else
  log "Proxmox Web UI: https://${FQDN}:8006/ (resolve pve-mbp.local to the host's LAN address)."
fi
log 'Provisioning complete. A reboot is required to boot the T2 kernel; this script will not reboot automatically.'
touch "$MARKER"
