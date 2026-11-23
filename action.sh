#!/system/bin/sh
PATH="/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH"
case "$0" in
  */*) MODDIR=${0%/*} ;;
  *) MODDIR="." ;;
esac

# shellcheck disable=SC1091
. "$MODDIR/common.sh"

load_config "$MODDIR/config.sh"
MENU_CHANGED=1
ZRAM_STATUS="unchanged"

add_reason() {
  if [ -z "$BOOT_PENDING_REASONS" ]; then
    BOOT_PENDING_REASONS="$1"
  else
    BOOT_PENDING_REASONS="${BOOT_PENDING_REASONS}, $1"
  fi
}

print_status() {
  local mod_ver mem_total_kb mem_avail_kb mem_total_mb mem_avail_mb
  local zram_algo zram_disk_b zram_disk_mb zram_orig_mb zram_compr_mb zram_mem_mb zram_ratio
  local psi_mem_full psi_io_full blk blk_name io_sched io_ra io_stats io_rq_aff
  local vfs_pressure dirty_bg dirty_fg watermark live_swappiness
  local live_usap live_dexopt live_lmkd_low live_lmkd_ratio xposed_mod
  local exp_zram_mb live_inline_on live_usap_on boot_pending BOOT_PENDING_REASONS=""

  mod_ver=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1 | tr -d '\r')
  xposed_mod=$(detect_xposed 2>/dev/null || true)

  mem_total_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
  mem_avail_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
  mem_total_kb=${mem_total_kb:-0}
  mem_avail_kb=${mem_avail_kb:-0}
  mem_total_mb=$((mem_total_kb / 1024))
  mem_avail_mb=$((mem_avail_kb / 1024))

  zram_algo=$(get_zram_live_algo)
  zram_disk_b=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)
  zram_disk_mb=$(awk -v b="$zram_disk_b" 'BEGIN { printf "%.0f\n", b / 1048576 }')
  if [ -r /sys/block/zram0/mm_stat ]; then
    set -- $(cat /sys/block/zram0/mm_stat 2>/dev/null)
    zram_orig_mb=$(awk -v b="${1:-0}" 'BEGIN { printf "%.0f\n", b / 1048576 }')
    zram_compr_mb=$(awk -v b="${2:-0}" 'BEGIN { printf "%.0f\n", b / 1048576 }')
    zram_mem_mb=$(awk -v b="${3:-0}" 'BEGIN { printf "%.0f\n", b / 1048576 }')
    zram_ratio=$(awk -v o="${1:-0}" -v m="${3:-0}" 'BEGIN { if (m > 0) printf "%.2f\n", o / m; else print "0.00" }')
  else
    zram_orig_mb=0; zram_compr_mb=0; zram_mem_mb=0; zram_ratio="0.00"
  fi

  psi_mem_full=$(awk '/^full / { for (i=1;i<=NF;i++) if ($i ~ /^total=/) { sub(/^total=/,"",$i); printf "%.1f\n", $i/1000000; exit } }' /proc/pressure/memory 2>/dev/null)
  psi_io_full=$(awk '/^full / { for (i=1;i<=NF;i++) if ($i ~ /^total=/) { sub(/^total=/,"",$i); printf "%.1f\n", $i/1000000; exit } }' /proc/pressure/io 2>/dev/null)

  blk=$(detect_block_dev 2>/dev/null || true)
  if [ -n "$blk" ]; then
    blk_name=$(basename "$blk")
    io_sched=$(awk '{for(i=1;i<=NF;i++) if($i~/^\[.*\]$/){gsub(/[\[\]]/,"",$i); print $i; exit}}' "$blk/queue/scheduler" 2>/dev/null)
    io_ra=$(cat "$blk/queue/read_ahead_kb" 2>/dev/null || echo 0)
    io_stats=$(cat "$blk/queue/iostats" 2>/dev/null || echo 0)
    io_rq_aff=$(cat "$blk/queue/rq_affinity" 2>/dev/null || echo 0)
  else
    blk_name="none"; io_sched="none"; io_ra="0"; io_stats="0"; io_rq_aff="0"
  fi

  vfs_pressure=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo 0)
  live_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 100)
  dirty_bg=$(awk 'BEGIN {
    getline b < "/proc/sys/vm/dirty_background_bytes"
    getline r < "/proc/sys/vm/dirty_background_ratio"
    if (b + 0 > 0) printf "%.0f MB\n", b / 1048576; else printf "%s%%\n", r
  }' 2>/dev/null)
  dirty_fg=$(awk 'BEGIN {
    getline b < "/proc/sys/vm/dirty_bytes"
    getline r < "/proc/sys/vm/dirty_ratio"
    if (b + 0 > 0) printf "%.0f MB\n", b / 1048576; else printf "%s%%\n", r
  }' 2>/dev/null)
  watermark=$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null || echo 0)

  live_usap=$(getprop dalvik.vm.usap_pool_enabled 2>/dev/null | tr -d '\r')
  live_dexopt=$(getprop dalvik.vm.dex2oat-flags 2>/dev/null | tr -d '\r')
  live_lmkd_low=$(getprop ro.lmk.swap_free_low_percentage 2>/dev/null | tr -d '\r')
  live_lmkd_ratio=$(getprop ro.lmk.swap_compression_ratio 2>/dev/null | tr -d '\r')

  if [ -n "$zram_algo" ] && [ "$zram_algo" != "$ZRAM_ALGO" ]; then
    add_reason "ZRAM algo (${zram_algo} -> ${ZRAM_ALGO})"
  fi
  exp_zram_mb=$((mem_total_mb * ZRAM_SIZE_PCT / 100))
  if [ "$mem_total_mb" -gt 0 ] && awk -v a="$zram_disk_mb" -v b="$exp_zram_mb" 'BEGIN { d=a-b; if(d<0)d=-d; exit(d>32?0:1) }'; then
    add_reason "ZRAM size (${zram_disk_mb}MB -> ~${exp_zram_mb}MB)"
  fi

  if [ -z "$xposed_mod" ]; then
    case "$live_dexopt" in
      *"--inline-max-code-units=0"*) live_inline_on=0 ;;
      *"--inline-max-code-units="*) live_inline_on=1 ;;
      *) live_inline_on=0 ;;
    esac
    if [ "$ART_INLINE" = "enabled" ] && [ "$live_inline_on" -eq 0 ]; then
      add_reason "ART inline"
    elif [ "$ART_INLINE" = "stock" ] && [ "$live_inline_on" -eq 1 ]; then
      add_reason "ART inline"
    fi
  fi

  [ "$live_usap" = "true" ] && live_usap_on=1 || live_usap_on=0
  if [ "$USAP_POOL" = "enabled" ] && [ "$live_usap_on" -eq 0 ]; then
    add_reason "USAP pool"
  elif [ "$USAP_POOL" = "stock" ] && [ "$live_usap_on" -eq 1 ]; then
    add_reason "USAP pool"
  fi

  if [ "$LMKD_TUNING" = "enabled" ] && [ "$live_lmkd_low" != "5" ]; then
    add_reason "LMKD tuning"
  elif [ "$LMKD_TUNING" = "stock" ] && [ "$live_lmkd_low" = "5" ]; then
    add_reason "LMKD tuning"
  fi

  [ -n "$BOOT_PENDING_REASONS" ] && boot_pending=1 || boot_pending=0

  printf 'VERSION=%s\n' "${mod_ver:-unknown}"
  printf 'ZRAM_ALGO=%s\n' "$ZRAM_ALGO"
  printf 'ZRAM_SIZE_PCT=%s\n' "$ZRAM_SIZE_PCT"
  printf 'VM_PROFILE=%s\n' "$VM_PROFILE"
  printf 'VM_SWAPPINESS=%s\n' "$VM_SWAPPINESS"
  printf 'IO_SCHED=%s\n' "$IO_SCHED"
  printf 'IO_READAHEAD_KB=%s\n' "$IO_READAHEAD_KB"
  printf 'ART_INLINE=%s\n' "$ART_INLINE"
  printf 'USAP_POOL=%s\n' "$USAP_POOL"
  printf 'LMKD_TUNING=%s\n' "$LMKD_TUNING"
  printf 'XPOSED_DETECTED=%s\n' "$([ -n "$xposed_mod" ] && echo 1 || echo 0)"
  printf 'XPOSED_MOD=%s\n' "${xposed_mod:-none}"
  printf 'ZRAM_STATUS=%s\n' "$ZRAM_STATUS"
  printf 'LIVE_ZRAM_ALGO=%s\n' "${zram_algo:-none}"
  printf 'LIVE_ZRAM_DISK_MB=%s\n' "${zram_disk_mb:-0}"
  printf 'LIVE_ZRAM_ORIG_MB=%s\n' "${zram_orig_mb:-0}"
  printf 'LIVE_ZRAM_COMPR_MB=%s\n' "${zram_compr_mb:-0}"
  printf 'LIVE_ZRAM_MEM_MB=%s\n' "${zram_mem_mb:-0}"
  printf 'LIVE_ZRAM_RATIO=%s\n' "${zram_ratio:-0.00}"
  printf 'MEM_TOTAL_MB=%s\n' "$mem_total_mb"
  printf 'MEM_AVAIL_MB=%s\n' "$mem_avail_mb"
  printf 'PSI_MEM_FULL_S=%s\n' "${psi_mem_full:-0.0}"
  printf 'PSI_IO_FULL_S=%s\n' "${psi_io_full:-0.0}"
  printf 'BLK_DEV=%s\n' "$blk_name"
  printf 'LIVE_IO_SCHED=%s\n' "${io_sched:-none}"
  printf 'LIVE_IO_RA_KB=%s\n' "$io_ra"
  printf 'LIVE_IO_STATS=%s\n' "$io_stats"
  printf 'LIVE_IO_RQ_AFF=%s\n' "$io_rq_aff"
  printf 'LIVE_VFS_PRESSURE=%s\n' "$vfs_pressure"
  printf 'LIVE_SWAPPINESS=%s\n' "$live_swappiness"
  printf 'LIVE_DIRTY_BG=%s\n' "${dirty_bg:-0}"
  printf 'LIVE_DIRTY=%s\n' "${dirty_fg:-0}"
  printf 'LIVE_WATERMARK=%s\n' "$watermark"
  printf 'LIVE_USAP=%s\n' "${live_usap:-unset}"
  printf 'LIVE_DEX2OAT_FLAGS=%s\n' "${live_dexopt:-unset}"
  printf 'LIVE_LMKD_SWAP_LOW=%s\n' "${live_lmkd_low:-unset}"
  printf 'LIVE_LMKD_RATIO=%s\n' "${live_lmkd_ratio:-unset}"
  printf 'BOOT_PENDING=%s\n' "$boot_pending"
  printf 'BOOT_PENDING_REASONS=%s\n' "${BOOT_PENDING_REASONS:-none}"
}

apply_live() {
  save_config "$MODDIR/config.sh"
  generate_system_prop "$MODDIR"
  apply_vm_io
  apply_zram live
}

case "${1:-}" in
  --status)
    print_status
    exit 0
    ;;
  --set)
    if [ "$#" -ne 10 ]; then
      echo "Usage: $0 --set <zstd|lz4> <50|75|100> <stock|responsive|aggressive> <100|130|160> <kyber|mq-deadline|none> <64|128|256> <enabled|stock> <enabled|stock> <enabled|stock>" >&2
      exit 1
    fi
    case "$2" in zstd|lz4) ;; *) echo "Invalid zram algo: $2" >&2; exit 1 ;; esac
    case "$3" in 50|75|100) ;; *) echo "Invalid zram size: $3" >&2; exit 1 ;; esac
    case "$4" in stock|responsive|aggressive) ;; *) echo "Invalid VM profile: $4" >&2; exit 1 ;; esac
    case "$5" in 100|130|160) ;; *) echo "Invalid swappiness: $5" >&2; exit 1 ;; esac
    case "$6" in kyber|mq-deadline|none) ;; *) echo "Invalid IO scheduler: $6" >&2; exit 1 ;; esac
    case "$7" in 64|128|256) ;; *) echo "Invalid read-ahead: $7" >&2; exit 1 ;; esac
    case "$8" in enabled|stock) ;; *) echo "Invalid ART inline option: $8" >&2; exit 1 ;; esac
    case "$9" in enabled|stock) ;; *) echo "Invalid USAP option: $9" >&2; exit 1 ;; esac
    case "${10}" in enabled|stock) ;; *) echo "Invalid LMKD option: ${10}" >&2; exit 1 ;; esac
    ZRAM_ALGO="$2"
    ZRAM_SIZE_PCT="$3"
    VM_PROFILE="$4"
    VM_SWAPPINESS="$5"
    IO_SCHED="$6"
    IO_READAHEAD_KB="$7"
    ART_INLINE="$8"
    USAP_POOL="$9"
    LMKD_TUNING="${10}"
    apply_live
    print_status
    exit 0
    ;;
  --compact)
    write_node /sys/block/zram0/compact 1
    print_status
    exit 0
    ;;
  --fstrim)
    fstrim_out=""
    if command -v fstrim >/dev/null 2>&1; then
      out_data=$(fstrim -v /data 2>&1 || true)
      out_cache=$(fstrim -v /cache 2>&1 || true)
      fstrim_out=$(printf '%s; %s' "$out_data" "$out_cache" | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')
    elif command -v sm >/dev/null 2>&1; then
      sm fstrim >/dev/null 2>&1 || true
      fstrim_out="sm fstrim completed"
    else
      echo "Error: neither fstrim nor sm utility available." >&2
      exit 1
    fi
    printf 'FSTRIM_OK=1\n'
    printf 'FSTRIM_SUMMARY=%s\n' "$fstrim_out"
    exit 0
    ;;
  --dexopt)
    if command -v cmd >/dev/null 2>&1; then
      ( cmd package bg-dexopt-job </dev/null >/dev/null 2>&1 ) &
      printf 'DEXOPT_TRIGGERED=1\n'
      exit 0
    fi
    echo "Error: cmd utility not available." >&2
    exit 1
    ;;
  --reboot)
    ( sleep 1; svc power reboot >/dev/null 2>&1 || reboot ) </dev/null >/dev/null 2>&1 &
    printf 'REBOOT_TRIGGERED=1\n'
    exit 0
    ;;
  --webui)
    MOD_ID=$(sed -n 's/^id=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1 | tr -d '\r')
    if launch_webui "${MOD_ID:-MT8188RamIoArtOptimizer}"; then
      exit 0
    fi
    echo "Error: No WebUI app (KsuWebUI / WebUI X) installed." >&2
    exit 1
    ;;
  --preset)
    if [ -z "${2:-}" ] || ! apply_preset "$2"; then
      echo "Usage: $0 [--preset multitasking|lowlatency|maxcap|stock | --set ... | --status | --compact | --fstrim | --dexopt | --reboot | --webui | --apply]" >&2
      exit 1
    fi
    ;;
  --apply)
    ;;
  "")
    run_interactive_menu action
    ;;
  *)
    echo "Usage: $0 [--preset multitasking|lowlatency|maxcap|stock | --set ... | --status | --compact | --fstrim | --dexopt | --reboot | --webui | --apply]" >&2
    exit 1
    ;;
esac

if [ "$MENU_CHANGED" -eq 1 ]; then
  apply_live
  echo ""
  echo "- Applied Configuration:"
  print_config_summary
  echo "  - ZRAM Status  : ${ZRAM_STATUS}"
  if [ "$ZRAM_STATUS" = "deferred_reboot" ]; then
    echo "  * ZRAM change deferred until reboot (swap currently holds active pages)."
  fi
  echo "  * ART / USAP / LMKD prop changes require a reboot to take effect."
else
  echo ""
  echo "- Kept existing configuration (no changes made)."
fi

if [ -z "${MMRL:-}" ] && [ -z "${KSU_NEXT:-}" ] && { [ "${KSU:-}" = "true" ] || [ "${APATCH:-}" = "true" ]; }; then
  sleep 2
fi

exit 0
