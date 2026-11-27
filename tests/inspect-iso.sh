#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: tests/inspect-iso.sh [--require-tools] [--max-initrd-mib N] [--max-iso-mib N] ISO

Checks the remastered ISO's GRUB entries, installer kernel, initrd contents,
preseed files, kernel image deb, and size limits. Missing xorriso/cpio is a
visible SKIP by default; --require-tools makes that condition an error for CI.

Defaults: --max-initrd-mib 200 --max-iso-mib 4096
USAGE
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_positive_integer() {
  local name=$1 value=$2
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "$name must be a positive integer (got '$value')"
}

require_tools=${ISO_INSPECT_REQUIRE_TOOLS:-0}
max_initrd_mib=200
max_iso_mib=4096

while (($#)); do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --require-tools)
      require_tools=1
      shift
      ;;
    --max-initrd-mib)
      (($# >= 2)) || fail '--max-initrd-mib requires a value'
      max_initrd_mib=$2
      shift 2
      ;;
    --max-iso-mib)
      (($# >= 2)) || fail '--max-iso-mib requires a value'
      max_iso_mib=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -* )
      fail "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
iso=$1
[[ -f "$iso" && -r "$iso" ]] || fail "ISO is not a readable regular file: $iso"
require_positive_integer --max-initrd-mib "$max_initrd_mib"
require_positive_integer --max-iso-mib "$max_iso_mib"

iso_bytes=$(stat -c '%s' -- "$iso")
iso_limit=$((max_iso_mib * 1024 * 1024))
((iso_bytes <= iso_limit)) || fail "ISO is $((iso_bytes / 1024 / 1024)) MiB; limit is ${max_iso_mib} MiB"
printf 'PASS: ISO size %d MiB (limit %d MiB)\n' "$((iso_bytes / 1024 / 1024))" "$max_iso_mib"

missing_tools=()
for tool in xorriso cpio; do
  command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if ((${#missing_tools[@]})); then
  message="ISO inspection needs: ${missing_tools[*]}"
  if [[ "$require_tools" == 1 ]]; then
    fail "$message (--require-tools is set)"
  fi
  printf 'SKIP: %s; install them or rerun with --require-tools in CI.\n' "$message"
  exit 0
fi
command -v strings >/dev/null 2>&1 || fail 'required command not found: strings (binutils)'
command -v python3 >/dev/null 2>&1 || fail 'required command not found: python3'
command -v gzip >/dev/null 2>&1 || fail 'required command not found: gzip'

work=$(mktemp -d "${TMPDIR:-/tmp}/inspect-pve-t2-iso.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
tree="$work/tree"
mkdir -p "$tree"
if ! xorriso -osirrox on -indev "$iso" -extract / "$tree" >"$work/xorriso.log" 2>&1; then
  cat "$work/xorriso.log" >&2
  fail 'xorriso could not extract the ISO filesystem'
fi

vmlinuz="$tree/install.amd/vmlinuz"
[[ -f "$vmlinuz" ]] || fail 'ISO is missing /install.amd/vmlinuz'
mapfile -t t2_releases < <(
  strings -a "$vmlinuz" |
    grep -Eo '[0-9]+(\.[0-9]+)+-[[:alnum:].+~_-]*-pve-t2' |
    sort -u || true
)
((${#t2_releases[@]} > 0)) || fail '/install.amd/vmlinuz does not contain a *-pve-t2 kernel release string'
printf 'PASS: installer kernel release: %s\n' "${t2_releases[*]}"

grub_cfg="$tree/boot/grub/grub.cfg"
[[ -f "$grub_cfg" ]] || fail 'ISO is missing /boot/grub/grub.cfg'
if ! grub_report=$(python3 - "$grub_cfg" "$tree" <<'PY'
import os
import re
import shlex
import sys
from pathlib import Path

cfg = Path(sys.argv[1])
iso_root = Path(sys.argv[2]).resolve()
text = cfg.read_text(encoding="utf-8")
lines = text.splitlines()


def brace_delta(line):
    delta = 0
    quote = None
    escaped = False
    for char in line:
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif quote:
            if char == quote:
                quote = None
        elif char in "'\"":
            quote = char
        elif char == "#":
            break
        elif char == "{":
            delta += 1
        elif char == "}":
            delta -= 1
    return delta


entries = []
depth = 0
index = 0
while index < len(lines):
    if depth == 0 and re.match(r"\s*menuentry\b", lines[index]):
        block = []
        local_depth = 0
        saw_open = False
        while index < len(lines):
            line = lines[index]
            block.append(line)
            local_depth += brace_delta(line)
            saw_open = saw_open or "{" in line
            index += 1
            if saw_open and local_depth == 0:
                break
        if not saw_open or local_depth != 0:
            raise SystemExit("unterminated top-level GRUB menuentry")
        entries.append("\n".join(block))
        continue
    depth += brace_delta(lines[index])
    if depth < 0:
        raise SystemExit("unbalanced GRUB braces")
    index += 1


def header(block):
    return block.splitlines()[0]


def preseed_paths(block):
    return re.findall(r"preseed/file=([^\s]+)", block)


def initrd_paths(block):
    paths = []
    for line in block.splitlines():
        match = re.match(r"\s*initrd\s+(.+?)\s*$", line)
        if not match:
            continue
        try:
            words = shlex.split(match.group(1))
        except ValueError as exc:
            raise SystemExit(f"invalid GRUB initrd line: {exc}")
        paths.extend(words)
    return paths


def kernel_paths(block):
    return re.findall(r"(?m)^\s*(?:linux|linuxefi)\s+(\S+)", block)


stock = [b for b in entries if re.search(r"['\"]Install['\"]", header(b))]
auto = [
    b for b in entries
    if "--hotkey=t" in header(b)
    or re.search(r"automated?", header(b), re.IGNORECASE)
    or "/preseed.cfg" in b
]
manual = [
    b for b in entries
    if "--hotkey=m" in header(b)
    or re.search(r"manual", header(b), re.IGNORECASE)
    or "/preseed-manual.cfg" in b
]
if len(stock) != 1:
    raise SystemExit(f"expected one top-level stock Install entry, found {len(stock)}")
if len(auto) != 1:
    raise SystemExit(f"expected one top-level T2 automatic entry, found {len(auto)}")
if len(manual) != 1:
    raise SystemExit(f"expected one top-level T2 manual entry, found {len(manual)}")

if preseed_paths(stock[0]):
    raise SystemExit("stock Install entry must not pass a preseed file")
if preseed_paths(auto[0]) != ["/preseed.cfg"]:
    raise SystemExit("automatic entry must pass exactly preseed/file=/preseed.cfg")
if preseed_paths(manual[0]) != ["/preseed-manual.cfg"]:
    raise SystemExit("manual entry must pass exactly preseed/file=/preseed-manual.cfg")

for label, entry in (("stock", stock[0]), ("auto", auto[0]), ("manual", manual[0])):
    if "/install.amd/vmlinuz" not in kernel_paths(entry):
        raise SystemExit(f"{label} entry must use /install.amd/vmlinuz")
    paths = initrd_paths(entry)
    if not paths:
        raise SystemExit(f"{label} entry has no initrd command")
    for path in paths:
        if not path.startswith("/") or "$" in path:
            raise SystemExit(f"{label} entry has a non-literal ISO initrd path: {path}")
        candidate = (iso_root / path.lstrip("/")).resolve()
        if os.path.commonpath((str(iso_root), str(candidate))) != str(iso_root) or not candidate.is_file():
            raise SystemExit(f"{label} entry references missing or unsafe initrd path: {path}")

auto_initrds = initrd_paths(auto[0])
manual_initrds = initrd_paths(manual[0])
if auto_initrds != manual_initrds:
    raise SystemExit("automatic and manual entries must share the same T2 initrd path(s)")

print("PASS: GRUB has one stock Install, one auto and one manual entry; preseed routing is isolated.")
print("AUTO_INITRD=" + ",".join(auto_initrds))
PY
); then
  fail 'GRUB menu validation failed'
fi
printf '%s\n' "$grub_report"

mapfile -d '' -t initrd_files < <(
  find "$tree/install.amd" -maxdepth 1 -type f \
    \( -name 'initrd*' -o -name '*preseed*.cpio' \) -print0 | sort -z
)
((${#initrd_files[@]} > 0)) || fail 'ISO has no installer initrd/preseed cpio files under /install.amd'

initrd_limit=$((max_initrd_mib * 1024 * 1024))
for initrd in "${initrd_files[@]}"; do
  case "$(basename -- "$initrd")" in
    initrd*)
      size=$(stat -c '%s' -- "$initrd")
      ((size <= initrd_limit)) || fail "${initrd#"$tree"} is $((size / 1024 / 1024)) MiB; limit is ${max_initrd_mib} MiB"
      printf 'PASS: %s size %d MiB (limit %d MiB)\n' "${initrd#"$tree"}" "$((size / 1024 / 1024))" "$max_initrd_mib"
      ;;
  esac
done

members_file="$work/cpio-members.txt"
: > "$members_file"
archive_count=0
for archive in "${initrd_files[@]}"; do
  case "$(basename -- "$archive")" in
    *.cpio)
      if ! cpio -it --quiet < "$archive" >> "$members_file" 2>"$work/cpio.log"; then
        cat "$work/cpio.log" >&2
        fail "cpio could not list ${archive#"$tree"}"
      fi
      archive_count=$((archive_count + 1))
      ;;
    *.gz)
      if ! gzip -dc -- "$archive" | cpio -it --quiet >> "$members_file" 2>"$work/cpio.log"; then
        cat "$work/cpio.log" >&2
        fail "could not list compressed cpio archive ${archive#"$tree"}"
      fi
      archive_count=$((archive_count + 1))
      ;;
    initrd*)
      # A combined T2 initrd may be an uncompressed preseed cpio followed by
      # the gzip initrd. List its leading archive but tolerate the compressed
      # tail; the standalone .gz payload is checked above as well.
      cpio -it --quiet < "$archive" >> "$members_file" 2>/dev/null || true
      archive_count=$((archive_count + 1))
      ;;
    *)
      # Ignore non-initrd cpio support files such as checksum metadata.
      ;;
  esac
done
((archive_count > 0)) || fail 'no raw newc or gzip-compressed cpio initrd could be listed'

member_exists() {
  local expression=$1
  grep -Eq "$expression" "$members_file"
}
member_exists '(^|/)t2bce_core\.ko(\.[^/]+)?$' || fail 'initrd cpio members do not include t2bce_core.ko'
member_exists '(^|/)modules\.dep$' || fail 'initrd cpio members do not include modules.dep'
member_exists '(^|/)preseed\.cfg$' || fail 'initrd cpio members do not include preseed.cfg'
member_exists '(^|/)preseed-manual\.cfg$' || fail 'initrd cpio members do not include preseed-manual.cfg'
printf 'PASS: initrd cpio contains t2bce_core.ko, modules.dep, and both preseed files.\n'

deb_dir="$tree/t2/debs"
[[ -d "$deb_dir" ]] || fail 'ISO is missing /t2/debs/'
mapfile -t image_debs < <(
  find "$deb_dir" -maxdepth 1 -type f \
    \( -name 'proxmox-kernel-*-pve-t2_*_amd64.deb' -o -name 'linux-image-*-pve-t2_*_amd64.deb' \) \
    -print | sort
)
((${#image_debs[@]} > 0)) || fail '/t2/debs/ has no *-pve-t2 amd64 kernel image deb'
printf 'PASS: T2 kernel image deb: %s\n' "${image_debs[*]#"$tree"/}"

printf 'PASS: ISO inspection complete: %s\n' "$iso"
