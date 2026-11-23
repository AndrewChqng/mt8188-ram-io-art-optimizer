# Changelog

## v1.0 (versionCode 100)

- Initial release targeting MediaTek MT8188 / 4 GB RAM + eMMC devices (verified on Amazon Fire Max 11 `sunstone` / `KFSNWI`).
- Reconfigures ZRAM (`zstd`/`lz4` and `50%`/`75%`/`100%` sizing) in `post-fs-data.sh` with safe swapoff/rollback guards.
- Smooths VM writeback (`dirty_background_bytes` / `dirty_bytes`), slab cache retention (`vfs_cache_pressure`), and background reclaim (`watermark_scale_factor`).
- Tunes eMMC (`mmcblk0`) queue scheduler (`kyber` / `mq-deadline` / `none`), read-ahead, `iostats`, and `rq_affinity`.
- Restores ART `dex2oat` method inlining (`--inline-max-code-units=32`) and enables USAP pre-forked Zygote pool (`usap_pool_enabled=true`, max 2 workers).
- Added offline WebUI (`webroot/`), install/action-time volume-button menus, CLI subcommands, and Magisk/KernelSU/APatch `updateJson` auto-updates.
