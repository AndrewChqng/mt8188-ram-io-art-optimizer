#!/system/bin/sh
PATH="/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH"
case "$0" in
  */*) MODDIR=${0%/*} ;;
  *) MODDIR="." ;;
esac

# shellcheck disable=SC1091
. "$MODDIR/common.sh"

i=0
while [ "$i" -lt 10 ]; do
  detect_block_dev >/dev/null 2>&1 && break
  sleep 1
  i=$((i + 1))
done

load_config "$MODDIR/config.sh"
apply_vm_io
