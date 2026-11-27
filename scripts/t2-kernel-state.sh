#!/usr/bin/env bash
# Read-only audit of the installed and selected T2 kernel lifecycle state.
set -u

readonly DPKG_QUERY=${T2_DPKG_QUERY:-dpkg-query}
readonly APT_MARK=${T2_APT_MARK:-apt-mark}
readonly UNAME=${T2_UNAME:-uname}
readonly GRUB_DEFAULT_FILE=${T2_GRUB_DEFAULT_FILE:-/etc/default/grub}
readonly GRUB_CFG=${T2_GRUB_CFG:-/boot/grub/grub.cfg}

failures=0

pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*"
  failures=$((failures + 1))
}

if [[ -n "${T2_PROC_VERSION:-}" ]]; then
  if [[ -r "$T2_PROC_VERSION" ]]; then
    running_kernel=$(<"$T2_PROC_VERSION")
  else
    # Also accept a literal release string for callers that do not have procfs.
    running_kernel=$T2_PROC_VERSION
  fi
else
  running_kernel=$("$UNAME" -r 2>/dev/null) || running_kernel=
fi

case "$running_kernel" in
  *-pve-t2|*-t2-pve) pass "running kernel is T2: ${running_kernel}" ;;
  '') fail 'could not determine the running kernel release.' ;;
  *) fail "running kernel is not a T2 kernel: ${running_kernel}" ;;
esac

if package_listing=$("$DPKG_QUERY" -W -f='${Package}\t${db:Status-Status}\n' 2>/dev/null); then
  mapfile -t t2_packages < <(
    printf '%s\n' "$package_listing" | awk -F '\t' '
      $2 == "installed" &&
        ($1 ~ /^proxmox-kernel-.+-pve-t2$/ || $1 ~ /^linux-image-.+-t2-pve$/) { print $1 }
    '
  )
else
  t2_packages=()
  fail 'dpkg-query could not inspect installed packages.'
fi

package=
package_kernel=
if ((${#t2_packages[@]} == 1)); then
  package=${t2_packages[0]}
  case "$package" in
    proxmox-kernel-*) package_kernel=${package#proxmox-kernel-} ;;
    linux-image-*) package_kernel=${package#linux-image-} ;;
  esac
  pass "exactly one T2 kernel package is installed: ${package}"
else
  fail "expected exactly one installed T2 kernel package, found ${#t2_packages[@]} (${t2_packages[*]:-none})."
fi

if hold_listing=$("$APT_MARK" showhold 2>/dev/null); then
  if [[ -n "$package" ]] && grep -Fxq -- "$package" <<<"$hold_listing"; then
    pass "T2 kernel package is held: ${package}"
  elif [[ -n "$package" ]]; then
    fail "T2 kernel package is not held: ${package}"
  else
    fail 'cannot verify a hold because there is not exactly one installed T2 kernel package.'
  fi
else
  fail 'apt-mark showhold failed.'
fi

grub_default=
default_lines=()
if [[ -r "$GRUB_DEFAULT_FILE" ]]; then
  mapfile -t default_lines < <(
    sed -n -E 's/^[[:space:]]*GRUB_DEFAULT[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$GRUB_DEFAULT_FILE"
  )
else
  fail "GRUB defaults file is missing or unreadable: ${GRUB_DEFAULT_FILE}"
fi

submenu_id=
entry_id=
grub_kernel=
if ((${#default_lines[@]} == 1)); then
  grub_default=${default_lines[0]}
  if [[ ${grub_default:0:1} == '"' && ${grub_default: -1} == '"' ]] ||
     [[ ${grub_default:0:1} == "'" && ${grub_default: -1} == "'" ]]; then
    grub_default=${grub_default:1:${#grub_default}-2}
  fi
  # first-boot writes the ID path with shell-safe %q escaping (notably \>). 
  grub_default=${grub_default//\\>/\>}
  if [[ "$grub_default" == *'>'* && "$grub_default" != *'>'*'>'* && "$grub_default" != *\\* ]]; then
    submenu_id=${grub_default%%>*}
    entry_id=${grub_default#*>}
    case "$submenu_id" in
      gnulinux-advanced-*)
        submenu_boot_id=${submenu_id#gnulinux-advanced-}
        case "$entry_id" in
          gnulinux-*-advanced-*)
            entry_body=${entry_id#gnulinux-}
            grub_kernel=${entry_body%-advanced-*}
            entry_boot_id=${entry_body##*-advanced-}
            case "$grub_kernel" in
              *-pve-t2|*-t2-pve)
                if [[ -n "$submenu_boot_id" && "$entry_boot_id" == "$submenu_boot_id" &&
                      "$entry_id" == "gnulinux-${grub_kernel}-advanced-${submenu_boot_id}" ]]; then
                  pass "GRUB_DEFAULT selects a version-specific T2 ID path: ${grub_default}"
                else
                  fail "GRUB_DEFAULT is not a matching version-specific T2 ID pair: ${grub_default}"
                  grub_kernel=
                fi
                ;;
              *) fail "GRUB_DEFAULT entry does not identify a T2 kernel version: ${grub_default}" ; grub_kernel= ;;
            esac
            ;;
          *) fail "GRUB_DEFAULT does not select a version-specific kernel entry: ${grub_default}" ;;
        esac
        ;;
      *) fail "GRUB_DEFAULT does not select a version-specific advanced entry: ${grub_default}" ;;
    esac
  else
    fail "GRUB_DEFAULT is not a version-specific submenu>entry ID path: ${grub_default}"
  fi
elif [[ -r "$GRUB_DEFAULT_FILE" ]]; then
  fail "expected exactly one GRUB_DEFAULT assignment, found ${#default_lines[@]}"
fi

if [[ -n "$package_kernel" && -n "$grub_kernel" ]]; then
  if [[ "$package_kernel" == "$grub_kernel" ]]; then
    pass "GRUB_DEFAULT targets the installed T2 kernel version: ${grub_kernel}"
  else
    fail "GRUB_DEFAULT targets ${grub_kernel}, but the installed T2 package is ${package_kernel}."
  fi
fi

if [[ ! -r "$GRUB_CFG" ]]; then
  fail "GRUB config is missing or unreadable: ${GRUB_CFG}"
elif [[ -n "$submenu_id" && -n "$entry_id" && -n "$grub_kernel" ]]; then
  if awk -v wanted_submenu="$submenu_id" -v wanted_entry="$entry_id" -v wanted_kernel="$grub_kernel" '
    function delta(line,    i, c, quote, escaped, result) {
      quote = ""; escaped = 0; result = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (escaped) { escaped = 0; continue }
        if (c == "\\") { escaped = 1; continue }
        if (quote != "") { if (c == quote) quote = ""; continue }
        if (c == "\"" || c == sprintf("%c", 39)) { quote = c; continue }
        if (c == "#") break
        if (c == "{") result++
        if (c == "}") result--
      }
      return result
    }
    function has_id(line, id,    single, double) {
      single = sprintf("%c", 39); double = "\""
      return index(line, single id single) || index(line, double id double)
    }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (!inside_submenu && line ~ /^submenu[[:space:]]/ && has_id(line, wanted_submenu)) {
        inside_submenu = 1
        submenu_depth = depth
      }
      if (inside_submenu && !inside_entry && depth > submenu_depth &&
          line ~ /^menuentry[[:space:]]/ && has_id(line, wanted_entry)) {
        inside_entry = 1
        entry_depth = depth
      }
      if (inside_entry && depth > entry_depth &&
          line ~ /^linux(efi|16|efi16)?[[:space:]]/) {
        sub(/^[[:space:]]*linux(efi|16|efi16)?[[:space:]]+/, "", line)
        split(line, fields, /[[:space:]]+/)
        kernel_path = fields[1]
        sub(/^.*\//, "", kernel_path)
        if (kernel_path == "vmlinuz-" wanted_kernel) kernel_found = 1
      }
      depth += delta($0)
      if (inside_entry && depth <= entry_depth) {
        if (kernel_found) found = 1
        inside_entry = 0
      }
      if (inside_submenu && depth <= submenu_depth) inside_submenu = 0
    }
    END { exit !found }
  ' "$GRUB_CFG"; then
    pass "GRUB config contains the selected T2 submenu, entry, and kernel: ${grub_kernel}"
  else
    fail "GRUB config has no matching version-specific T2 entry for ${grub_default}: ${GRUB_CFG}"
  fi
fi

if [[ -n "$running_kernel" && -n "$package_kernel" && "$running_kernel" != "$package_kernel" ]]; then
  warn "running kernel ${running_kernel} differs from the single installed T2 package ${package_kernel}; reboot may be pending."
fi

if ((failures > 0)); then
  exit 1
fi
exit 0
