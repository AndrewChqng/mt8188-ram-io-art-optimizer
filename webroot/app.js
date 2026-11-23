"use strict";

const ACTION_SCRIPT = "/data/adb/modules/MT8188RamIoArtOptimizer/action.sh";

const VALID_ALGO = new Set(["zstd", "lz4"]);
const VALID_PCT = new Set([50, 75, 100]);
const VALID_VM = new Set(["stock", "responsive", "aggressive"]);
const VALID_SWAP = new Set([100, 130, 160]);
const VALID_SCHED = new Set(["kyber", "mq-deadline", "none"]);
const VALID_RA = new Set([64, 128, 256]);
const VALID_TOGGLE = new Set(["enabled", "stock"]);

const PRESETS = {
  multitasking: { algo: "zstd", pct: 75, vm: "responsive", swap: 130, sched: "kyber", ra: 128, art: "enabled", usap: "enabled", lmkd: "enabled", label: "Multitasking" },
  lowlatency: { algo: "lz4", pct: 75, vm: "responsive", swap: 100, sched: "none", ra: 64, art: "enabled", usap: "enabled", lmkd: "enabled", label: "Low Latency" },
  maxcap: { algo: "zstd", pct: 100, vm: "aggressive", swap: 160, sched: "kyber", ra: 128, art: "enabled", usap: "enabled", lmkd: "enabled", label: "Max Capacity" },
  stock: { algo: "lz4", pct: 50, vm: "stock", swap: 100, sched: "mq-deadline", ra: 128, art: "stock", usap: "stock", lmkd: "stock", label: "Stock" }
};

const VM_NOTES = {
  stock: "10%/20% dirty ratio | vfs=100 | wm=10",
  responsive: "16/64 MB dirty cap | vfs=55 | wm=25",
  aggressive: "12/48 MB dirty cap | vfs=45 | wm=40"
};

let execSeq = 0;
let isBusy = false;
let rebootArmed = false;
let rebootTimer = null;

const saved = { algo: "zstd", pct: 75, vm: "responsive", swap: 130, sched: "kyber", ra: 128, art: "enabled", usap: "enabled", lmkd: "enabled" };
const draft = { algo: "zstd", pct: 75, vm: "responsive", swap: 130, sched: "kyber", ra: 128, art: "enabled", usap: "enabled", lmkd: "enabled" };

const live = {
  version: "v1.1",
  bootPending: false,
  pendingReasons: "none",
  xposedDetected: false,
  xposedMod: "none",
  ramTotalMb: 0,
  ramAvailMb: 0,
  zramAlgo: "--",
  zramDiskMb: 0,
  zramOrigMb: 0,
  zramMemMb: 0,
  zramRatio: "0.00",
  psiMemS: "0.0",
  psiIoS: "0.0",
  blkDev: "--",
  ioSched: "--",
  ioRaKb: 0,
  ioStats: "--",
  vfsPressure: "--",
  swappiness: "--",
  dirtyBg: "--",
  dirtyFg: "--",
  usap: "--",
  dexoptFlags: "--",
  lmkdLow: "--",
  loaded: false
};

function hasKsu() {
  return typeof window.ksu !== "undefined" && typeof window.ksu.exec === "function";
}

function ksuToast(msg) {
  try {
    if (typeof window.ksu !== "undefined" && typeof window.ksu.toast === "function") {
      window.ksu.toast(String(msg));
    }
  } catch (_) {}
}

function ksuExec(cmd, options = {}) {
  return new Promise((resolve, reject) => {
    if (!hasKsu()) {
      reject(new Error("KernelSU/WebUI exec bridge unavailable"));
      return;
    }
    const cb = `ramopt_cb_${Date.now()}_${execSeq++}`;
    window[cb] = (errno, stdout, stderr) => {
      delete window[cb];
      resolve({ errno: Number(errno), stdout: stdout || "", stderr: stderr || "" });
    };
    try {
      window.ksu.exec(cmd, JSON.stringify(options), cb);
    } catch (err) {
      delete window[cb];
      reject(err);
    }
  });
}

function parseKeyValues(text) {
  const out = {};
  for (const raw of String(text).split(/\r?\n/)) {
    const idx = raw.indexOf("=");
    if (idx <= 0) continue;
    const k = raw.slice(0, idx).trim();
    const v = raw.slice(idx + 1).trim();
    if (k) out[k] = v;
  }
  return out;
}

function detectPreset(cfg) {
  for (const [id, p] of Object.entries(PRESETS)) {
    const artMatch = live.xposedDetected || p.art === cfg.art;
    if (p.algo === cfg.algo && p.pct === cfg.pct && p.vm === cfg.vm &&
        p.swap === cfg.swap && p.sched === cfg.sched && p.ra === cfg.ra &&
        artMatch && p.usap === cfg.usap && p.lmkd === cfg.lmkd) {
      return id;
    }
  }
  return null;
}

function isDirty() {
  const artDirty = !live.xposedDetected && draft.art !== saved.art;
  return draft.algo !== saved.algo || draft.pct !== saved.pct || draft.vm !== saved.vm ||
    draft.swap !== saved.swap || draft.sched !== saved.sched || draft.ra !== saved.ra ||
    artDirty || draft.usap !== saved.usap || draft.lmkd !== saved.lmkd;
}

function showToast(msg, kind = "ok") {
  const el = document.getElementById("toast");
  el.textContent = msg;
  el.className = `toast ${kind}`;
}

function setBusy(busy, label) {
  isBusy = busy;
  ["btn-apply", "btn-compact", "btn-fstrim", "btn-dexopt", "btn-refresh", "btn-reboot"].forEach((id) => {
    const el = document.getElementById(id);
    if (el) el.disabled = busy;
  });
  const applyBtn = document.getElementById("btn-apply");
  if (label) {
    applyBtn.textContent = label;
  } else {
    applyBtn.textContent = isDirty() ? "Apply Settings (Unsaved)" : "Apply Settings";
  }
}

function setActiveGroup(selector, attr, val) {
  document.querySelectorAll(selector).forEach((btn) => {
    btn.classList.toggle("active", btn.dataset[attr] === String(val));
  });
}

function render() {
  const presetId = detectPreset(draft);
  const dirty = isDirty();

  document.getElementById("ver-badge").textContent = live.version || "v1.1";
  const pill = document.getElementById("status-pill");
  const rebootBanner = document.getElementById("reboot-banner");

  if (!live.loaded) {
    pill.textContent = "Preview";
    pill.className = "pill pill-neutral";
    rebootBanner.classList.add("hidden");
  } else if (live.bootPending) {
    pill.textContent = "Reboot Pending";
    pill.className = "pill pill-warn";
    document.getElementById("pending-reasons").textContent = live.pendingReasons || "Reboot required";
    rebootBanner.classList.remove("hidden");
  } else {
    pill.textContent = "Active";
    pill.className = "pill pill-ok";
    rebootBanner.classList.add("hidden");
  }

  document.getElementById("saved-summary").textContent = dirty
    ? "Unsaved edits"
    : `${saved.algo} ${saved.pct}% | sw=${saved.swap} | ${saved.vm}`;

  document.getElementById("t-ram").textContent = live.loaded
    ? `${live.ramAvailMb} / ${live.ramTotalMb} MB`
    : "--";
  document.getElementById("t-zram").textContent = live.loaded
    ? `${live.zramAlgo} | ${live.zramOrigMb}->${live.zramMemMb} MB (${live.zramRatio}x) / ${live.zramDiskMb} MB`
    : "--";
  document.getElementById("t-psi").textContent = live.loaded
    ? `Mem ${live.psiMemS}s | IO ${live.psiIoS}s`
    : "--";
  document.getElementById("t-io").textContent = live.loaded
    ? `${live.blkDev} | ${live.ioSched} | ${live.ioRaKb} KB | iostats=${live.ioStats}`
    : "--";
  document.getElementById("t-vm").textContent = live.loaded
    ? `sw=${live.swappiness} bg=${live.dirtyBg} fg=${live.dirtyFg} vfs=${live.vfsPressure}`
    : "--";
  document.getElementById("t-art").textContent = live.loaded
    ? `usap=${live.usap} | lmk_low=${live.lmkdLow}% | ${live.xposedDetected ? `Xposed (${live.xposedMod})` : live.dexoptFlags}`
    : "--";

  document.getElementById("preset-label").textContent = presetId ? PRESETS[presetId].label : "Custom";
  document.querySelectorAll("#preset-grid .preset-btn").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.preset === presetId);
  });

  setActiveGroup("#algo-group .seg-btn", "algo", draft.algo);
  setActiveGroup("#pct-group .seg-btn", "pct", draft.pct);
  setActiveGroup("#vm-group .seg-btn", "vm", draft.vm);
  setActiveGroup("#swap-group .seg-btn", "swap", draft.swap);
  setActiveGroup("#sched-group .seg-btn", "sched", draft.sched);
  setActiveGroup("#ra-group .seg-btn", "ra", draft.ra);
  setActiveGroup("#art-group .seg-btn", "art", draft.art);
  setActiveGroup("#usap-group .seg-btn", "usap", draft.usap);
  setActiveGroup("#lmkd-group .seg-btn", "lmkd", draft.lmkd);

  document.getElementById("algo-note").textContent =
    draft.algo === "zstd" ? "zstd (higher compression ratio)" : "lz4 (lowest CPU swap latency)";
  document.getElementById("pct-note").textContent =
    draft.pct === 50 ? "50% (~1.85 GB stock)" : (draft.pct === 75 ? "75% (~2.8 GB)" : "100% (~3.7 GB)");
  document.getElementById("vm-note").textContent = VM_NOTES[draft.vm] || "";
  document.getElementById("swap-note").textContent =
    draft.swap === 160 ? "160 (aggressive ZRAM / cache priority)" : (draft.swap === 130 ? "130 (prefer zstd ZRAM)" : "100 (stock)");
  document.getElementById("sched-note").textContent =
    draft.sched === "kyber" ? "kyber (low latency)" : (draft.sched === "none" ? "none (passthrough)" : "mq-deadline (stock)");

  const xposedNote = document.getElementById("art-xposed-note");
  document.querySelectorAll("#art-group .seg-btn").forEach((btn) => {
    btn.disabled = live.xposedDetected;
  });
  if (live.xposedDetected) {
    document.getElementById("art-note").textContent = `Managed by ${live.xposedMod}`;
    xposedNote.textContent = `Active Xposed module (${live.xposedMod}) requires --inline-max-code-units=0 so hooks stay intact.`;
    xposedNote.classList.remove("hidden");
  } else {
    document.getElementById("art-note").textContent =
      draft.art === "enabled" ? "--inline-max-code-units=32" : "--inline-max-code-units=0 (stock)";
    xposedNote.classList.add("hidden");
  }

  document.getElementById("usap-note").textContent =
    draft.usap === "enabled" ? "max 2 warm workers" : "disabled (stock)";
  document.getElementById("lmkd-note").textContent =
    draft.lmkd === "enabled" ? "swap_free_low=5% | ratio aware" : "stock Android LMKD";

  const applyBtn = document.getElementById("btn-apply");
  applyBtn.classList.toggle("pending", dirty);
  if (!isBusy) {
    applyBtn.textContent = dirty ? "Apply Settings (Unsaved)" : "Apply Settings";
  }
}

function hydrate(kv) {
  if (VALID_ALGO.has(kv.ZRAM_ALGO)) saved.algo = draft.algo = kv.ZRAM_ALGO;
  if (VALID_PCT.has(Number(kv.ZRAM_SIZE_PCT))) saved.pct = draft.pct = Number(kv.ZRAM_SIZE_PCT);
  if (VALID_VM.has(kv.VM_PROFILE)) saved.vm = draft.vm = kv.VM_PROFILE;
  if (VALID_SWAP.has(Number(kv.VM_SWAPPINESS))) saved.swap = draft.swap = Number(kv.VM_SWAPPINESS);
  if (VALID_SCHED.has(kv.IO_SCHED)) saved.sched = draft.sched = kv.IO_SCHED;
  if (VALID_RA.has(Number(kv.IO_READAHEAD_KB))) saved.ra = draft.ra = Number(kv.IO_READAHEAD_KB);
  if (VALID_TOGGLE.has(kv.ART_INLINE)) saved.art = draft.art = kv.ART_INLINE;
  if (VALID_TOGGLE.has(kv.USAP_POOL)) saved.usap = draft.usap = kv.USAP_POOL;
  if (VALID_TOGGLE.has(kv.LMKD_TUNING)) saved.lmkd = draft.lmkd = kv.LMKD_TUNING;

  live.version = kv.VERSION || "v1.1";
  live.bootPending = kv.BOOT_PENDING === "1";
  live.pendingReasons = kv.BOOT_PENDING_REASONS || "none";
  live.xposedDetected = kv.XPOSED_DETECTED === "1";
  live.xposedMod = kv.XPOSED_MOD || "none";
  live.ramTotalMb = Number(kv.MEM_TOTAL_MB || 0);
  live.ramAvailMb = Number(kv.MEM_AVAIL_MB || 0);
  live.zramAlgo = kv.LIVE_ZRAM_ALGO || "--";
  live.zramDiskMb = Number(kv.LIVE_ZRAM_DISK_MB || 0);
  live.zramOrigMb = Number(kv.LIVE_ZRAM_ORIG_MB || 0);
  live.zramMemMb = Number(kv.LIVE_ZRAM_MEM_MB || 0);
  live.zramRatio = kv.LIVE_ZRAM_RATIO || "0.00";
  live.psiMemS = kv.PSI_MEM_FULL_S || "0.0";
  live.psiIoS = kv.PSI_IO_FULL_S || "0.0";
  live.blkDev = kv.BLK_DEV || "--";
  live.ioSched = kv.LIVE_IO_SCHED || "--";
  live.ioRaKb = Number(kv.LIVE_IO_RA_KB || 0);
  live.ioStats = kv.LIVE_IO_STATS ?? "--";
  live.vfsPressure = kv.LIVE_VFS_PRESSURE ?? "--";
  live.swappiness = kv.LIVE_SWAPPINESS ?? "--";
  live.dirtyBg = kv.LIVE_DIRTY_BG || "--";
  live.dirtyFg = kv.LIVE_DIRTY || "--";
  live.usap = kv.LIVE_USAP || "--";
  live.dexoptFlags = kv.LIVE_DEX2OAT_FLAGS || "--";
  live.lmkdLow = kv.LIVE_LMKD_SWAP_LOW || "--";
  live.loaded = true;
}

async function refreshStatus(silent = false) {
  if (!hasKsu()) {
    document.getElementById("demo-banner").classList.remove("hidden");
    render();
    return;
  }
  setBusy(true, "Refreshing...");
  try {
    const res = await ksuExec(`sh "${ACTION_SCRIPT}" --status`);
    if (res.errno !== 0) {
      showToast(res.stderr.trim() || `Status error (exit ${res.errno})`, "err");
      return;
    }
    hydrate(parseKeyValues(res.stdout));
    if (!silent) showToast("Telemetry refreshed.", "ok");
  } catch (err) {
    showToast(`Query error: ${err.message}`, "err");
  } finally {
    setBusy(false);
    render();
  }
}

async function applySettings() {
  if (!hasKsu()) {
    showToast("Preview mode: open inside KernelSU / APatch / WebUI X / MMRL.", "err");
    return;
  }
  if (!VALID_ALGO.has(draft.algo) || !VALID_PCT.has(draft.pct) || !VALID_VM.has(draft.vm) ||
      !VALID_SWAP.has(draft.swap) || !VALID_SCHED.has(draft.sched) || !VALID_RA.has(draft.ra) ||
      !VALID_TOGGLE.has(draft.art) || !VALID_TOGGLE.has(draft.usap) || !VALID_TOGGLE.has(draft.lmkd)) {
    showToast("Invalid configuration values.", "err");
    return;
  }
  setBusy(true, "Applying...");
  try {
    const cmd = `sh "${ACTION_SCRIPT}" --set ${draft.algo} ${draft.pct} ${draft.vm} ${draft.swap} ${draft.sched} ${draft.ra} ${draft.art} ${draft.usap} ${draft.lmkd}`;
    const res = await ksuExec(cmd);
    if (res.errno !== 0) {
      showToast(res.stderr.trim() || `Apply failed (exit ${res.errno})`, "err");
      return;
    }
    const kv = parseKeyValues(res.stdout);
    hydrate(kv);
    if (kv.BOOT_PENDING === "1") {
      showToast(`VM & I/O applied live. Reboot pending: ${kv.BOOT_PENDING_REASONS}`, "warn");
      ksuToast("VM/IO applied — reboot pending");
    } else {
      showToast("All settings active live.", "ok");
      ksuToast("RAM/IO Optimizer applied");
    }
  } catch (err) {
    showToast(`Apply error: ${err.message}`, "err");
  } finally {
    setBusy(false);
    render();
  }
}

async function compactZram() {
  if (!hasKsu()) return;
  setBusy(true, "Compacting...");
  try {
    const res = await ksuExec(`sh "${ACTION_SCRIPT}" --compact`);
    if (res.errno !== 0) {
      showToast(res.stderr.trim() || "ZRAM compact failed", "err");
      return;
    }
    hydrate(parseKeyValues(res.stdout));
    showToast("ZRAM compacted.", "ok");
    ksuToast("ZRAM compacted");
  } catch (err) {
    showToast(`Compact error: ${err.message}`, "err");
  } finally {
    setBusy(false);
    render();
  }
}

async function trimEmmc() {
  if (!hasKsu()) return;
  setBusy(true, "Trimming eMMC...");
  try {
    const res = await ksuExec(`sh "${ACTION_SCRIPT}" --fstrim`);
    if (res.errno !== 0) {
      showToast(res.stderr.trim() || "fstrim failed", "err");
      return;
    }
    const kv = parseKeyValues(res.stdout);
    showToast(`eMMC trim complete: ${kv.FSTRIM_SUMMARY || "done"}`, "ok");
    ksuToast("eMMC trim complete");
  } catch (err) {
    showToast(`Trim error: ${err.message}`, "err");
  } finally {
    setBusy(false);
    render();
  }
}

async function triggerDexopt() {
  if (!hasKsu()) return;
  setBusy(true, "Starting dexopt...");
  try {
    const res = await ksuExec(`sh "${ACTION_SCRIPT}" --dexopt`);
    if (res.errno !== 0) {
      showToast(res.stderr.trim() || "Failed to start bg-dexopt-job", "err");
      return;
    }
    showToast("Background ART optimization (bg-dexopt-job) started.", "ok");
    ksuToast("Started bg-dexopt-job");
  } catch (err) {
    showToast(`Dexopt error: ${err.message}`, "err");
  } finally {
    setBusy(false);
    render();
  }
}

function resetRebootArm() {
  rebootArmed = false;
  if (rebootTimer) {
    clearTimeout(rebootTimer);
    rebootTimer = null;
  }
  const btn = document.getElementById("btn-reboot");
  if (btn) {
    btn.textContent = "Reboot Now";
    btn.classList.remove("confirm");
  }
}

async function handleRebootClick() {
  if (!hasKsu() || isBusy) return;
  const btn = document.getElementById("btn-reboot");
  if (!rebootArmed) {
    rebootArmed = true;
    btn.textContent = "Confirm Reboot?";
    btn.classList.add("confirm");
    rebootTimer = setTimeout(resetRebootArm, 5000);
    return;
  }
  resetRebootArm();
  setBusy(true, "Rebooting...");
  try {
    await ksuExec(`sh "${ACTION_SCRIPT}" --reboot`);
    showToast("Rebooting device...", "warn");
  } catch (err) {
    showToast(`Reboot failed: ${err.message}`, "err");
    setBusy(false);
    render();
  }
}

document.addEventListener("DOMContentLoaded", () => {
  document.getElementById("preset-grid").addEventListener("click", (ev) => {
    const btn = ev.target.closest(".preset-btn");
    if (!btn || isBusy) return;
    const p = PRESETS[btn.dataset.preset];
    if (!p) return;
    Object.assign(draft, {
      algo: p.algo, pct: p.pct, vm: p.vm, swap: p.swap,
      sched: p.sched, ra: p.ra, art: p.art, usap: p.usap, lmkd: p.lmkd
    });
    render();
  });

  document.getElementById("algo-group").addEventListener("click", (ev) => {
    const btn = ev.target.closest(".seg-btn");
    if (!btn || isBusy || !VALID_ALGO.has(btn.dataset.algo)) return;
    draft.algo = btn.dataset.algo;
    render();
  });

  document.getElementById("pct-group").addEventListener("click", (ev) => {
    const btn = ev.target.closest(".seg-btn");
    if (!btn || isBusy) return;
    const val = Number(btn.dataset.pct);
    if (VALID_PCT.has(val)) { draft.pct = val; render(); }
  });

  document.getElementById("vm-group").addEventListener("click", (ev) => {
    const btn = ev.target.closest(".seg-btn");
    if (!btn || isBusy || !VALID_VM.has(btn.dataset.vm)) return;
    draft.vm = btn.dataset.vm;
    render();
  });

  document.getElementById("swap-group").addEventListener("click", (ev) => {
    const btn = ev.target.closest(".seg-btn");
    if (!btn || isBusy) return;
    const val = Number(btn.dataset.swap);
    if (VALID_SWAP.has(val)) { draft.swap = val; render(); }
  });

  document.getElementById("sched-group").addEventListener("click", (ev) => {
    const btn = ev.target.closest(".seg-btn");
    if (!btn || isBusy || !VALID_SCHED.has(btn.dataset.sched)) return;
    draft.sched = btn.dataset.sched;
    render();
  });

  document.getElementById("ra-group").addEventListener("click", (ev) => {
    const btn = ev.target.closest(".seg-btn");
    if (!btn || isBusy) return;
    const val = Number(btn.dataset.ra);
    if (VALID_RA.has(val)) { draft.ra = val; render(); }
  });

  document.getElementById("art-group").addEventListener("click", (ev) => {
    const btn = ev.target.closest(".seg-btn");
    if (!btn || btn.disabled || isBusy || !VALID_TOGGLE.has(btn.dataset.art)) return;
    draft.art = btn.dataset.art;
    render();
  });

  document.getElementById("usap-group").addEventListener("click", (ev) => {
    const btn = ev.target.closest(".seg-btn");
    if (!btn || isBusy || !VALID_TOGGLE.has(btn.dataset.usap)) return;
    draft.usap = btn.dataset.usap;
    render();
  });

  document.getElementById("lmkd-group").addEventListener("click", (ev) => {
    const btn = ev.target.closest(".seg-btn");
    if (!btn || isBusy || !VALID_TOGGLE.has(btn.dataset.lmkd)) return;
    draft.lmkd = btn.dataset.lmkd;
    render();
  });

  document.getElementById("btn-apply").addEventListener("click", () => { if (!isBusy) applySettings(); });
  document.getElementById("btn-compact").addEventListener("click", () => { if (!isBusy) compactZram(); });
  document.getElementById("btn-fstrim").addEventListener("click", () => { if (!isBusy) trimEmmc(); });
  document.getElementById("btn-dexopt").addEventListener("click", () => { if (!isBusy) triggerDexopt(); });
  document.getElementById("btn-refresh").addEventListener("click", () => { if (!isBusy) refreshStatus(false); });
  document.getElementById("btn-reboot").addEventListener("click", handleRebootClick);

  render();
  refreshStatus(true);
});
