#!/system/bin/sh
# Shared configuration, ZRAM/VM/eMMC/ART appliers, and volume-key UI for MT8188RamIoArtOptimizer.

print_msg() {
  if command -v ui_print >/dev/null 2>&1; then
    ui_print "$1"
  else
    printf '%s\n' "$1"
  fi
}

set_default_config() {
  ZRAM_ALGO="zstd"
  ZRAM_SIZE_PCT=75
  VM_PROFILE="responsive"
  IO_SCHED="kyber"
  IO_READAHEAD_KB=128
  ART_INLINE="enabled"
  USAP_POOL="enabled"
}

sanitize_config() {
  case "${ZRAM_ALGO:-}" in
    zstd|lz4) ;;
    *) ZRAM_ALGO="zstd" ;;
  esac
  case "${ZRAM_SIZE_PCT:-}" in
    50|75|100) ;;
    *) ZRAM_SIZE_PCT=75 ;;
  esac
  case "${VM_PROFILE:-}" in
    stock|responsive|aggressive) ;;
    *) VM_PROFILE="responsive" ;;
  esac
  case "${IO_SCHED:-}" in
    kyber|mq-deadline|none) ;;
    *) IO_SCHED="kyber" ;;
  esac
  case "${IO_READAHEAD_KB:-}" in
    64|128|256) ;;
    *) IO_READAHEAD_KB=128 ;;
  esac
  case "${ART_INLINE:-}" in
    enabled|stock) ;;
    *) ART_INLINE="enabled" ;;
  esac
  case "${USAP_POOL:-}" in
    enabled|stock) ;;
    *) USAP_POOL="enabled" ;;
  esac
}

load_config() {
  local cfg="$1"
  set_default_config
  if [ -r "$cfg" ]; then
    # shellcheck disable=SC1090
    . "$cfg" 2>/dev/null || true
  fi
  sanitize_config
}

save_config() {
  local cfg="$1"
  sanitize_config
  cat > "$cfg" << EOF
ZRAM_ALGO=$ZRAM_ALGO
ZRAM_SIZE_PCT=$ZRAM_SIZE_PCT
VM_PROFILE=$VM_PROFILE
IO_SCHED=$IO_SCHED
IO_READAHEAD_KB=$IO_READAHEAD_KB
ART_INLINE=$ART_INLINE
USAP_POOL=$USAP_POOL
EOF
}

apply_preset() {
  case "$1" in
    multitasking)
      ZRAM_ALGO="zstd"
      ZRAM_SIZE_PCT=75
      VM_PROFILE="responsive"
      IO_SCHED="kyber"
      IO_READAHEAD_KB=128
      ART_INLINE="enabled"
      USAP_POOL="enabled"
      ;;
    lowlatency)
      ZRAM_ALGO="lz4"
      ZRAM_SIZE_PCT=75
      VM_PROFILE="responsive"
      IO_SCHED="none"
      IO_READAHEAD_KB=64
      ART_INLINE="enabled"
      USAP_POOL="enabled"
      ;;
    maxcap)
      ZRAM_ALGO="zstd"
      ZRAM_SIZE_PCT=100
      VM_PROFILE="aggressive"
      IO_SCHED="kyber"
      IO_READAHEAD_KB=128
      ART_INLINE="enabled"
      USAP_POOL="enabled"
      ;;
    stock)
      ZRAM_ALGO="lz4"
      ZRAM_SIZE_PCT=50
      VM_PROFILE="stock"
      IO_SCHED="mq-deadline"
      IO_READAHEAD_KB=128
      ART_INLINE="stock"
      USAP_POOL="stock"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

format_config_oneliner() {
  printf 'ZRAM %s %s%% | VM %s | IO %s/%sKB | ART %s | USAP %s' \
    "$ZRAM_ALGO" "$ZRAM_SIZE_PCT" "$VM_PROFILE" "$IO_SCHED" "$IO_READAHEAD_KB" "$ART_INLINE" "$USAP_POOL"
}

print_config_summary() {
  print_msg "  - ZRAM         : ${ZRAM_ALGO} @ ${ZRAM_SIZE_PCT}% RAM"
  print_msg "  - VM Writeback : ${VM_PROFILE}"
  print_msg "  - Storage Queue: ${IO_SCHED} / ${IO_READAHEAD_KB} KB read-ahead"
  print_msg "  - ART Inlining : ${ART_INLINE}"
  print_msg "  - USAP Pool    : ${USAP_POOL}"
}

detect_block_dev() {
  if [ -d /sys/block/mmcblk0/queue ]; then
    printf '/sys/block/mmcblk0\n'
    return 0
  fi
  if [ -d /sys/block/sda/queue ]; then
    printf '/sys/block/sda\n'
    return 0
  fi
  return 1
}

write_node() {
  local node="$1"
  local val="$2"
  [ -w "$node" ] || return 0
  printf '%s' "$val" > "$node" 2>/dev/null || true
}

get_zram_live_algo() {
  awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^\[.*\]$/) {
        gsub(/[\[\]]/, "", $i)
        print $i
        exit
      }
    }
  }' /sys/block/zram0/comp_algorithm 2>/dev/null
}

apply_zram() {
  local mode="${1:-boot}"
  local mem_total_kb swap_total_kb swap_free_kb mem_avail_kb swap_used_kb
  local target_bytes cur_bytes target_algo cur_algo avail_algos fallback_bytes
  ZRAM_STATUS="skipped"

  sanitize_config

  [ -b /dev/block/zram0 ] && [ -d /sys/block/zram0 ] || {
    ZRAM_STATUS="unavailable"
    return 0
  }

  mem_total_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
  [ -n "$mem_total_kb" ] && [ "$mem_total_kb" -gt 0 ] 2>/dev/null || {
    ZRAM_STATUS="unavailable"
    return 0
  }

  target_bytes=$(awk -v kb="$mem_total_kb" -v pct="$ZRAM_SIZE_PCT" \
    'BEGIN { b = int((kb * pct / 100) * 1024); b = int(b / 4096) * 4096; printf "%.0f\n", b }')

  avail_algos=$(tr -d '[]' < /sys/block/zram0/comp_algorithm 2>/dev/null || echo "lz4")
  case " $avail_algos " in
    *" $ZRAM_ALGO "*) target_algo="$ZRAM_ALGO" ;;
    *) target_algo="lz4" ;;
  esac

  cur_algo=$(get_zram_live_algo)
  cur_bytes=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)

  if [ "$cur_algo" = "$target_algo" ] && awk -v c="$cur_bytes" -v t="$target_bytes" \
    'BEGIN { d = c - t; if (d < 0) d = -d; exit (d <= 4194304 ? 0 : 1) }'; then
    ZRAM_STATUS="unchanged"
    return 0
  fi

  swap_total_kb=$(awk '/^SwapTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
  swap_free_kb=$(awk '/^SwapFree:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
  mem_avail_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
  swap_total_kb=${swap_total_kb:-0}
  swap_free_kb=${swap_free_kb:-0}
  mem_avail_kb=${mem_avail_kb:-0}
  swap_used_kb=$((swap_total_kb - swap_free_kb))
  [ "$swap_used_kb" -lt 0 ] && swap_used_kb=0

  if [ "$mode" = "live" ]; then
    if [ $((swap_used_kb + 524288)) -ge "$mem_avail_kb" ]; then
      ZRAM_STATUS="deferred_reboot"
      return 0
    fi
  else
    if [ "$swap_used_kb" -ge 262144 ] && [ $((swap_used_kb + 262144)) -ge "$mem_avail_kb" ]; then
      ZRAM_STATUS="deferred_reboot"
      return 0
    fi
  fi

  swapoff /dev/block/zram0 2>/dev/null || true
  if printf '1' > /sys/block/zram0/reset 2>/dev/null &&
     printf '%s' "$target_algo" > /sys/block/zram0/comp_algorithm 2>/dev/null &&
     printf '%s' "$target_bytes" > /sys/block/zram0/disksize 2>/dev/null &&
     mkswap /dev/block/zram0 >/dev/null 2>&1 &&
     swapon /dev/block/zram0 >/dev/null 2>&1; then
    ZRAM_STATUS="applied"
  else
    printf '1' > /sys/block/zram0/reset 2>/dev/null || true
    printf 'lz4' > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    fallback_bytes=$(awk -v kb="$mem_total_kb" \
      'BEGIN { printf "%.0f\n", int((kb * 50 / 100) * 1024 / 4096) * 4096 }')
    printf '%s' "$fallback_bytes" > /sys/block/zram0/disksize 2>/dev/null || true
    mkswap /dev/block/zram0 >/dev/null 2>&1 || true
    swapon /dev/block/zram0 >/dev/null 2>&1 || true
    ZRAM_STATUS="failed_reverted"
  fi
  return 0
}

apply_vm_io() {
  local blk q avail_scheds

  sanitize_config

  write_node /proc/sys/vm/page-cluster 0
  write_node /sys/kernel/mm/swap/vma_ra_enabled false
  write_node /proc/sys/vm/swappiness 100

  case "$VM_PROFILE" in
    stock)
      write_node /proc/sys/vm/vfs_cache_pressure 100
      write_node /proc/sys/vm/dirty_background_ratio 10
      write_node /proc/sys/vm/dirty_ratio 20
      write_node /proc/sys/vm/watermark_scale_factor 10
      ;;
    responsive)
      write_node /proc/sys/vm/vfs_cache_pressure 55
      write_node /proc/sys/vm/dirty_background_bytes 16777216
      write_node /proc/sys/vm/dirty_bytes 67108864
      write_node /proc/sys/vm/watermark_scale_factor 25
      ;;
    aggressive)
      write_node /proc/sys/vm/vfs_cache_pressure 45
      write_node /proc/sys/vm/dirty_background_bytes 12582912
      write_node /proc/sys/vm/dirty_bytes 50331648
      write_node /proc/sys/vm/watermark_scale_factor 40
      ;;
  esac

  blk=$(detect_block_dev 2>/dev/null || true)
  if [ -n "$blk" ] && [ -d "$blk/queue" ]; then
    q="$blk/queue"
    avail_scheds=$(tr -d '[]' < "$q/scheduler" 2>/dev/null || true)
    case " $avail_scheds " in
      *" $IO_SCHED "*) write_node "$q/scheduler" "$IO_SCHED" ;;
    esac
    write_node "$q/read_ahead_kb" "$IO_READAHEAD_KB"
    write_node "$q/add_random" 0
    if [ "$VM_PROFILE" = "stock" ] && [ "$IO_SCHED" = "mq-deadline" ]; then
      write_node "$q/iostats" 1
      write_node "$q/rq_affinity" 1
    else
      write_node "$q/iostats" 0
      write_node "$q/rq_affinity" 2
    fi
  fi
}

generate_system_prop() {
  local moddir="$1"
  local tmp_prop="$moddir/system.prop.tmp.$$"

  sanitize_config

  if [ "$ART_INLINE" = "stock" ] && [ "$USAP_POOL" = "stock" ]; then
    rm -f "$moddir/system.prop" "$tmp_prop"
    return 0
  fi

  : > "$tmp_prop"
  if [ "$ART_INLINE" = "enabled" ]; then
    printf 'dalvik.vm.dex2oat-flags=--inline-max-code-units=32\n' >> "$tmp_prop"
  fi
  if [ "$USAP_POOL" = "enabled" ]; then
    printf 'dalvik.vm.usap_pool_enabled=true\n' >> "$tmp_prop"
    printf 'dalvik.vm.usap_pool_size_max=2\n' >> "$tmp_prop"
    printf 'dalvik.vm.usap_pool_size_min=1\n' >> "$tmp_prop"
  fi
  mv -f "$tmp_prop" "$moddir/system.prop"
}

detect_webui_app() {
  if ! command -v pm >/dev/null 2>&1; then
    return 1
  fi
  if pm path io.github.a13e300.ksuwebui >/dev/null 2>&1; then
    printf 'ksuwebui\n'
    return 0
  fi
  if pm path com.dergoogler.mmrl.wx >/dev/null 2>&1; then
    printf 'webuix\n'
    return 0
  fi
  return 1
}

launch_webui() {
  local mod_id="$1"
  local app=""
  app=$(detect_webui_app 2>/dev/null || true)
  command -v am >/dev/null 2>&1 || return 1
  case "$app" in
    ksuwebui)
      print_msg "- Launching WebUI in KsuWebUIStandalone..."
      am start -n "io.github.a13e300.ksuwebui/.WebUIActivity" -e id "$mod_id" >/dev/null 2>&1
      return $?
      ;;
    webuix)
      print_msg "- Launching WebUI in WebUI X..."
      am start -n "com.dergoogler.mmrl.wx/.ui.activity.webui.WebUIActivity" -e MOD_ID "$mod_id" >/dev/null 2>&1
      return $?
      ;;
  esac
  return 1
}

# Wait for a single Volume Up (0), Volume Down (1), or timeout/unavailable (2).
choose_key() {
  local secs="${1:-15}"
  local fifo=""
  local ge_pid=""
  local line=""
  local rc=2

  command -v getevent >/dev/null 2>&1 || return 2

  for dir in /dev /data/local/tmp /tmp; do
    [ -d "$dir" ] && [ -w "$dir" ] || continue
    fifo="$dir/.hvb_ram_fifo_$$"
    rm -f "$fifo" 2>/dev/null || true
    if mkfifo "$fifo" 2>/dev/null; then
      break
    fi
    fifo=""
  done
  [ -n "$fifo" ] || return 2

  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" getevent -lq > "$fifo" 2>/dev/null &
  else
    getevent -lq > "$fifo" 2>/dev/null &
  fi
  ge_pid=$!

  while IFS= read -r line; do
    case "$line" in
      *KEY_VOLUMEUP*DOWN*|*" 0001 0073 00000001"*)
        rc=0
        break
        ;;
      *KEY_VOLUMEDOWN*DOWN*|*" 0001 0072 00000001"*)
        rc=1
        break
        ;;
    esac
  done < "$fifo"

  if [ -n "$ge_pid" ]; then
    pkill -P "$ge_pid" 2>/dev/null || true
    kill -TERM "-$ge_pid" 2>/dev/null || true
    kill -TERM "$ge_pid" 2>/dev/null || true
    wait "$ge_pid" 2>/dev/null || true
  fi
  rm -f "$fifo" 2>/dev/null || true

  if [ "$rc" -ne 2 ]; then
    usleep 150000 2>/dev/null || sleep 0.15 2>/dev/null || true
  fi
  return "$rc"
}

prompt_choice() {
  local title="$1"
  local idx="$2"
  shift 2
  local count="$#"
  local key_rc=2
  local current_label=""
  local n=0

  [ "$count" -gt 0 ] || return 1
  [ "$idx" -ge "$count" ] 2>/dev/null && idx=0

  print_msg ""
  print_msg "$title"

  while :; do
    n=0
    for lbl in "$@"; do
      if [ "$n" -eq "$idx" ]; then
        current_label="$lbl"
        break
      fi
      n=$((n + 1))
    done

    print_msg "  > [$((idx + 1))/${count}] ${current_label}"
    choose_key 15
    key_rc=$?
    if [ "$key_rc" -eq 0 ]; then
      idx=$(( (idx + 1) % count ))
    elif [ "$key_rc" -eq 1 ]; then
      print_msg "  * Selected: ${current_label}"
      break
    else
      print_msg "  * Timeout/Auto-confirmed: ${current_label}"
      break
    fi
  done

  CHOICE_IDX="$idx"
}

run_custom_menu() {
  local start_idx=0

  # 1. ZRAM Algorithm
  case "$ZRAM_ALGO" in zstd) start_idx=0 ;; lz4) start_idx=1 ;; esac
  prompt_choice "[1/7] ZRAM Compression Algorithm:" "$start_idx" \
    "zstd (higher compression ratio, more multitasking headroom)" \
    "lz4 (lowest CPU swap latency)"
  case "$CHOICE_IDX" in 0) ZRAM_ALGO="zstd" ;; 1) ZRAM_ALGO="lz4" ;; esac

  # 2. ZRAM Size
  case "$ZRAM_SIZE_PCT" in 75) start_idx=0 ;; 100) start_idx=1 ;; 50) start_idx=2 ;; esac
  prompt_choice "[2/7] ZRAM Size (% of RAM):" "$start_idx" \
    "75% (~2.8 GB)" \
    "100% (~3.7 GB)" \
    "50% (~1.85 GB stock)"
  case "$CHOICE_IDX" in 0) ZRAM_SIZE_PCT=75 ;; 1) ZRAM_SIZE_PCT=100 ;; 2) ZRAM_SIZE_PCT=50 ;; esac

  # 3. VM Writeback Profile
  case "$VM_PROFILE" in responsive) start_idx=0 ;; aggressive) start_idx=1 ;; stock) start_idx=2 ;; esac
  prompt_choice "[3/7] VM Writeback & Reclaim Profile:" "$start_idx" \
    "Responsive (16/64 MB dirty cap, vfs=55, watermark=25)" \
    "Aggressive (12/48 MB dirty cap, vfs=45, watermark=40)" \
    "Stock (10%/20% dirty ratios, vfs=100, watermark=10)"
  case "$CHOICE_IDX" in 0) VM_PROFILE="responsive" ;; 1) VM_PROFILE="aggressive" ;; 2) VM_PROFILE="stock" ;; esac

  # 4. eMMC Scheduler
  case "$IO_SCHED" in kyber) start_idx=0 ;; none) start_idx=1 ;; mq-deadline) start_idx=2 ;; esac
  prompt_choice "[4/7] Storage I/O Scheduler:" "$start_idx" \
    "kyber (low-latency token scheduler)" \
    "none (passthrough, minimal CPU overhead)" \
    "mq-deadline (stock)"
  case "$CHOICE_IDX" in 0) IO_SCHED="kyber" ;; 1) IO_SCHED="none" ;; 2) IO_SCHED="mq-deadline" ;; esac

  # 5. Read-Ahead
  case "$IO_READAHEAD_KB" in 128) start_idx=0 ;; 64) start_idx=1 ;; 256) start_idx=2 ;; esac
  prompt_choice "[5/7] Storage Read-Ahead:" "$start_idx" \
    "128 KB (balanced)" \
    "64 KB (lowest random read overhead)" \
    "256 KB (larger sequential read-ahead)"
  case "$CHOICE_IDX" in 0) IO_READAHEAD_KB=128 ;; 1) IO_READAHEAD_KB=64 ;; 2) IO_READAHEAD_KB=256 ;; esac

  # 6. ART Method Inlining
  case "$ART_INLINE" in enabled) start_idx=0 ;; stock) start_idx=1 ;; esac
  prompt_choice "[6/7] ART dex2oat Method Inlining (reboot):" "$start_idx" \
    "Enabled (--inline-max-code-units=32)" \
    "Stock (--inline-max-code-units=0 / disabled)"
  case "$CHOICE_IDX" in 0) ART_INLINE="enabled" ;; 1) ART_INLINE="stock" ;; esac

  # 7. USAP Pool
  case "$USAP_POOL" in enabled) start_idx=0 ;; stock) start_idx=1 ;; esac
  prompt_choice "[7/7] USAP Pre-forked Zygote Pool (reboot):" "$start_idx" \
    "Enabled (faster cold app launches, max 2 workers)" \
    "Stock (disabled)"
  case "$CHOICE_IDX" in 0) USAP_POOL="enabled" ;; 1) USAP_POOL="stock" ;; esac
}

run_interactive_menu() {
  local mode="$1"
  local existing_summary=""
  local webui_app=""
  local mod_id=""
  MENU_CHANGED=1

  print_msg ""
  print_msg "================================================="
  print_msg " MT8188 RAM, I/O & ART Optimizer - Options"
  print_msg " [Vol+] Next option | [Vol-] Confirm | 15s Timeout"
  print_msg "================================================="

  if [ "$mode" = "action" ] || [ "${HAS_EXISTING_CONFIG:-0}" -eq 1 ]; then
    existing_summary=$(format_config_oneliner)
    print_msg "Current: ${existing_summary}"
  fi

  if [ "$mode" = "action" ]; then
    webui_app=$(detect_webui_app 2>/dev/null || true)
    if [ -n "$webui_app" ]; then
      prompt_choice "Select Action / Preset:" 0 \
        "Keep current / Cancel (no changes)" \
        "Open WebUI (KsuWebUI / WebUI X)" \
        "Multitasking (default) - zstd 75% | responsive | kyber | ART+USAP ON" \
        "Low Latency - lz4 75% | responsive | none/64KB | ART+USAP ON" \
        "Max Capacity - zstd 100% | aggressive | kyber | ART+USAP ON" \
        "Stock - lz4 50% | stock VM | mq-deadline | ART+USAP OFF" \
        "Custom (configure all 7 options individually)"
      case "$CHOICE_IDX" in
        0) MENU_CHANGED=0; return 0 ;;
        1)
          mod_id=$(sed -n 's/^id=//p' "${MODDIR:-/data/adb/modules/MT8188RamIoArtOptimizer}/module.prop" 2>/dev/null | head -n 1 | tr -d '\r')
          launch_webui "${mod_id:-MT8188RamIoArtOptimizer}" || print_msg "! Failed to launch WebUI."
          MENU_CHANGED=0
          return 0
          ;;
        2) apply_preset multitasking ;;
        3) apply_preset lowlatency ;;
        4) apply_preset maxcap ;;
        5) apply_preset stock ;;
        6) run_custom_menu ;;
      esac
    else
      prompt_choice "Select Action / Preset:" 0 \
        "Keep current / Cancel (no changes)" \
        "Multitasking (default) - zstd 75% | responsive | kyber | ART+USAP ON" \
        "Low Latency - lz4 75% | responsive | none/64KB | ART+USAP ON" \
        "Max Capacity - zstd 100% | aggressive | kyber | ART+USAP ON" \
        "Stock - lz4 50% | stock VM | mq-deadline | ART+USAP OFF" \
        "Custom (configure all 7 options individually)"
      case "$CHOICE_IDX" in
        0) MENU_CHANGED=0; return 0 ;;
        1) apply_preset multitasking ;;
        2) apply_preset lowlatency ;;
        3) apply_preset maxcap ;;
        4) apply_preset stock ;;
        5) run_custom_menu ;;
      esac
    fi
  elif [ "${HAS_EXISTING_CONFIG:-0}" -eq 1 ]; then
    prompt_choice "Select Configuration Preset:" 0 \
      "Keep existing (${existing_summary})" \
      "Multitasking (default) - zstd 75% | responsive | kyber | ART+USAP ON" \
      "Low Latency - lz4 75% | responsive | none/64KB | ART+USAP ON" \
      "Max Capacity - zstd 100% | aggressive | kyber | ART+USAP ON" \
      "Stock - lz4 50% | stock VM | mq-deadline | ART+USAP OFF" \
      "Custom (configure all 7 options individually)"
    case "$CHOICE_IDX" in
      0) ;;
      1) apply_preset multitasking ;;
      2) apply_preset lowlatency ;;
      3) apply_preset maxcap ;;
      4) apply_preset stock ;;
      5) run_custom_menu ;;
    esac
  else
    prompt_choice "Select Configuration Preset:" 0 \
      "Multitasking (default) - zstd 75% | responsive | kyber | ART+USAP ON" \
      "Low Latency - lz4 75% | responsive | none/64KB | ART+USAP ON" \
      "Max Capacity - zstd 100% | aggressive | kyber | ART+USAP ON" \
      "Stock - lz4 50% | stock VM | mq-deadline | ART+USAP OFF" \
      "Custom (configure all 7 options individually)"
    case "$CHOICE_IDX" in
      0) apply_preset multitasking ;;
      1) apply_preset lowlatency ;;
      2) apply_preset maxcap ;;
      3) apply_preset stock ;;
      4) run_custom_menu ;;
    esac
  fi

  sanitize_config
  return 0
}
