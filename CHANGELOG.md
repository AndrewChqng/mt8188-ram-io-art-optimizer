# Changelog

## v1.1 (versionCode 110)

- **Xposed / Vector Auto-Detection**: Automatically detects active `zygisk_vector`, `zygisk_lsposed`, or `riru_lsposed` modules and leaves `dalvik.vm.dex2oat-flags` untouched so Xposed hooks stay intact without triggering false `Reboot Pending` alerts.
- **VM Swappiness Control**: Added live customizable `vm.swappiness` (`100` / `130` / `160`) to take full advantage of ~`4×` `zstd` ZRAM compression before evicting clean file cache.
- **LMKD Multitasking Tuning**: Added boot-time `ro.lmk.*` tuning (`swap_free_low_percentage=5`, `psi_partial_stall_ms=100`, `psi_complete_stall_ms=700`, `thrashing_limit=100`, `swap_compression_ratio=3|4`) so Android utilizes expanded ZRAM before killing cached apps.
- **On-Demand eMMC Trim**: Added `action.sh --fstrim` and WebUI **Trim eMMC** button (`/data` and `/cache`).
- **Improved Pending-Reboot UX**: WebUI now displays the exact `BOOT_PENDING_REASONS` and includes a two-step confirmation **Reboot Now** button (`action.sh --reboot`).

## v1.0 (versionCode 100)

- Initial release targeting MediaTek MT8188 / 4 GB RAM + eMMC devices (verified on Amazon Fire Max 11 `sunstone` / `KFSNWI`).
- Reconfigures ZRAM (`zstd`/`lz4` and `50%`/`75%`/`100%` sizing) in `post-fs-data.sh` with safe swapoff/rollback guards.
- Smooths VM writeback (`dirty_background_bytes` / `dirty_bytes`), slab cache retention (`vfs_cache_pressure`), and background reclaim (`watermark_scale_factor`).
- Tunes eMMC (`mmcblk0`) queue scheduler (`kyber` / `mq-deadline` / `none`), read-ahead, `iostats`, and `rq_affinity`.
- Restores ART `dex2oat` method inlining (`--inline-max-code-units=32`) and enables USAP pre-forked Zygote pool (`usap_pool_enabled=true`, max 2 workers).
- Added offline WebUI (`webroot/`), install/action-time volume-button menus, CLI subcommands, and Magisk/KernelSU/APatch `updateJson` auto-updates.
