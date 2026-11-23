DEVICES="$T2_PARTMAN_ROOT/devices"
TAB=$(printf '\t')
RET=

db_get() {
  case "$1" in
    partman-auto/disk) RET=/dev/nvme0n1 ;;
    partman-auto/init_automatically_partition) RET=biggest_free ;;
    partman-auto/method) RET= ;;
    partman-auto/choose_recipe) RET=pve-final ;;
    partman-auto/expert_recipe) RET='pve-final :: fixture recipe' ;;
    *) RET= ;;
  esac
}

open_dialog() {
  [ "$1" = PARTITION_INFO ] && [ "$2" = "$PARTMAN_FREE_ID" ]
}

read_line() {
  names="$*"
  set -- 1 "$PARTMAN_FREE_ID" "$PARTMAN_FREE_BYTES" primary free /dev/mock fixture
  while [ -n "$names" ]; do
    case "$names" in
      *' '*) name=${names%% *}; names=${names#* } ;;
      *) name=$names; names= ;;
    esac
    eval "$name=\$1"
    shift
  done
}

close_dialog() { :; }
longint_le() { [ "$1" -le "$2" ]; }
