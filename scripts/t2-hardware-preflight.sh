#!/bin/sh
# Read-only hardware checks for the MacBookPro15,1 Debian Installer live system.

usage() {
  printf 'Usage: %s [--report FILE]\n' "$0"
}

REPORT_FILE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      REPORT_FILE=$2
      shift 2
      ;;
    --report=*)
      REPORT_FILE=${1#--report=}
      [ -n "$REPORT_FILE" ] || { usage >&2; exit 2; }
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$(id -u 2>/dev/null)" != 0 ]; then
  printf 'ERROR: run this read-only preflight as root.\n' >&2
  exit 1
fi

if [ -n "$REPORT_FILE" ]; then
  if ! : > "$REPORT_FILE"; then
    printf 'ERROR: cannot create report file: %s\n' "$REPORT_FILE" >&2
    exit 2
  fi
fi

ROOT_PREFIX=${T2_PREFLIGHT_ROOT:-/}
case "$ROOT_PREFIX" in
  /) ROOT_PREFIX= ;;
  */) ROOT_PREFIX=${ROOT_PREFIX%/} ;;
esac

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

emit() {
  line="$1: $2"
  if [ -n "$REPORT_FILE" ]; then
    printf '%s\n' "$line" | tee -a "$REPORT_FILE"
  else
    printf '%s\n' "$line"
  fi
}

pass() { PASS_COUNT=$((PASS_COUNT + 1)); emit PASS "$*"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); emit WARN "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); emit FAIL "$*"; }
info() { emit INFO "$*"; }

# DMI identity is useful context but a mismatch is not itself a hard stop.
DMI_FILE=$ROOT_PREFIX/sys/class/dmi/id/product_name
if [ -r "$DMI_FILE" ]; then
  PRODUCT_NAME=$(sed -n '1p' "$DMI_FILE")
  if [ "$PRODUCT_NAME" = MacBookPro15,1 ]; then
    pass 'DMI product_name is MacBookPro15,1.'
  else
    warn "DMI product_name is '${PRODUCT_NAME:-empty}', expected MacBookPro15,1. Confirm this is the intended machine."
  fi
else
  warn "DMI product_name is unavailable at $DMI_FILE."
fi

EFI_DIR=$ROOT_PREFIX/sys/firmware/efi
if [ -d "$EFI_DIR" ]; then
  pass 'EFI runtime interface is present; the installer was booted in EFI mode.'
else
  fail 'EFI runtime interface is missing; reboot the installer using the Mac startup Option menu and its EFI entry.'
fi

EFIVARS_DIR=$EFI_DIR/efivars
SECUREBOOT_FOUND=0
for efivar in "$EFIVARS_DIR"/SecureBoot-*; do
  [ -f "$efivar" ] || continue
  SECUREBOOT_FOUND=1
  # EFI variable files start with four attribute bytes followed by the value.
  secureboot_bytes=$(od -An -t u1 -N 5 "$efivar" 2>/dev/null)
  set -- $secureboot_bytes
  if [ "$#" -lt 5 ]; then
    warn 'SecureBoot efivar exists but its attributes/value could not be read.'
    break
  fi
  secureboot_value=$5
  case "$secureboot_value" in
    0) pass 'Secure Boot is disabled (SecureBoot efivar value 0).' ;;
    1) warn 'Secure Boot is enabled (SecureBoot efivar value 1); disable it in Startup Security Utility before booting this installer.' ;;
    *) warn "SecureBoot efivar has an unexpected value (${secureboot_value}); verify Startup Security Utility settings." ;;
  esac
  break
done
if [ "$SECUREBOOT_FOUND" -eq 0 ]; then
  warn 'SecureBoot efivar is unavailable; its state could not be confirmed.'
fi

for module in t2bce_core t2bce_vhci; do
  if [ -d "$ROOT_PREFIX/sys/module/$module" ]; then
    pass "Required T2 module $module is loaded."
  else
    fail "Required T2 module $module is not loaded; try: modprobe t2bce_core t2bce_vhci"
  fi
done
for module in applesmc apple_gmux; do
  if [ -d "$ROOT_PREFIX/sys/module/$module" ]; then
    info "Optional module $module is loaded."
  else
    warn "Optional module $module is not loaded; Apple-specific sensors/display controls may be unavailable."
  fi
done

INPUT_FILE=$ROOT_PREFIX/proc/bus/input/devices
if [ -r "$INPUT_FILE" ]; then
  input_flags=$(awk '
    function inspect_record() {
      if (handlers ~ /(^|[[:space:]])kbd([[:space:]]|$)/) keyboard = 1
      if (handlers ~ /(^|[[:space:]])mouse[0-9]*([[:space:]]|$)/) pointer = 1
    }
    /^N: Name=/ {
      name = $0
      sub(/^N: Name="/, "", name)
      sub(/"$/, "", name)
    }
    /^H: Handlers=/ {
      handlers = $0
      sub(/^H: Handlers=/, "", handlers)
    }
    /^$/ { inspect_record(); name = ""; handlers = "" }
    END {
      inspect_record()
      printf "%d %d\n", keyboard, pointer
    }
  ' "$INPUT_FILE")
  set -- $input_flags
  keyboard_found=${1:-0}
  pointer_found=${2:-0}
  if [ "$keyboard_found" -eq 1 ]; then
    pass 'Input devices include a keyboard with the kbd handler.'
  else
    fail 'No keyboard with the kbd handler was found; check T2BCE modules or connect a USB keyboard.'
  fi
  if [ "$pointer_found" -eq 1 ]; then
    pass 'Input devices include a pointer with the mouse handler.'
  else
    fail 'No pointer with the mouse handler was found; check T2BCE modules or connect an external pointing device.'
  fi
  apple_inputs=$(awk '
    /^N: Name=/ {
      name = $0
      sub(/^N: Name="/, "", name)
      sub(/"$/, "", name)
      if (name ~ /Apple/) print "Apple internal input device: " name
    }
  ' "$INPUT_FILE")
  if [ -n "$apple_inputs" ]; then
    printf '%s\n' "$apple_inputs" | while IFS= read -r apple_input; do info "$apple_input"; done
  fi
else
  fail "Input device inventory is unavailable: $INPUT_FILE"
fi

NVME_DIR=$ROOT_PREFIX/sys/class/nvme
nvme_found=0
for controller in "$NVME_DIR"/*; do
  if [ -e "$controller" ] || [ -L "$controller" ]; then
    nvme_found=1
    break
  fi
done
if [ "$nvme_found" -eq 1 ]; then
  pass 'At least one NVMe controller is present in sysfs.'
else
  fail "No NVMe controller was found under $NVME_DIR."
fi

if command -v lsblk >/dev/null 2>&1; then
  lsblk_output=$(lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>&1)
  lsblk_status=$?
  if [ "$lsblk_status" -eq 0 ]; then
    info 'Block-device inventory (lsblk):'
    if [ -n "$lsblk_output" ]; then
      printf '%s\n' "$lsblk_output" | while IFS= read -r block_line; do info "  $block_line"; done
    fi
  else
    warn "lsblk could not list block devices: ${lsblk_output:-no details}"
  fi

  disk_records=$(lsblk -dnpo NAME,TYPE 2>/dev/null)
  disk_status=$?
  if [ "$disk_status" -eq 0 ]; then
    while IFS= read -r disk_record; do
      set -- $disk_record
      [ "$#" -ge 2 ] || continue
      [ "$2" = disk ] || continue
      disk_device=$1
      if command -v blkid >/dev/null 2>&1; then
        disk_signature=$(blkid -p -o value -s TYPE "$disk_device" 2>/dev/null)
        blkid_status=$?
        case "$blkid_status" in
          0)
            if [ -n "$disk_signature" ]; then
              warn "Read-only blkid probe found signature '$disk_signature' on $disk_device; review it before installation."
            else
              warn "blkid returned an empty signature result for $disk_device; review the device before installation."
            fi
            ;;
          2) pass "No blkid signature was detected on $disk_device (read-only probe)." ;;
          *) warn "Could not safely inspect signatures on $disk_device (blkid exit=$blkid_status)." ;;
        esac
      else
        warn "blkid is unavailable; signatures on $disk_device were not inspected."
      fi
    done <<EOF
$disk_records
EOF
  else
    warn 'lsblk could not identify disks for blkid signature checks.'
  fi
else
  warn 'lsblk is unavailable; disk inventory and per-disk signature checks were skipped.'
  if [ -d "$ROOT_PREFIX/sys/block" ]; then
    for block_path in "$ROOT_PREFIX"/sys/block/*; do
      [ -d "$block_path" ] || continue
      [ -e "$block_path/partition" ] && continue
      block_name=${block_path##*/}
      if command -v blkid >/dev/null 2>&1; then
        disk_device=/dev/$block_name
        disk_signature=$(blkid -p -o value -s TYPE "$disk_device" 2>/dev/null)
        blkid_status=$?
        case "$blkid_status" in
          0) warn "Read-only blkid probe found signature '${disk_signature:-unknown}' on $disk_device; review it before installation." ;;
          2) pass "No blkid signature was detected on $disk_device (read-only probe)." ;;
          *) warn "Could not safely inspect signatures on $disk_device (blkid exit=$blkid_status)." ;;
        esac
      else
        warn "blkid is unavailable; signatures on /dev/$block_name were not inspected."
      fi
    done
  fi
fi
warn 'Automatic installation expects exactly one unused LVM reservation; confirm the intended target and layout before starting an installation.'

NET_DIR=$ROOT_PREFIX/sys/class/net
WIRED_FOUND=0
CARRIER_FOUND=0
IPV4_FOUND=0
for net_path in "$NET_DIR"/*; do
  [ -e "$net_path" ] || [ -L "$net_path" ] || continue
  interface=${net_path##*/}
  [ "$interface" = lo ] && continue
  if [ -d "$net_path/wireless" ] || [ -e "$net_path/phy80211" ]; then
    info "Ignoring wireless interface $interface for the wired-link check."
    continue
  fi
  WIRED_FOUND=1
  if [ -r "$net_path/carrier" ]; then
    IFS= read -r carrier < "$net_path/carrier"
  else
    carrier=
  fi
  if [ "$carrier" = 1 ]; then
    CARRIER_FOUND=1
    pass "Wired interface $interface reports carrier=1."
  else
    info "Wired interface $interface has no active carrier (carrier=${carrier:-unknown})."
  fi
  driver_target=$(readlink "$net_path/device/driver" 2>/dev/null)
  if [ -n "$driver_target" ]; then
    info "Interface $interface driver: ${driver_target##*/}."
  else
    info "Interface $interface driver: unavailable in sysfs."
  fi
  if command -v ip >/dev/null 2>&1; then
    ipv4_output=$(ip -o -4 addr show dev "$interface" 2>/dev/null)
    case "$ipv4_output" in
      *' inet '*) IPV4_FOUND=1 ;;
    esac
  fi
done

if [ "$WIRED_FOUND" -eq 0 ]; then
  fail 'No non-wireless network interface was found; connect a supported USB-C/Thunderbolt Ethernet adapter.'
elif [ "$CARRIER_FOUND" -eq 0 ]; then
  fail 'No non-wireless interface has carrier=1; connect the wired adapter to an active Ethernet link.'
fi

if command -v ip >/dev/null 2>&1; then
  if [ "$IPV4_FOUND" -eq 1 ]; then
    pass 'A wired interface has an IPv4 address.'
  else
    warn 'No IPv4 address was found on a wired interface; check DHCP/cabling or run dhclient <interface> after identifying the wired adapter.'
  fi
  default_route=$(ip -4 route show default 2>/dev/null)
  if [ -n "$default_route" ]; then
    pass 'An IPv4 default route is present.'
  else
    warn 'No IPv4 default route was found; check DHCP, gateway and DNS before first-boot Proxmox provisioning.'
  fi
else
  warn 'iproute2 (ip) is unavailable; IPv4 and default-route checks were skipped. Install/boot with iproute2 or inspect with ip -o -4 addr and ip -4 route show default.'
fi

if [ -d "$ROOT_PREFIX/lib/firmware/brcm" ]; then
  info 'Broadcom firmware directory exists; Wi-Fi firmware is optional for the wired-LAN bring-up path.'
else
  warn 'Broadcom firmware directory is absent; this is informational for the wired-Ethernet bring-up path.'
fi

if [ "$FAIL_COUNT" -eq 0 ]; then
  result=PASS
else
  result=FAIL
fi
emit SUMMARY "$result: $PASS_COUNT PASS, $WARN_COUNT WARN, $FAIL_COUNT FAIL"

[ "$FAIL_COUNT" -eq 0 ]
