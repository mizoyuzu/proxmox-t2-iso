#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tests/vm/pve-t2-auto.sh install --iso ISO [--workdir /tmp/pve-t2-auto.NAME] [--ovmf-code FILE] [--ovmf-vars-template FILE] [--accel kvm|tcg]
  tests/vm/pve-t2-auto.sh boot1|boot2 --workdir /tmp/pve-t2-auto.NAME [--ovmf-code FILE] [--accel kvm|tcg]
  tests/vm/pve-t2-auto.sh stop --workdir /tmp/pve-t2-auto.NAME

Only a new 64 GiB raw file below /tmp/pve-t2-auto.* is used as a target.
There is no block-device option. Passwords are entered interactively and
never saved. Run install, boot1, boot2, then stop.
USAGE
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

mode=${1:-}
case "$mode" in
  install|boot1|boot2|stop) shift ;;
  -h|--help|'') usage; exit 0 ;;
  *) usage >&2; fail "unknown mode: $mode" ;;
esac

iso=
workdir=
ovmf_code=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
ovmf_vars_template=${OVMF_VARS_TEMPLATE:-/usr/share/OVMF/OVMF_VARS_4M.fd}
accel=${QEMU_ACCEL:-kvm}
ssh_port=${SSH_FORWARD_PORT:-22222}
web_port=${WEB_FORWARD_PORT:-28006}

while (($#)); do
  case "$1" in
    --iso) (($# >= 2)) || fail '--iso requires a path'; iso=$2; shift 2 ;;
    --workdir) (($# >= 2)) || fail '--workdir requires a path'; workdir=$2; shift 2 ;;
    --ovmf-code) (($# >= 2)) || fail '--ovmf-code requires a path'; ovmf_code=$2; shift 2 ;;
    --ovmf-vars-template) (($# >= 2)) || fail '--ovmf-vars-template requires a path'; ovmf_vars_template=$2; shift 2 ;;
    --accel) (($# >= 2)) || fail '--accel requires kvm or tcg'; accel=$2; shift 2 ;;
    --ssh-port) (($# >= 2)) || fail '--ssh-port requires a port'; ssh_port=$2; shift 2 ;;
    --web-port) (($# >= 2)) || fail '--web-port requires a port'; web_port=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

[[ "$accel" == kvm || "$accel" == tcg ]] || fail '--accel must be kvm or tcg'
[[ "$ssh_port" =~ ^[0-9]+$ ]] && ((ssh_port > 0 && ssh_port < 65536)) || fail 'SSH forward port must be 1-65535'
[[ "$web_port" =~ ^[0-9]+$ ]] && ((web_port > 0 && web_port < 65536)) || fail 'Web forward port must be 1-65535'

if [[ -z "$workdir" && "$mode" == install ]]; then
  workdir=$(mktemp -d /tmp/pve-t2-auto.XXXXXX)
fi
[[ -n "$workdir" ]] || fail '--workdir is required for boot1, boot2, and stop'
[[ "$workdir" == /tmp/pve-t2-auto.* ]] || fail 'workdir must use the /tmp/pve-t2-auto.* prefix'
[[ ! -L "$workdir" ]] || fail 'workdir must not be a symlink'
workdir=$(realpath -m -- "$workdir")
case "$workdir" in
  /tmp/pve-t2-auto.*) ;;
  *) fail 'resolved workdir must remain below /tmp/pve-t2-auto.*' ;;
esac

disk="$workdir/disk.raw"
vars="$workdir/OVMF_VARS.fd"
pid_file="$workdir/qemu.pid"
monitor_socket="$workdir/qemu-monitor.sock"
loop_device=
mount_p1="$workdir/mnt-p1"
mount_p2="$workdir/mnt-p2"

cleanup_loop() {
  if [[ -n "$loop_device" ]]; then
    sudo umount "$mount_p2" >/dev/null 2>&1 || true
    sudo umount "$mount_p1" >/dev/null 2>&1 || true
    sudo losetup -d "$loop_device" >/dev/null 2>&1 || true
    loop_device=
  fi
}
trap cleanup_loop EXIT

if [[ "$mode" == stop ]]; then
  [[ ! -L "$monitor_socket" ]] || fail 'QEMU monitor socket path must not be a symlink'
  [[ -S "$monitor_socket" ]] || fail "QEMU monitor socket not found: $monitor_socket"
  python3 - "$monitor_socket" <<'PY'
import socket
import sys
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as monitor:
    monitor.settimeout(5)
    monitor.connect(sys.argv[1])
    try:
        monitor.recv(4096)
    except TimeoutError:
        pass
    monitor.sendall(b"system_powerdown\n")
PY
  echo 'Sent ACPI powerdown to the disposable VM. Confirm shutdown before reusing the workdir.'
  exit 0
fi

[[ -d "$workdir" ]] || mkdir -p -- "$workdir"
for tool in qemu-system-x86_64 sgdisk losetup partprobe udevadm mkfs.fat mkfs.ext4 sudo python3 realpath; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command not found: $tool"
done
[[ -r "$ovmf_code" ]] || fail "OVMF code image is not readable: $ovmf_code"

create_test_disk() {
  [[ -n "$iso" && -r "$iso" ]] || fail 'install mode requires --iso with a readable remastered ISO'
  [[ -r "$ovmf_vars_template" ]] || fail "OVMF vars template is not readable: $ovmf_vars_template"
  [[ ! -e "$disk" && ! -L "$disk" ]] || fail "refusing to overwrite existing VM disk: $disk"
  [[ ! -e "$vars" && ! -L "$vars" ]] || fail "refusing to overwrite existing OVMF vars file: $vars"
  [[ ! -e "$mount_p1" && ! -L "$mount_p1" ]] || fail "refusing to use existing mount path: $mount_p1"
  [[ ! -e "$mount_p2" && ! -L "$mount_p2" ]] || fail "refusing to use existing mount path: $mount_p2"
  truncate -s 64G "$disk"
  sgdisk --clear \
    --new=1:2048:+200M --typecode=1:ef00 --change-name=1:Existing-EFI \
    --new=2:0:+8G --typecode=2:8300 --change-name=2:Existing-Linux \
    "$disk"
  loop_device=$(sudo losetup --find --show --partscan -- "$disk")
  sudo partprobe "$loop_device"
  sudo udevadm settle
  [[ -b "${loop_device}p1" && -b "${loop_device}p2" ]] || fail 'loop partition devices were not created for the disposable image'
  sudo mkfs.fat -F 32 "${loop_device}p1" >/dev/null
  sudo mkfs.ext4 -F "${loop_device}p2" >/dev/null
  mkdir -p "$mount_p1" "$mount_p2"
  sudo mount "${loop_device}p1" "$mount_p1"
  sudo mount "${loop_device}p2" "$mount_p2"
  printf 'keep p1\n' | sudo tee "$mount_p1/DRYRUN-P1.txt" >/dev/null
  printf 'keep p2\n' | sudo tee "$mount_p2/DRYRUN-P2.txt" >/dev/null
  cleanup_loop
  rmdir "$mount_p1" "$mount_p2"
  cp -- "$ovmf_vars_template" "$vars"
  printf 'VM workspace: %s\n' "$workdir"
  echo 'Prepared disposable 64 GiB GPT: p1=200 MiB existing ESP, p2=8 GiB existing Linux; remaining space is free.'
  echo 'Marker files DRYRUN-P1.txt and DRYRUN-P2.txt verify p1/p2 preservation.'
}

if [[ "$mode" == install ]]; then
  [[ ! -e "$pid_file" && ! -L "$pid_file" ]] || fail "stale QEMU pid file exists; inspect before proceeding: $pid_file"
  [[ ! -e "$monitor_socket" && ! -L "$monitor_socket" ]] || fail "stale QEMU monitor path exists; inspect before proceeding: $monitor_socket"
  create_test_disk
else
  [[ ! -L "$disk" && ! -L "$vars" && ! -L "$pid_file" && ! -L "$monitor_socket" ]] || fail 'VM disk and QEMU state paths must not be symlinks'
  [[ -f "$disk" && ! -b "$disk" && ! -L "$disk" ]] || fail "expected disposable raw image $disk"
  [[ -f "$vars" ]] || fail "OVMF vars file is missing: $vars (run install mode first)"
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    fail "QEMU is already running for this workdir (pid $(cat "$pid_file"))"
  fi
  rm -f -- "$pid_file" "$monitor_socket"
fi

if [[ "$mode" == install ]]; then
  qemu=(qemu-system-x86_64
    -machine "q35,accel=$accel"
    -cpu "$([[ "$accel" == kvm ]] && printf host || printf max)"
    -m 8G -smp 4
    -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
    -drive "if=pflash,format=raw,file=$vars"
    -drive "if=none,id=installcd,file=$iso,media=cdrom,readonly=on"
    -device ide-cd,drive=installcd
    -drive "if=none,id=t2disk,file=$disk,format=raw"
    -device nvme,drive=t2disk,serial=T2DRYRUN0001
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22,hostfwd=tcp:127.0.0.1:${web_port}-:8006"
    -device e1000,netdev=net0
    -boot order=d,menu=on
    -display gtk -serial mon:stdio)
  printf 'Launching installer against %s only. At GRUB, press t for the explicit auto-install entry.\n' "$disk"
  echo 'Set root password interactively; do not save it in this workdir or command history.'
  echo 'At the installer reboot prompt, power off the VM, then run boot1; do not boot from the ISO again.'
  "${qemu[@]}"
  printf 'Installer VM stopped. Workspace: %s\n' "$workdir"
  printf 'Next: %q boot1 --workdir %q --accel %q\n' "$0" "$workdir" "$accel"
  exit 0
fi

wait_for_port() {
  local port=$1 limit=$2 elapsed=0
  while ((elapsed < limit)); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

case "$mode" in
  boot1|boot2)
    qemu=(qemu-system-x86_64
      -daemonize -pidfile "$pid_file"
      -machine "q35,accel=$accel"
      -cpu "$([[ "$accel" == kvm ]] && printf host || printf max)"
      -m 8G -smp 4
      -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
      -drive "if=pflash,format=raw,file=$vars"
      -drive "if=none,id=t2disk,file=$disk,format=raw"
      -device nvme,drive=t2disk,serial=T2DRYRUN0001
      -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22,hostfwd=tcp:127.0.0.1:${web_port}-:8006"
      -device e1000,netdev=net0
      -boot order=c
      -display gtk -serial none
      -monitor "unix:$monitor_socket,server=on,wait=off")
    "${qemu[@]}"
    ;;
esac

echo "QEMU is running in a GTK window (pid $(cat "$pid_file")). Waiting for SSH on 127.0.0.1:$ssh_port."
if ! wait_for_port "$ssh_port" 1800; then
  fail 'SSH did not become reachable in 30 minutes; inspect the VM console and QEMU window'
fi

ssh_opts=(
  -tt -p "$ssh_port"
  -o ConnectTimeout=10
  -o NumberOfPasswordPrompts=1
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$workdir/known_hosts"
  -o GlobalKnownHostsFile=/dev/null
)

if [[ "$mode" == boot1 ]]; then
  echo 'SSH prompts for the root password entered in Debian Installer; it is not stored.'
  ssh "${ssh_opts[@]}" root@127.0.0.1 'bash -s -- boot1' <<'GUEST'
set -Eeuo pipefail
[[ "$1" == boot1 ]]
echo 'Waiting for first-boot-proxmox.service to finish (up to 30 minutes)...'
for attempt in {1..180}; do
  state=$(systemctl show --property=ActiveState --value first-boot-proxmox.service 2>/dev/null || true)
  [[ "$state" != activating && "$state" != deactivating ]] && break
  sleep 10
done
systemctl is-failed --quiet first-boot-proxmox.service && {
  journalctl -u first-boot-proxmox.service --no-pager -n 100
  exit 1
}
test -f /var/lib/first-boot-proxmox.done
cat /var/lib/first-boot-proxmox.status
grep -Eq '^awaiting-reboot[[:space:]]+' /var/lib/first-boot-proxmox.status
echo 'PASS: first-boot completed and requested the management-readiness reboot.'
GUEST
  echo 'Boot 1 passed. Stop the guest gracefully, then run boot2.'
else
  echo 'SSH prompts for the root password entered in Debian Installer; it is not stored.'
  ssh "${ssh_opts[@]}" root@127.0.0.1 'bash -s -- boot2' <<'GUEST'
set -Eeuo pipefail
[[ "$1" == boot2 ]]
kernel=$(uname -r)
[[ "$kernel" == *-pve-t2 ]] || { echo "FAIL: unexpected kernel: $kernel" >&2; exit 1; }
printf 'PASS: uname -r = %s\n' "$kernel"
lsmod | grep -Eq '^t2bce_core[[:space:]]' || { echo 'FAIL: t2bce_core is not loaded' >&2; exit 1; }
lsmod | grep -Eq '^t2bce_vhci[[:space:]]' || { echo 'FAIL: t2bce_vhci is not loaded' >&2; exit 1; }
echo 'PASS: t2bce_core and t2bce_vhci are loaded.'
modinfo zfs >/dev/null
echo 'PASS: modinfo zfs'
for service in ssh pve-cluster pvedaemon pveproxy pvestatd; do
  systemctl is-active --quiet "$service" || { echo "FAIL: service is not active: $service" >&2; exit 1; }
done
echo 'PASS: SSH and core PVE services are active.'
bridge_addr=$(ip -4 -o addr show dev vmbr0 scope global)
[[ -n "$bridge_addr" ]] || { echo 'FAIL: vmbr0 has no global IPv4 address' >&2; exit 1; }
printf '%s\n' "$bridge_addr"
ifquery --list | grep -Fx vmbr0 >/dev/null
echo 'PASS: vmbr0 is configured and has a global IPv4 address.'
curl -kfsS -o /dev/null https://127.0.0.1:8006/
echo 'PASS: guest Web UI endpoint responds on HTTPS/8006.'
pvesm status
pvesm status | awk '$1 == "local-lvm" && $3 == "active" { found=1 } END { exit !found }' || {
  echo 'FAIL: local-lvm is not active in pvesm status' >&2
  exit 1
}
echo 'PASS: local-lvm is active.'
GUEST
  command -v curl >/dev/null 2>&1 || fail 'curl is required for the host-side Web UI check'
  curl -kfsS -o /dev/null "https://127.0.0.1:$web_port/" || fail "host-forwarded Web UI failed at https://127.0.0.1:$web_port/"
  echo "PASS: host can reach the guest Web UI at https://127.0.0.1:$web_port/"
  echo 'Boot 2 checks passed. The guest remains open in QEMU; use stop --workdir to send ACPI powerdown.'
fi
