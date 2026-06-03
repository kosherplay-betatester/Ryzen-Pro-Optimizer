# Ryzen Pro Optimizer

**Current version: 0.7.0** — see [CHANGELOG.md](CHANGELOG.md) for full release notes.

A friendly, local web-based UI for tuning AMD Ryzen **Curve Optimizer** offsets — sets per-core CO values from Windows (no BIOS reboot), runs stress tests via [CoreCycler](https://github.com/sp00n/corecycler), parses logs into a clean pass/fail report with smart next-step suggestions, and shows live CPU telemetry the whole time.

Now ships with a **Pro Dashboard** (live charts, V/F scatter, per-core heatmap, history export), a **Safety Guard** that hard-aborts stress tests on temp/voltage/WHEA breaches, a **panic-revert breadcrumb** that survives BSODs so the next boot can roll back to safe values automatically, a **Smart Auto-Adjust** bisection-based tuner with five goal modes + V-Cache awareness + cross-session learning, a **Tune Theater** live narrative UI that shows every step the algorithm takes, an opt-in **startup disclaimer** that walks the user through the risks of CPU undervolting, a **first-run BIOS-setup helper** that auto-detects when PBO/CO isn't enabled in BIOS and shows per-vendor menu paths, a **Live Curve Optimizer panel** that reads the SMU continuously so you can watch the chip's actual values change in real time, and (new in 0.7.0) a built-in **auto-updater** that probes GitHub for newer releases on every launch and applies them safely without touching your profiles or session state.

Think of it as a free, open, transparent, manual-by-default alternative to Hydra — built on top of CoreCycler so the proven stress-test machinery is doing the heavy lifting, while we focus on the UX, safety, and live visibility layer most users actually need.

---

## What's new in 0.7.0 (highlights)

- **Auto-updater.** `Launch.bat` checks GitHub for a newer version on every boot (rate-limited to once every 6 h). If `main`'s `$script:AppVersion` is ahead of yours, a colored `Y/N/S` prompt fires — default **Y** applies the update; **N** skips this run; **S** silences the prompt until the next release. Updates pull `main.zip`, snapshot the existing top-level tree into `installer-cache/backups/{old-version}-{timestamp}/` for one-shot rollback, then overlay — leaving `runtime/`, `profiles/`, `corecycler/`, `vendor/`, and `installer-cache/` strictly untouched. Refuses to run if another instance is on port 8765 or a tune is mid-flight on disk. A separate `Update.bat` triggers a manual force-check.
- **Per-core test progress grid** under Live Status — a pill per core that's been activated, color-coded green/blue/amber for passed/testing/failed, with inline `N err` / `N WHEA` tags. New `Parse-LiveCoreStats` attributes events to whichever core was active at the time, so you can see exactly which cores cleared their iterations and which ones tripped.
- **Smart Tune progress overlay on per-core CO pills.** Each pill in the Live CO panel now shows the live SMU value **plus** a scope-status badge — 🔒 locked, ▶ probing now, dashed/dimmed pending, ❌ failed. The Live CO panel auto-switches to per-core view when a Smart Tune starts (respects later manual switches), so you see Auto-Adjust progress per core without leaving the card.
- **Live Curve Optimizer panel is always visible** — was previously hidden outside of a tune. Useful idle to verify the BIOS-applied CO matches your saved profile.
- **Fixed: `Inspect-SafetySnapshot` 500-ing /api/status every tick** — second pass on the same endpoint hardened in 0.6.0. Two distinct PowerShell 7.5+ regressions: `@($List[object])` raising `ArgumentException`, and a `-join` operator misparsed as a `Select-Object` parameter inside the defensive catch. Both fixed, with belt-and-braces around the log call so a future formatting mistake can't re-introduce the same class of bug.

Full release notes including the v0.6.0 audit batch and earlier versions in [CHANGELOG.md](CHANGELOG.md).

---

## Why this exists

CoreCycler is the gold-standard tool for testing Ryzen CO stability, but it's a PowerShell script driven by editing a 900-line `config.ini`. That's powerful — but it's a wall of text, and it leaves the cycle of "set CO in BIOS → reboot → run test → reboot to change values → repeat" intact.

This app removes the BIOS round-trips and the config-file fiddling. You set values from Windows, run a test, get a friendly report (with live charts of what just happened), dial back if needed, save your sweet spot as a profile, and only commit to BIOS once you're done experimenting. If anything goes wrong, one button (or the **Esc** key) instantly resets everything to zero — and if the system actually crashes, the breadcrumb left on disk lets the next launch offer to revert to the last-known-safe values automatically.

---

## What's in the box

### ◆ Curve Optimizer setting (from Windows, no reboot)
- **Three modes:** All cores · Per-CCD · Per-core — matches the layout in your BIOS
- **Auto-detected starting values:** on launch, reads your currently active CO (from BIOS or last session) and shows it in a banner — your form pre-fills with those values, you edit what you want to change
- **Diff-aware Apply:** the Apply button is disabled until you actually change something; tooltip shows the delta
- **Revert to launch values:** undo all your experiments in one click — restores whatever was active when you opened the app
- **Reset CO (panic):** instantly sets all cores to 0 — works mid-test, works from the Esc key, no confirmation dialog
- **Panic-revert breadcrumb:** every CO write drops a tiny JSON file *before* the SMU register touch. If the system crashes mid-write, the next boot detects the breadcrumb and offers to revert. Your remote tuning session can BSOD without leaving you stranded.

### ▶ Stability testing — three modes
- **Test runner:** wraps CoreCycler. Selectable Prime95 mode: SSE (default, best for CO), AVX2, AVX512
- **User-defined cycle count:** default 1 (quick check), recommends 3+ for confidence, accepts up to 10000 for overnight runs
- **Manual mode (default):** you set CO, run test, get report, decide next move
- **Auto-Adjust mode:** opts into CoreCycler's AutomaticTestMode — when a core errors, CoreCycler bumps its offset upward (less negative) and retries, walking each core to its individual stable edge autonomously
- **Smart Auto-Adjust (Pro) — see next section**
- **Live status during tests:** which core is testing, current iteration, error counts, runtime
- **Stop button + Esc** during a test exits cleanly; CoreCycler config restored

### ⌬ Smart Auto-Adjust (Pro)
A bisection-based, telemetry-aware, history-learning auto-tuner that replaces CoreCycler's linear "increment on error" loop. **Five user-selectable goal modes** plus an overclock direction toggle:

| Mode | Direction | Time | Iter./value | Per-CCD vs per-core | Safety margin |
|---|---|---|---|---|---|
| **Daily Driver** *(default)* | undervolt | 30–60 min | 2 clean | per-CCD | +2 points (safer) |
| **Max Stable** | undervolt | 3–6 h | 5 clean + cross-check | per-CCD then per-core refine | +1 point |
| **Adaptive** | undervolt | hours/days, background | continuous re-verify | per-core, slow-growth | +2 points |
| **Characterize** | both | ~1 h | 1 short pass per probe | per-core | n/a (insight only) |
| **Overclock** | overshoot (+) | 1–2 h | 3 clean | per-core | –1 point (toward safer) |

Under the hood:
- **Hybrid bisection algorithm** with telemetry-modulated step sizing — steps shrink as the CPU approaches your safety limits, expand when there's lots of headroom. Direction-aware (correctly tracks "shallowest fail" for both undervolt and overclock).
- **V-Cache CCD asymmetry handling** — auto-detects X3D parts (7950X3D, 9950X3D, etc.); V-Cache CCD gets tighter bounds (e.g., floor -25 vs -30) and is probed *first* so failures happen fast on the more delicate silicon.
- **Persistent cross-session learning** — `runtime/tuner-history.jsonl` is append-only; every probe result becomes a permanent data point. Future sessions seed bisection from known-stable / known-crash bounds and *never re-probe* a value that has previously crashed your specific CPU.
- **Crash-recovery resume** — interrupted sessions can be picked back up across reboots. The mid-probe value gets recorded as `ABORT_CRASH` in history (worst class — permanent guard rail). Resume rebuilds the orchestrator state from `runtime/tuner-session.json`.
- **Safety-margin locking** — the final committed value is always shifted *away* from the discovered edge by the mode's margin (e.g., Daily Driver locks at edge+2 toward zero). Never the absolute edge.
- **Single-iteration probe loop** driven by `/api/status` ticks, so the HTTP server stays responsive between Prime95 runs.

Per the design spec at [`docs/superpowers/specs/2026-05-28-smart-auto-adjust-design.md`](docs/superpowers/specs/2026-05-28-smart-auto-adjust-design.md). 88 Pester unit tests cover the search engine, history queries, mode policies, narrative buffer, probe classifier, profile store (incl. pre-tune snapshots), and orchestrator state machine.

### ▣ Tune Theater
The transparency layer for Smart Auto-Adjust runs. Auto-opens above the Pro Dashboard when a Smart Tune starts. Shows:
- **Progress header** — overall %, per-scope status pills, rough ETA
- **"Currently" strip** — what the algorithm is doing *right now* (e.g., "Probing CCD1 at CO=-22 · Prime95 SSE · 3m 12s in"), updated every second
- **Per-scope ladder cards** — bounds (`floor..ceiling`), live `knownStable | knownUnstable` window, probe count, locked value, 🔋 marker on V-Cache scopes
- **Live narrative log** — every probe start, every classification, every bound tighten, every history hit, every safety event, with icons (⚙ lifecycle · ▦ history · ◇ safety · ◆ planning · ▣ panic-revert · ➤ probe · ✓ PASS · ✗ FAIL · ⚠ WHEA · ▣ lock · ↻ retry). Pinnable autoscroll.
- **Resume/discard banner on next launch** — if a session was interrupted, the UI offers to pick up where you left off or start fresh.

The narrative log is fed via `GET /api/smart-tune/state?since=<seqId>` — a paginated stream that lets multiple browser tabs stay in sync without re-downloading the whole history each poll.

### ◇ Safety Guards (auto-tune watchdog)
A live limit-checker that runs alongside any test and **hard-aborts** the moment any of these trip:

| Limit | Default | Configurable |
|---|---|---|
| Max core temperature | 95 °C | yes (50–105 °C) |
| Max core VID | 1.45 V | yes (0.9–1.55 V) |
| WHEA hardware-error delta | abort on first | yes (toggle) |

Hysteresis: a single transient spike just warns; **three consecutive samples** over the limit trigger an abort. WHEA aborts fire immediately — hardware corrected-error events are a much stronger signal than a thermal blip.

On abort, the guard:
1. Stops the running test
2. Reads the current CO values
3. **Steps every core back one increment toward neutral** (the same `incrementBy` you configured)
4. Writes the safer values to SMU (with a panic-revert breadcrumb first)
5. Records the abort and the step-back in a counter visible in the UI

This is the seatbelt: even a misconfigured Auto-Adjust run that wanders into unstable territory gets caught before a BSOD.

### ▦ Pro Dashboard (live charts + insights)
Toggleable card (📊 button in the top-right of the page, auto-opens when a test starts) with:

- **Per-core clock chart** — one line per physical core, rolling window
- **Temperature chart** — package Tctl/Tdie + CCD0 + CCD1 (on dual-CCD parts)
- **Per-core voltage chart** — one line per core, VID readings
- **Package power chart** — wattage over time
- **Boost map (V/F scatter)** — voltage × clock per core at the current instant. Watch the curve shift as the CPU loads.
- **Stats grid** — Pkg Temp, Pkg Power, Avg Clock, Avg VID, Hottest Core, Avg Load. Each tile shows min/avg/max for the session, and **turns warn/danger** when approaching or crossing your safety limits.
- **Per-core heatmap** — live tile per physical core showing V / clock / load%, with a 🔋 marker on V-Cache cores and a load-progress bar at the bottom.
- **Time window selector:** 60 s / 3 m / 10 m / 30 m of rolling history
- **Pause / Reset stats / Export history** — pause the live update, reset min/max counters, or download the full sample history as JSON for offline analysis

The Pro Dashboard charts stream off the same `/api/telemetry` endpoint your basic telemetry strip already uses — they're just rendered with Chart.js (vendored offline, no CDN dependency).

### ⌗ Live telemetry (always visible)
**Compact strip** always in view: package temp, package power (PPT), average voltage, max clock, with one click to expand.

**Expanded inline grid:** per-core voltage / clock / load for each core (16 physical cores on a 7950X3D, not the 32 SMT siblings). CCDs labelled, V-Cache marked on X3D parts. Color-coded background by temperature.

**Peak tracking during tests:** the moment a test starts, "peaks" snapshot begins recording max temp, max power, max voltage, max clock per core. Shown in the post-test report so you can sanity-check thermals as well as stability.

Sensors read via the open-source [LibreHardwareMonitorLib](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) DLL. **Important:** modern LibreHardwareMonitor releases ship a `.NET 10` build that Windows PowerShell 5.1 cannot load — the installer pulls the older `.NET Framework 4.7.2` build from NuGet instead, and the launcher self-heals if it ever finds an incompatible DLL. (Details in [Troubleshooting](#troubleshooting).)

### ⚠ WHEA Bodyguard
A background watcher subscribed to Windows' WHEA event log. Always on while the app is running.
- Event-driven (Windows pushes events to us — zero CPU when idle, zero polling)
- Real-time UI alert: header indicator turns red, toast notification appears, optional audio beep
- Catches corrected hardware errors even between tests, while idle, or during gaming
- Persists across restarts (`runtime/bodyguard-log.json`)
- Hooks into the Safety Guard — a WHEA event during an Auto-Adjust run triggers an automatic step-back (configurable)

### ▤ Profiles
- Save your CO settings as named JSON profiles with optional notes
- One-click reapply after reboot (CO values are temporary by Windows design — BIOS values return on every boot)
- Tagged with the CPU model — UI warns if you try to apply a profile saved on a different CPU
- Profiles live in `profiles/` as plain JSON — easy to inspect, copy, share

### ⚙ Shutdown behaviour (no more accidental kills)
By default, the service runs until **you** stop it (terminal Ctrl+C, closing the cmd window, or the in-page shutdown button). Closing the browser tab does **not** kill it — because Chrome's memory-saver and RDP disconnects look identical to a closed tab and would otherwise terminate your tuning run while you weren't looking. Opt-in checkbox in Settings if you do want tab-close to stop the server.

### ⓘ Help (in-app)
A slide-out **?** panel with two tabs:
- **Quick Start** — what CO is, the silicon lottery, step-by-step usage, the Esc panic key
- **Advanced** — Auto-Adjust mode, V-Cache strategy, step-size guidance, WHEA explained, profile semantics, troubleshooting

### ⚠ Startup disclaimer
On first launch, a full-screen modal walks the user through the real risks of CPU undervolting / overclocking: BSOD / data loss, remote-session blindness (RDP can leave you stranded after a freeze), the worst-case CMOS reset, hardware wear from sustained Prime95, why WHEA = stop, and the fact that all SMU writes are temporary (BIOS values return on reboot). User has to explicitly click **"I understand the risks · Continue"** to dismiss it.

Acceptance is versioned in `localStorage` (`rpo.disclaimerAccepted = 'v1'`), so future disclaimer wording changes will re-prompt. A **"⚠ Show risk disclaimer again"** button in Settings lets the user re-read it on demand.

### ⚙ First-run BIOS-setup helper (auto-detection)
**The hard constraint:** Curve Optimizer is a sub-feature of Precision Boost Overdrive (PBO), and **both must be enabled in BIOS** before any OS-level tool — including this one — can take effect. No OS tool can enable PBO at runtime in a way that persists across reboots; AMD's SMU does not expose a public command for it, and even Ryzen Master's "Manual PBO" mode evaporates on reboot.

What this app does about it:
- **Read-back verification on every CO write** — `Test-CoWritesStuck` in `lib/co-reader-writer.ps1` reads back the per-core CO values immediately after a write and compares element-wise. If the SMU silently ignored the write (the signature of PBO/CO disabled in BIOS), the API response includes `writesStuck: false` with the list of mismatches.
- **Auto-shown BIOS-setup card** — the UI surfaces a tabbed help card with vendor-specific menu paths (ASUS, MSI, Gigabyte, ASRock, plus a Generic fallback) the moment a write doesn't stick. The card explains exactly where in the BIOS to find PBO + Curve Optimizer for that vendor.
- **First-run proactive hint** — on initial page load, if your launch CO snapshot is all zeros AND you've never dismissed the card, it shows up automatically as a "looks like you might be a first-timer" nudge. Dismiss it once and it stays dismissed (localStorage `rpo.biosSetupDismissed`) — unless a write later fails, in which case it re-surfaces with the specific error context.
- **Post-Apply toast** — if a write succeeds AND verification passes, the toast says "Applied ✓ (verified)". If verification fails, you get a red toast: "⚠ CO write was IGNORED by the SMU - PBO/CO probably disabled in BIOS".

So a user who has never set foot in their BIOS gets diagnosed and guided automatically without having to read this README.

---

## Supported CPUs

| Family | Generation | CO Support |
|---|---|---|
| Ryzen 5000 (Vermeer / Cezanne) | Zen 3 | ✅ (first generation with Curve Optimizer) |
| Ryzen 5000X3D (5800X3D) | Zen 3 + 3D V-Cache | ✅ (V-Cache CCD detected and labelled) |
| Ryzen 7000 (Raphael) | Zen 4 | ✅ |
| Ryzen 7000X3D (7800X3D / 7900X3D / 7950X3D) | Zen 4 + V-Cache | ✅ (V-Cache CCD0 detected and labelled) |
| Ryzen 9000 (Granite Ridge) | Zen 5 | ✅ |
| Ryzen 9000X3D (9800X3D / 9900X3D / 9950X3D) | Zen 5 + V-Cache | ✅ |
| Ryzen 3000 (Matisse) | Zen 2 | ❌ — CO was introduced in Zen 3, app shows friendly "not supported" screen |
| Older / Intel / other | — | ❌ — friendly "not supported" screen |

CPU detection includes:
- Auto-discovery of model name + core count via `Win32_Processor`
- Override table for known models (CCD count, V-Cache CCD index)
- Heuristic fallback: >8 cores ⇒ dual-CCD (holds across all current consumer Ryzen)

---

## Installation

### Requirements
- Windows 10 or 11
- PowerShell 5.1+ (ships with Windows)
- Internet connection for the installer to fetch CoreCycler + PawnIO + LibreHardwareMonitor stack (one-time)
- Administrator rights (required for SMU register writes; `Launch.bat` self-elevates)

### Install
```powershell
cd C:\path\where\you\want\it
git clone https://github.com/kosherplay-betatester/Ryzen-Pro-Optimizer.git
cd Ryzen-Pro-Optimizer
```

That's it. **Don't run anything yet — just clone.**

### First launch
Double-click **`Launch.bat`**.

1. Windows prompts for administrator (UAC). Accept.
2. The launcher checks four things and runs the installer if anything is missing or incompatible:
   - `corecycler/script-corecycler.ps1` exists?
   - `vendor/LibreHardwareMonitorLib.dll` exists?
   - That DLL is the .NET-Framework-compatible build (not .NET 10)?
   - The `PawnIO` Windows service is registered?
3. If installer runs, it fetches:
   - **CoreCycler** — latest release ZIP from GitHub
   - **PawnIO driver** — installer EXE from GitHub (one short wizard, you click through). Replaces the deprecated WinRing0 driver.
   - **LibreHardwareMonitor + companions** — `LibreHardwareMonitorLib.dll`, `DiskInfoToolkit.dll`, `RAMSPDToolkit-NDD.dll`, `HidSharp.dll`, `System.Memory.dll`, `System.Runtime.CompilerServices.Unsafe.dll`. All pulled from NuGet, all the `net472` build. **Why NuGet instead of GitHub releases:** the GitHub releases now ship `.NET 10` builds that Windows PowerShell 5.1 cannot load. NuGet's `runtimes/win-x64/lib/net472/` path still has a compatible build, and the version pin (LibreHardwareMonitorLib `0.9.6` + System.Memory `4.6.3` + Unsafe `6.1.2`) is the verified-working combination.
4. Server starts on `http://127.0.0.1:8765` (or next free port up to 8775)
5. Your default browser opens the UI

Subsequent launches skip the installer and go straight to the server (~2 seconds to a usable browser tab).

### Auto-updater (new in 0.7.0)

`Launch.bat` runs `update.ps1` before booting the server. On every launch (rate-limited to once every 6 h to avoid hammering GitHub on rapid restart cycles), it:

1. Reads `$script:AppVersion` from your local `server.ps1`.
2. Fetches the same line from `main` on GitHub via `raw.githubusercontent.com` (5 s timeout; fails open if you're offline).
3. If the remote is newer, prints a coloured prompt:
   ```
   ============================================================
     UPDATE AVAILABLE: v0.6.0  ->  v0.7.0
     Strongly recommended. Your profiles, history, and runtime
     state are preserved by the updater.

     [Y] Update now (recommended)
     [N] Not this time
     [S] Skip this version (don't ask again until v0.7.0+1)
   ============================================================
   Choice (Y/N/S, default Y):
   ```
4. On `Y`: downloads `main.zip`, snapshots the existing top-level tree into `installer-cache/backups/{old-version}-{timestamp}/`, then overlays. **Never touches** `runtime/`, `profiles/`, `corecycler/`, `vendor/`, or `installer-cache/` — your CO profiles, session history, panic-revert state, and installer-managed third-party stay exactly where they are.

**Refuses to run** if another instance is listening on `127.0.0.1:8765` (would dead-lock DLL handles) or if a panic-revert / RUNNING `tune-session.json` is on disk (would orphan an in-flight test process).

To force a check between scheduled probes (e.g. you skipped a version and want to re-check), run **`Update.bat`** — it bypasses both the 6 h rate-limit and any skip-version marker.

If you'd rather have manual control of when you're on a new version, just press `N` every time. The launcher continues to boot the existing install either way; the updater never blocks startup.

### Manual install fallback
If the installer fails (rare — usually a flaky network during the GitHub or NuGet download):
1. Run `Install.bat` manually — it prints exact error + recovery instructions
2. Or: download CoreCycler from https://github.com/sp00n/corecycler/releases, extract its contents into the `corecycler/` subfolder of this repo
3. Or: install PawnIO manually from https://github.com/namazso/PawnIO.Setup/releases
4. Re-run `Launch.bat` — the launcher's compatibility check will trigger the installer to fetch the right LHM DLLs from NuGet

---

## How it works (the actual mechanics)

```
┌─────────────────────────────────────────────────────────────────┐
│  Browser (localhost) — vanilla HTML/CSS/JS + Chart.js (vendored)│
│  Polls /api/status, /api/telemetry every 1s                     │
│  Renders Pro Dashboard (charts, heatmap, V/F scatter)           │
│  Sends safety prefs + tab-close heartbeat (opt-in)              │
└──────────────────────────┬──────────────────────────────────────┘
                           │ HTTP (127.0.0.1 only, no auth needed)
┌──────────────────────────┴──────────────────────────────────────┐
│  PowerShell HTTP server (server.ps1)                            │
│   ├─ System.Net.HttpListener on port 8765+                      │
│   ├─ Custom router with parameterized paths                     │
│   ├─ Run-state machine: IDLE → APPLYING_CO → TESTING →          │
│   │                    STOPPING → REPORTING → IDLE              │
│   ├─ Always-on WHEA EventLog subscription (Bodyguard)           │
│   ├─ Safety Guard: live limit checks during tests + abort hook  │
│   ├─ Panic-revert breadcrumb writer (before every CO write)     │
│   └─ Subprocess manager for CoreCycler                          │
└────┬─────────────────┬─────────────────┬───────────────────────-┘
     │ runs            │ runs            │ loads
┌────┴────────┐  ┌─────┴───────┐  ┌──────┴───────────────────────┐
│ ryzen-smu-  │  │ CoreCycler  │  │ LibreHardwareMonitor stack    │
│ cli (PawnIO │  │ (orchestr.  │  │ (LHM + HidSharp + DiskInfo +  │
│ → SMU regs) │  │ Prime95)    │  │  RAMSPD + System.Memory net472)│
└─────────────┘  └─────────────┘  └──────────────────────────────-┘
```

### The data flow

**On launch:**
1. `Launch.bat` self-elevates, then runs the compatibility check (Is corecycler installed? Is the LHM DLL compatible? Is PawnIO registered?) and runs `installer.ps1` if anything is missing.
2. `server.ps1` does a final admin check (errors cleanly if not elevated for some reason)
3. Self-heal: if the LHM DLL is the wrong `.NET 10` build, re-run the installer to replace it
4. Detects CPU via `Get-CimInstance Win32_Processor`, classifies CCD layout
5. Initializes `ryzen-smu-cli` wrapper, reads current CO values, saves to `runtime/launch-snapshot.json`
6. Initializes LibreHardwareMonitorLib for sensors
7. Subscribes to Windows WHEA event log (Bodyguard)
8. Initializes the Safety Guard (armed when an Auto-Adjust test starts)
9. **Checks for `runtime/panic-revert.json`** — if found, the previous session crashed mid-tune; surfaces a banner with revert button
10. Opens HTTP listener, opens browser

**When you set CO values:**
1. Browser POSTs `/api/co` with `{ mode: 'per-ccd', values: { ccd0: -10, ccd1: -20 } }`
2. Server expands the mode into a flat 16-int array
3. **Writes `runtime/panic-revert.json`** with the intended values (the breadcrumb)
4. Calls `ryzen-smu-cli.exe --offset -10,-10,...,-20,-20`
5. ryzen-smu-cli writes to the SMU registers via PawnIO
6. **Deletes the breadcrumb** (the write completed — no panic needed)

**When you start a test:**
1. Server reads your safety prefs from the request body (or uses configured defaults)
2. For Auto-Adjust runs: arms the Safety Guard with abort callback wired up
3. Generates a `runtime/generated-config.ini` from your UI selections
4. Backs up CoreCycler's `config.ini`, swaps in ours
5. Spawns `script-corecycler.ps1` in a new console window (so you can see the test live)
6. Begins peak-tracking telemetry
7. Pro Dashboard auto-opens in the browser

**During a test (every 1 s status poll):**
- Server reads latest telemetry snapshot
- Updates peak tracker
- Hands the snapshot to the Safety Guard for inspection
- If a hard limit is breached *3 samples in a row* (or WHEA fires once), the Safety Guard's abort callback fires:
  - Stops CoreCycler
  - Reads current CO, computes per-core step-back values
  - Writes the panic breadcrumb + applies the safer values
  - Transitions to REPORTING state

**When a test finishes (clean):**
1. Server detects the CoreCycler process exited (or you clicked Stop)
2. Disables the Safety Guard, clears the panic breadcrumb
3. Stops peak tracking
4. Runs the log parser over `CoreCycler_*.log` + `Prime95_*.log`
5. Builds the report (verdict + cores failed/passed + peaks + smart suggestions)
6. State machine moves to REPORTING; browser polls `/api/status`, sees REPORTING, fetches `/api/report`

**Esc panic:**
- Browser sends POST `/api/reset-co`
- Server calls `ryzen-smu-cli --offset 0,0,...,0`
- All cores back to zero offset in under 1 second
- Works mid-test (state machine transitions REPORTING with INCOMPLETE verdict)

**System crash mid-tune:**
- Breadcrumb (`runtime/panic-revert.json`) is on disk from the most recent CO write
- On next boot, `server.ps1` startup notices it, prints a console banner, surfaces a UI prompt
- User clicks **Revert to launch snapshot** — server reverts CO to whatever was captured at the previous session's launch, deletes the breadcrumb

---

## File layout

```
Ryzen-Pro-Optimizer/
├── Launch.bat                        ← entry point (self-elevates, runs
│                                       installer if anything missing or
│                                       LHM DLL incompatible)
├── Install.bat                       ← explicit installer entry
├── installer.ps1                     ← fetches CoreCycler, PawnIO, and
│                                       the net472 LHM DLL stack from NuGet
├── server.ps1                        ← HTTP server + route registrations,
│                                       Safety Guard wiring, panic-revert
├── lib/
│   ├── logging.ps1                   ← structured log with rotation
│   ├── router.ps1                    ← parameterised route table
│   ├── http-server.ps1               ← HttpListener wrapper, JSON helpers,
│   │                                   server loop with tick callback
│   ├── cpu-detect.ps1                ← CPU model, CCDs, V-Cache,
│   │                                   CO support check
│   ├── co-reader-writer.ps1          ← ryzen-smu-cli wrapper
│   ├── profile-store.ps1             ← JSON profile save/load/apply
│   ├── telemetry-poller.ps1          ← LibreHardwareMonitor reader,
│   │                                   sensor-name normalisation,
│   │                                   physical-core filtering
│   ├── state-machine.ps1             ← 6-state machine with validated
│   │                                   transitions
│   ├── corecycler-runner.ps1         ← config gen, spawn, stop, log tail
│   ├── log-parser.ps1                ← CoreCycler + Prime95 log → report
│   ├── smart-suggestions.ps1         ← context-aware recommendations
│   ├── whea-watcher.ps1              ← Event Log subscription,
│   │                                   concurrent queue
│   ├── safety-guard.ps1              ← live limit checker, hysteresis,
│   │                                   abort callback, step-back logic
│   ├── smart-tuner-modes.ps1         ← Smart Auto-Adjust: mode policy
│   │                                   data table (5 modes)
│   ├── smart-tuner-search.ps1        ← Smart Auto-Adjust: pure bisection
│   │                                   engine (New-ScopeState,
│   │                                   Get-NextCandidate,
│   │                                   Update-ScopeFromResult,
│   │                                   Test-ScopeConverged, Get-LockInValue)
│   ├── smart-tuner-history.ps1       ← Smart Auto-Adjust: append-only
│   │                                   JSONL ledger + queries
│   │                                   (Get-KnownCrashFloor,
│   │                                   Get-KnownStableCeiling,
│   │                                   Get-Confidence, Compact-History)
│   ├── smart-tuner-narrative.ps1     ← Smart Auto-Adjust: ring buffer
│   │                                   narrative log with seqId pagination
│   └── smart-tuner.ps1               ← Smart Auto-Adjust: orchestrator
│                                       (Start/Stop/Discard/Resume,
│                                       Plan-TuneSession, Step-SmartTune,
│                                       Tune-Scope, session persistence)
├── web/
│   ├── index.html                    ← page structure: telemetry strip,
│   │                                   Pro Dashboard, test card, settings
│   ├── style.css                     ← dark theme; AMD-red for danger,
│   │                                   cyan accent for actions
│   ├── app.js                        ← vanilla JS, polls server, renders
│   │                                   UI, ProDash chart module,
│   │                                   safety-banner renderer, audio
│   │                                   alerts, panic-revert prompt
│   ├── help.html                     ← Quick Start + Advanced
│   └── vendor/
│       └── chart.umd.js              ← Chart.js 4.4 (vendored, no CDN)
├── vendor/                           ← fetched by installer (gitignored)
│   ├── LibreHardwareMonitorLib.dll       (0.9.6, net472)
│   ├── DiskInfoToolkit.dll               (1.1.2, net472)
│   ├── RAMSPDToolkit-NDD.dll             (1.4.2, net472)
│   ├── HidSharp.dll                      (2.6.4, net35)
│   ├── System.Memory.dll                 (4.6.3, net462)
│   └── System.Runtime.CompilerServices.Unsafe.dll  (6.1.2, net462)
├── corecycler/                       ← fetched by installer (gitignored)
├── profiles/                         ← your saved CO profiles (gitignored)
├── runtime/                          ← transient state (gitignored):
│   ├── server.log                        rotates at 5 MB
│   ├── launch-snapshot.json              CO values at server start
│   ├── generated-config.ini              the config we hand to CoreCycler
│   ├── bodyguard-log.json                WHEA event history
│   ├── panic-revert.json                 written before every CO change,
│   │                                     deleted on success — its
│   │                                     presence on next boot signals
│   │                                     "previous session crashed"
│   ├── tuner-session.json                Smart Auto-Adjust: rewritten
│   │                                     atomically after each probe so
│   │                                     a crash mid-session is resumable
│   └── tuner-history.jsonl               Smart Auto-Adjust: append-only
│                                         JSONL ledger, per-CPU-model
│                                         partitioned, capped at 10k
│                                         entries (crash entries never
│                                         pruned)
├── tests/                            ← Pester test files
└── docs/superpowers/
    ├── specs/                        ← design specs (incl. Smart
    │                                   Auto-Adjust design)
    └── plans/                        ← implementation plans
```

---

## API reference

All endpoints are JSON. Bound to `127.0.0.1` only.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/ping` | Liveness check |
| GET | `/api/version` | App version + install dir (footer link) |
| GET | `/api/cpu` | Detected CPU info (name, cores, CCDs, V-Cache, CO support) |
| GET | `/api/co/current` | Live CO values from SMU |
| GET | `/api/co/launch` | The snapshot captured when the server started |
| POST | `/api/co` | Apply CO values. Body: `{ mode: 'all-cores'\|'per-ccd'\|'per-core', values: {...} }`. Wrapped in panic-revert breadcrumb. Response includes `writesStuck` (read-back verification) and `mismatches` (per-core deltas if SMU ignored the write — BIOS PBO/CO probably disabled). |
| POST | `/api/reset-co` | Set all cores to 0 (panic). Response includes `writesStuck`. |
| POST | `/api/co/revert` | Apply the launch-time snapshot. Response includes `writesStuck`. |
| GET | `/api/profiles` | List saved profiles |
| POST | `/api/profiles` | Save a profile |
| DELETE | `/api/profiles/{name}` | Delete a profile |
| POST | `/api/profiles/{name}/apply` | Apply a saved profile to live CO |
| GET | `/api/telemetry` | Live sensor snapshot |
| GET | `/api/telemetry/history` | Last 60 seconds of sensor snapshots |
| GET | `/api/telemetry/peaks` | Max values seen during current/last test |
| POST | `/api/test/start` | Start a test. Body: `{ mode, iterations, autoAdjust?, autoMax?, autoInc?, coresToTest?, safety:{maxTempC,maxVid,abortOnWhea} }`. Safety object arms the Safety Guard. |
| POST | `/api/test/stop` | Stop running test (Ctrl+C → fallback to kill). Disables Safety Guard. |
| GET | `/api/status` | State machine status + live test progress + WHEA events + Safety Guard state + panic-revert pending flag + `smartTune` (full Smart Tune state with narrative entries since `?since=<seqId>`) + `coWritesActive` (true/false/null from last verification) + `coWriteMismatches` |
| GET | `/api/report` | Latest test report (verdict + cores failed + peaks + suggestions) |
| GET | `/api/whea` | Full WHEA event list |
| POST | `/api/whea/clear` | Clear stored WHEA events |
| POST | `/api/heartbeat` | Browser keepalive — only consequential when the user opted in to "tab close stops service" |
| POST | `/api/shutdown` | Graceful shutdown: revert CO, stop test, close listener |
| POST | `/api/settings` | Update runtime settings. Body keys (all optional): `heartbeatEnabled`, `safetyMaxTempC`, `safetyMaxVid`, `safetyAutoAbortOnWhea` |
| GET | `/api/panic-revert` | Returns the pending panic-revert breadcrumb if one exists (from a previous crashed session) |
| POST | `/api/panic-revert/apply` | Reverts CO to launch snapshot and clears the breadcrumb |
| POST | `/api/panic-revert/dismiss` | Clears the breadcrumb without applying anything |
| POST | `/api/smart-tune/start` | Start a Smart Auto-Adjust session. Body: `{ mode: 'daily-driver'\|'max-stable'\|'adaptive'\|'characterize'\|'overclock', direction: 'undervolt'\|'overclock' }`. Arms the Safety Guard with auto-revert-to-launch-on-trip. |
| POST | `/api/smart-tune/stop` | Stop the running Smart Tune; disables Safety Guard; transitions to REPORTING. |
| GET | `/api/smart-tune/state` | Full session state + narrative entries newer than `?since=<seqId>` (paginated). Driven by the browser's 1Hz `/api/status` poll. |
| POST | `/api/smart-tune/resume` | Rebuild a previous session's orchestrator state from `runtime/tuner-session.json` and resume the loop. The interrupted probe is recorded as `ABORT_CRASH` in history (permanent guard rail). |
| POST | `/api/smart-tune/discard` | Wipe the pending session JSON without resuming. |
| GET | `/api/smart-tune/history` | All probe history for the detected CPU model (per-CPU partitioned JSONL). |
| GET | `/api/smart-tune/pending-session` | Returns the pending session JSON if one exists on startup (UI shows the resume/discard banner). |

---

## Safety & semantics

- **CO writes are temporary.** They sit in SMU registers until the next reboot. After reboot, your BIOS values return. To make settings permanent, write them into BIOS. This app is for **finding** the right values — BIOS is where you **commit** them.
- **Every CO write drops a breadcrumb first.** `runtime/panic-revert.json` is created *before* the SMU write and deleted *after* success. If the system locks up between those two moments, the next boot sees the breadcrumb and offers to revert.
- **The Safety Guard runs alongside every Auto-Adjust test** and hard-aborts on sustained temp/voltage breaches or any WHEA event. On abort, it steps every core back one increment toward neutral.
- **The Esc key resets everything to 0** at any time. No confirmation. Designed for emergencies when the system is partially unstable but the browser still responds.
- **The Reset CO button** is always visible, top-right, red. Works the same as Esc.
- **No auto-apply on Windows startup.** A bad profile auto-applied at boot could lock you out of Windows. You apply profiles manually after launch, by explicit click.
- **WHEA events** during a stress test are a strong signal: even if Prime95 doesn't error out, the CPU detected and corrected hardware errors. Back off the CO offset.
- **The service does not auto-shut-down when you close the browser tab** (Chrome's memory-saver and RDP disconnects look like a closed tab). The terminal window is the master switch. Opt-in checkbox if you do want tab-close to stop the server.
- **The "silicon lottery"** is real. Every CPU is unique, every core within it is unique. Your weakest core caps your all-cores limit. Expect trial and error. The Smart Suggestions are designed to keep you moving in the right direction without false promises.
- **PBO + Curve Optimizer must be enabled in BIOS once.** No OS tool can enable PBO at runtime in a way that persists across reboots — AMD's SMU does not expose a public command for it. The app verifies every write by read-back and surfaces a BIOS-setup card automatically if the SMU silently ignores the write.
- **Smart Auto-Adjust never re-probes a previously crashed value.** The per-CPU JSONL history is append-only; every `FAIL_WHEA` / `ABORT_CRASH` / `TIMEOUT` becomes a permanent guard rail. Even across reinstalls — keep `runtime/tuner-history.jsonl` around if you want to retain the learning.
- **Locked-in CO values always have a safety margin.** Smart Auto-Adjust never commits the absolute discovered edge — it shifts toward zero by the mode's `marginPoints` (e.g., Daily Driver = +2 toward neutral). The point of the bisection is to *find* the edge; the point of the margin is to *not sit there*.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| "must run as administrator" error | Not elevated | Use `Launch.bat` (auto-elevates) or right-click → Run as Administrator |
| Browser shows "Curve Optimizer Not Supported" | CPU older than Zen 3, or non-AMD, or unrecognised | Confirm your CPU is Ryzen 5000-series or newer |
| "ryzen-smu-cli not found" | Installer hasn't run successfully | Run `Install.bat`; check for network/firewall blocks to GitHub |
| Telemetry panel says "unavailable", `server.log` shows wall of `System.Runtime, Version=10.0.0.0` errors | LHM DLL is the .NET 10 build, PS 5.1 can't load it | **Auto-healed** since the recent update — `Launch.bat` and `server.ps1` both detect this and re-run the installer to pull the net472 build from NuGet. If it still fails, delete `vendor/*.dll` and re-run `Install.bat`. |
| Pro Dashboard charts don't appear | `web/vendor/chart.umd.js` missing | Re-clone or run `Install.bat`; verify the file exists |
| Test ends immediately as INCOMPLETE | CoreCycler subprocess crashed (often config issue) | Check `corecycler/logs/` for the latest log; if Prime95 can't start, may be a Visual C++ runtime issue |
| Auto-Adjust runs but no Safety Guard banner appears | Browser hadn't reached the page when test started, OR you started a Manual test (guard only arms on Auto-Adjust) | Reload the page; or start the test in Auto-Adjust mode |
| Service exited unexpectedly while I was away | Probably the heartbeat watchdog (only fires if you opted into "tab close stops service") | Open Settings, uncheck "Closing the browser tab/window stops the service" |
| Browser shows "Previous session crash detected" banner on launch | The last session left a panic-revert breadcrumb — likely a BSOD, hard hang, or process kill during a CO write or auto-tune | Click **Revert to launch snapshot** to roll back to safe values, or **Dismiss** if you've already manually verified the state |
| Per-core grid shows 32 cores on a 16-core CPU | Should be auto-filtered now (SMT siblings collapsed); if not, your build is older than the telemetry fix — pull latest | Update from git |
| Port 8765 already in use | Another app, or a previous session | App auto-walks to 8766, 8767, etc. up to 8775 — check the server console window for the actual URL |
| Browser doesn't open automatically | Default browser misconfig | Server window shows the URL — open it manually |
| WHEA indicator never goes green | Watcher failed to subscribe | Usually needs admin (which `Launch.bat` provides). Check `runtime/server.log` for `Failed to start` |
| Audio beep on WHEA doesn't fire | Browser autoplay policy or audio muted | Click anywhere on the page once (autoplay needs a user gesture); ensure tab audio isn't muted; check the toggle in Safety Guards settings |
| Apply toast says "⚠ CO write was IGNORED by the SMU" or the BIOS-setup card appears automatically | PBO + Curve Optimizer disabled in BIOS — SMU accepts writes but registers stay at the BIOS defaults | Reboot into BIOS, enable PBO + Curve Optimizer (the card shows per-vendor menu paths). Save & Exit. The next Apply will read-back-verify; you'll see "Applied ✓ (verified)" when it sticks. |
| Smart Tune session won't start | State machine isn't IDLE, or CoreCycler/CO tool aren't ready | Stop any running test first; verify Install.bat completed; check `runtime/server.log` for the actual `Cannot start - state=...` reason |
| Tune Theater appears blank during a Smart Tune | Initial probe hasn't completed yet — Prime95 needs 30-60s warm-up | Wait. The "Currently" strip updates every second; the bisection ladder fills in as probes complete. |
| "Previous Smart Tune session detected" banner on launch | Last session was interrupted (BSOD, process kill, crash mid-tune) | Click **Resume** to continue from the next pending scope (the interrupted probe is recorded as `ABORT_CRASH` in history — permanent guard rail), or **Discard** to start fresh |

Server log lives at `runtime/server.log` (rotates at 5 MB).

---

## Roadmap

Shipped in the current build (see [`docs/superpowers/specs/`](docs/superpowers/specs/) and [`docs/superpowers/plans/`](docs/superpowers/plans/) for the design + execution records, and [CHANGELOG.md](CHANGELOG.md) for the per-version log):
- ✓ Pro Dashboard with Chart.js live charts, V/F scatter, per-core heatmap, history export
- ✓ Per-core chart legend with three-state filter (click toggle · shift+click solo) + HTML tooltip that escapes the canvas
- ✓ Safety Guard with hysteresis, hard-abort, auto-revert to launch snapshot on trip; defensive try/catch around `Inspect-SafetySnapshot` so a bad tick can't 500 `/api/status`
- ✓ Panic-revert breadcrumb surviving BSODs
- ✓ Startup risk disclaimer with versioned acceptance (opt-in to suppress)
- ✓ Smart Auto-Adjust orchestrator + five goal modes + V-Cache CCD asymmetry handling + per-mode granularity transparency in the UI (per-CCD vs per-CCD+per-core surfaced in the dropdown labels)
- ✓ Tune Theater live narrative UI with seqId-paginated state stream
- ✓ Cross-session history learning + crash-as-data-point recording + CPU model fuzzy match (trim + lowercase) so microcode-revision differences don't break history seeding
- ✓ Resume-SmartTune for interrupted sessions, with `scopeState` preserved for LOCKED scopes and phase-B per-core scopes seeded from their parent CCD's locked value
- ✓ Write-verify on every CO apply + auto-detected first-run BIOS-setup card
- ✓ Live Curve Optimizer panel during tunes (Summary / Per-CCD / Per-core)
- ✓ Pre-tune profile snapshots (Auto-Adjust + Smart Auto-Adjust) with millisecond-precision filenames to prevent same-second collision
- ✓ Apply confirmation modal with inline "Save profile & apply" option
- ✓ Profile Details inline-expand preview with per-core CO pill chips
- ✓ Stored-XSS escaping at every server-string interpolation site (audit batch)
- ✓ Process handle disposal + path traversal canonicalization + idempotent shutdown + double-arm guard + state-machine REPORTING→TESTING (audit batch)
- ✓ App version surfaced in the UI footer + `/api/version` endpoint

Next up:
- **AVX2 / AVX-512 stress matrix in Max Stable mode** — currently the orchestrator only invokes Prime95 SSE; Max Stable would benefit from a multi-workload cross-check pass after the bisection converges.
- **Per-core thermal budget** — V-Cache CCD cores that consistently run hotter than siblings could get a per-core temp guard in addition to the per-CCD policy.
- **"Compare two CPUs" history view** — if `tuner-history.jsonl` accumulates data for multiple CPU models on the same install, surface a side-by-side comparison.
- **Selected-cores Smart Tune** — a future option to scope a Smart Tune run to a user-picked subset of cores (e.g., only the V-Cache CCD) instead of always the full plan.
- **AGESA-version detection** — read the running BIOS AGESA via WMI and warn if it's known-buggy for CO on the user's chipset.

---

## Credits & attribution

This project stands on the shoulders of:
- **[CoreCycler](https://github.com/sp00n/corecycler)** by sp00n — the actual stress-test engine
- **[LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)** by Libre Hardware Monitor team (MIT) — sensor library
- **[PawnIO](https://github.com/namazso/PawnIO)** by namazso — modern replacement for the deprecated WinRing0 driver
- **[ryzen-smu-cli](https://github.com/rawhide-kobayashi/ryzen-smu-cli)** by rawhide-kobayashi — SMU register CLI (bundled by CoreCycler)
- **[Prime95](https://www.mersenne.org/download/)** by Mersenne Research — the actual CPU stress driver
- **[Chart.js](https://www.chartjs.org/)** (MIT) — Pro Dashboard live charts

This app is the UX / safety / live-visibility wrapper that makes them friendly to use together for Curve Optimizer hunting.

## License

The Ryzen Pro Optimizer code (everything in this repo outside `corecycler/` and `vendor/`) is provided as-is, freely shared, no warranty. Use at your own risk — undervolting can crash your system, cause data loss, or in worst cases require a CMOS reset to recover. The Esc panic button, the panic-revert breadcrumb, the Safety Guard, and BIOS reversibility are your safety nets — use them.

Bundled dependencies retain their own licenses (CoreCycler is open source; LibreHardwareMonitor is MIT; PawnIO is MIT-licensed too).
