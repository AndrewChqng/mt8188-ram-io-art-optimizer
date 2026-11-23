#!/system/bin/sh
PATH="/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH"
case "$0" in
  */*) MODDIR=${0%/*} ;;
  *) MODDIR="." ;;
esac

# shellcheck disable=SC1091
. "$MODDIR/common.sh"

load_config "$MODDIR/config.sh"
apply_zram boot
