# MT8188 RAM, eMMC I/O & ART Optimizer (`MT8188RamIoArtOptimizer`)

A systemless **Magisk / KernelSU / APatch** optimization module with an offline **WebUI** and **volume-button customization**, built and verified on the **Amazon Fire Max 11** (`sunstone` / `KFSNWI`, MediaTek `mt8188`, 4 GB RAM + eMMC, LineageOS 24.0 / Android 17).

---

## Why This Exists (Measured Bottlenecks on `sunstone`)

1. **Tight 4 GB RAM + 50% `lz4` ZRAM**: Stock `/vendor/etc/init/hw/init.mt8188.rc` sets ZRAM to `50%` (~`1.85 GB`) using `lz4`, even though `zstd` is compiled into the kernel (`/sys/block/zram0/comp_algorithm`). Expanding ZRAM to `75–100%` with `zstd` retains more background apps in memory before `lmkd` kills them.
2. **eMMC I/O Pressure & Large Writeback Bursts**: Stock `vm.dirty_background_ratio=10` / `vm.dirty_ratio=20` allows hundreds of MB of dirty pages to pile up before flushing to eMMC (`mmcblk0`, `mq-deadline`, `iostats=1`), amplifying PSI I/O stalls (`25.96 s` vs `3.97 s` memory stalls observed).
3. **Disabled ART Method Inlining & USAP Pool**: Stock properties set `dalvik.vm.dex2oat-flags=--inline-max-code-units=0` (disabling AOT method inlining) and `dalvik.vm.usap_pool_enabled=false` (cold Zygote `fork()` on every app launch).

---

## Optimization Levers

| Area | Mechanism | Applies |
| :--- | :--- | :--- |
| **ZRAM Swap** (`post-fs-data.sh`) | Configures `/dev/block/zram0` compression (`zstd` / `lz4`) and size (`50%` / `75%` / `100%` RAM) before Android services fill swap, with swap-usage safety checks and automatic `lz4` fallback | At boot (or live via Action/WebUI if safe) |
| **VM Writeback & Reclaim** (`service.sh`) | Caps writeback bursts (`16/64 MB` or `12/48 MB` `dirty_background_bytes` / `dirty_bytes`), tunes `vfs_cache_pressure` (`55`/`45`), raises `watermark_scale_factor` (`25`/`40`), enforces `page-cluster=0` | **Live immediately** |
| **eMMC I/O Queue** (`service.sh`) | Tunes `/sys/block/mmcblk0/queue` scheduler (`kyber` / `none` / `mq-deadline`), `read_ahead_kb` (`64` / `128` / `256`), `iostats=0`, `add_random=0`, `rq_affinity=2` | **Live immediately** |
| **ART & Zygote** (`system.prop`) | Sets `dalvik.vm.dex2oat-flags=--inline-max-code-units=32` and `dalvik.vm.usap_pool_enabled=true` (`usap_pool_size_max=2`, `min=1`) | **At boot** |

> [!NOTE]
> Designed to complement **Frosty** without fighting its settings (Frosty's stock `user_prefs` keeps kernel/RAM tweaks off; even if enabled, this module owns ZRAM sizing/`zstd`, `dirty_bytes`, scheduler selection, `iostats`, ART inlining, and USAP).

---

## Presets & Customization

Configure via **Volume Up** (`Next`) / **Volume Down** (`Confirm`) during installation (`customize.sh`) or via the **WebUI** / **Action button** (`action.sh`) after boot:

| Preset | ZRAM | VM Writeback | Storage Queue | ART Inline | USAP Pool |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Multitasking** *(default)* | `zstd` @ `75%` | `responsive` (`16/64 MB`, `vfs=55`, `wm=25`) | `kyber` / `128 KB` | `enabled` (`32`) | `enabled` (`max 2`) |
| **Low Latency** | `lz4` @ `75%` | `responsive` (`16/64 MB`, `vfs=55`, `wm=25`) | `none` / `64 KB` | `enabled` (`32`) | `enabled` (`max 2`) |
| **Max Capacity** | `zstd` @ `100%` | `aggressive` (`12/48 MB`, `vfs=45`, `wm=40`) | `kyber` / `128 KB` | `enabled` (`32`) | `enabled` (`max 2`) |
| **Stock** | `lz4` @ `50%` | `stock` (`10%/20%`, `vfs=100`, `wm=10`) | `mq-deadline` / `128 KB` | `stock` (`0`) | `stock` (`false`) |

### WebUI (`webroot/`)

Open directly in **KernelSU**, **APatch**, **KsuWebUIStandalone**, **MMRL**, or **WebUI X** (or select **Open WebUI** from the Magisk **Action** volume-key menu):

- View live **RAM**, **ZRAM ratio & usage**, **Memory/I/O PSI stalls**, **eMMC queue**, and **ART/USAP** state.
- Apply presets or individual sliders/toggles, compact ZRAM on demand, or trigger `cmd package bg-dexopt-job` so installed apps re-optimize with method inlining enabled.

### ADB CLI Reference

```bash
# Query live telemetry and saved settings
adb shell "su -c 'sh /data/adb/modules/MT8188RamIoArtOptimizer/action.sh --status'"

# Apply a preset
adb shell "su -c 'sh /data/adb/modules/MT8188RamIoArtOptimizer/action.sh --preset lowlatency'"

# Apply explicit custom parameters: <algo> <pct> <vm> <sched> <ra_kb> <art> <usap>
adb shell "su -c 'sh /data/adb/modules/MT8188RamIoArtOptimizer/action.sh --set zstd 75 responsive kyber 128 enabled enabled'"

# Trigger ZRAM compaction or background ART dexopt
adb shell "su -c 'sh /data/adb/modules/MT8188RamIoArtOptimizer/action.sh --compact'"
adb shell "su -c 'sh /data/adb/modules/MT8188RamIoArtOptimizer/action.sh --dexopt'"
```

---

## Installation & Building

1. Download **`MT8188RamIoArtOptimizer-v1.0.zip`** from **[GitHub Releases](https://github.com/AndrewChqng/mt8188-ram-io-art-optimizer/releases)** (or build with `./build.sh`).
2. Flash in **Magisk** (v20.4+), **KernelSU**, or **APatch**, select your preset via **Volume Up / Down** (or wait 15s for **Multitasking**), and reboot.
3. Auto-updates are supported natively via `updateJson` ([`update.json`](update.json) + [`CHANGELOG.md`](CHANGELOG.md)).

```bash
git clone https://github.com/AndrewChqng/mt8188-ram-io-art-optimizer.git
cd mt8188-ram-io-art-optimizer
./build.sh
```

---

## Verification

```bash
adb shell "su -c 'cat /sys/block/zram0/comp_algorithm; cat /sys/block/zram0/disksize; cat /sys/block/mmcblk0/queue/scheduler'"
adb shell "getprop dalvik.vm.dex2oat-flags; getprop dalvik.vm.usap_pool_enabled"
```

---

## Credits & Disclaimer

- Engineered and documented with AI pair-programming assistance from **Antigravity (Google DeepMind)** by profiling live MT8188 (`sunstone`) `/proc/meminfo`, `/proc/pressure/*`, `/sys/block/zram0/*`, `/sys/block/mmcblk0/queue/*`, `/vendor/etc/init/hw/init.mt8188.rc`, and ART/Zygote properties over ADB, and packaging safe `post-fs-data.sh` ZRAM setup, live `service.sh`/`action.sh` VM & eMMC tuning, `system.prop` ART/USAP overrides, volume-key menus, and an offline WebUI into a systemless Magisk module.
- **Disclaimer**: This is experimental, AI-assisted low-level kernel/VM/ART tuning software provided "as-is" without warranty of any kind. Modifying swap algorithms, block I/O schedulers, dirty writeback limits, and compiler flags carries risk of instability or unexpected behavior; use at your own risk.
