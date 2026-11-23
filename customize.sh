#!/system/bin/sh
PATH="/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH"

MOD_ID=$(sed -n 's/^id=//p' "$MODPATH/module.prop" | head -n 1 | tr -d '\r')
MOD_VER=$(sed -n 's/^version=//p' "$MODPATH/module.prop" | head -n 1 | tr -d '\r')

ui_print "**************************************************"
ui_print " MT8188 RAM, eMMC I/O & ART Optimizer (${MOD_VER:-v1.0}) "
ui_print " ZRAM (zstd/lz4) + VM/eMMC + ART Inline + USAP    "
ui_print "**************************************************"

# shellcheck disable=SC1091
. "$MODPATH/common.sh"

OLD_CONFIG="/data/adb/modules/${MOD_ID:-MT8188RamIoArtOptimizer}/config.sh"
if [ -r "$OLD_CONFIG" ]; then
  HAS_EXISTING_CONFIG=1
  load_config "$OLD_CONFIG"
else
  HAS_EXISTING_CONFIG=0
  set_default_config
fi

run_interactive_menu install
save_config "$MODPATH/config.sh"
generate_system_prop "$MODPATH"

ui_print ""
ui_print "- Final Configuration:"
print_config_summary
ui_print "- Saved to config.sh (re-configure anytime via Action / WebUI)."

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
