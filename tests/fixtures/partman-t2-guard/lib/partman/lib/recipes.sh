decode_recipe() {
  scheme=$(printf '%s\n' \
    '512 512 512 fat32 $iflabel{ gpt } method{ efi } format{ }' \
    '1024 1536 1536 ext4 method{ format } mountpoint{ /boot }' \
    '4096 4096 4096 linux-swap method{ swap }' \
    '20480 20480 32768 ext4 method{ format } mountpoint{ / }' \
    '1 1 -1 free $primary{ } method{ lvm } vg_name{ pve }')
}

filter_reused() { :; }

min_size() {
  printf '%s\n' "$scheme" | awk '{ total += $1 } END { print total }'
}

foreach_partition() {
  doing=$1
  saved_ifs=$IFS
  newline=$(printf '\n.')
  newline=${newline%.}
  IFS=$newline
  remaining=$(printf '%s\n' "$scheme" | wc -l)
  for partition in $scheme; do
    IFS=$saved_ifs
    if [ "$remaining" -gt 1 ]; then last=no; else last=yes; fi
    set -- $partition
    eval "$doing"
    remaining=$((remaining - 1))
    IFS=$newline
  done
  IFS=$saved_ifs
}
