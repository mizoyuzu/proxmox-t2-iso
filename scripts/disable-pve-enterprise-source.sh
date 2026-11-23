#!/usr/bin/env bash
set -euo pipefail

# pve-manager ships this canonical deb822 source. Keep the change scoped to
# that file and to stanzas for the PVE enterprise repository; leave all other
# apt sources, including pve-no-subscription, untouched.
source_dir=${PVE_APT_SOURCES_DIR:-/etc/apt/sources.list.d}
source_file=$source_dir/pve-enterprise.sources

log() {
  printf '[disable-pve-enterprise-source] %s\n' "$*"
}

if [[ ! -e "$source_file" ]]; then
  log 'pve-enterprise.sources is absent; nothing to disable.'
  exit 0
fi
if [[ -L "$source_file" || ! -f "$source_file" ]]; then
  log "ERROR: refusing to modify non-regular package source path: $source_file" >&2
  exit 1
fi

source_tmp=$(mktemp "$source_file.XXXXXX")
trap 'rm -f "$source_tmp"' EXIT

set +e
awk '
  function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
  }
  function append_value(old, value) {
    value = trim(value)
    return old == "" ? value : old " " value
  }
  function contains_token(value, wanted,    count, tokens, i) {
    count = split(value, tokens, /[[:space:]]+/)
    for (i = 1; i <= count; i++) if (tokens[i] == wanted) return 1
    return 0
  }
  function flush_stanza(    i, uri_match, component_match, enabled_index, enabled_continuation) {
    if (line_count == 0) return
    uri_match = contains_token(values["uris"], "https://enterprise.proxmox.com/debian/pve")
    component_match = contains_token(values["components"], "pve-enterprise")
    if (uri_match && component_match) {
      match_count++
      enabled_index = field_index["enabled"]
      enabled_continuation = continuation_count["enabled"]
      if (enabled_continuation > 0) {
        malformed = 1
      } else if (enabled_index == 0) {
        changed = 1
        for (i = 1; i <= line_count; i++) print lines[i]
        print "Enabled: no"
      } else if (tolower(trim(values["enabled"])) != "no") {
        changed = 1
        for (i = 1; i <= line_count; i++) {
          if (i == enabled_index) print "Enabled: no"
          else print lines[i]
        }
      } else {
        for (i = 1; i <= line_count; i++) print lines[i]
      }
    } else {
      for (i = 1; i <= line_count; i++) print lines[i]
    }
    delete lines
    delete values
    delete field_index
    delete continuation_count
    delete seen
    line_count = 0
    current_field = ""
  }
  {
    if ($0 ~ /^[[:space:]]*$/) {
      flush_stanza()
      print $0
      next
    }
    line_count++
    lines[line_count] = $0
    if ($0 ~ /^[[:space:]]*#/) next
    if ($0 ~ /^[[:space:]]/) {
      if (current_field == "") {
        malformed = 1
        next
      }
      continuation_count[current_field]++
      values[current_field] = append_value(values[current_field], $0)
      next
    }
    if ($0 !~ /^[[:alpha:]][[:alnum:]-]*:/) {
      malformed = 1
      next
    }
    key = tolower($0)
    sub(/:.*/, "", key)
    value = $0
    sub(/^[^:]*:[[:space:]]*/, "", value)
    if (seen[key]++) malformed = 1
    current_field = key
    field_index[key] = line_count
    values[key] = trim(value)
  }
  END {
    flush_stanza()
    if (malformed) exit 2
    if (match_count == 0) exit 3
    if (changed) exit 0
  }
' "$source_file" > "$source_tmp"
awk_status=$?
set -e

case $awk_status in
  0)
    if cmp -s "$source_tmp" "$source_file"; then
      log 'the PVE enterprise source is already disabled.'
      exit 0
    fi
    chmod --reference="$source_file" "$source_tmp"
    chown --reference="$source_file" "$source_tmp"
    mv -f -- "$source_tmp" "$source_file"
    trap - EXIT
    log 'disabled the pve-enterprise deb822 stanza.'
    ;;
  3)
    log 'the canonical file has no matching PVE enterprise stanza; leaving it unchanged.'
    ;;
  *)
    log "ERROR: could not safely parse $source_file; refusing to run apt with an unverified enterprise source." >&2
    exit 1
    ;;
esac
