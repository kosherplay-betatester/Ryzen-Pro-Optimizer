# Ryzen Pro Optimizer

A friendly, local web-based UI for tuning AMD Ryzen **Curve Optimizer** offsets — sets per-core CO values from Windows (no BIOS reboot), runs stress tests via [CoreCycler](https://github.com/sp00n/corecycler), parses logs into a clean pass/fail report with smart next-step suggestions, and shows live CPU telemetry the whole time.

Think of it as a free, open, transparent, manual-by-default alternative to Hydra — built on top of CoreCycler so the proven stress-test machinery is doing the heavy lifting, while we focus on the UX layer most users actually need.

---

## Why this exists

CoreCycler is the gold-standard tool for testing Ryzen CO stability, but it's a PowerShell script driven by editing a 900-line `config.ini`. That's powerful — but it's a wall of text, and it leaves the cycle of "set CO in BIOS → reboot → run test → reboot to change values → repeat" intact.

This app removes the BIOS round-trips and the config-file fiddling. You set values from Windows, run a test, get a friendly report, dial back if needed, save your sweet spot as a profile, and only commit to BIOS once you're done experimenting. If anything goes wrong, one button (or the **Esc** key) instantly resets everything to zero.

---

## Capabilities

### Curve Optimizer setting (from Windows, no reboot)
- **Three modes:** All cores · Per-CCD · Per-core — matches the layout in your BIOS
- **Auto-detected starting values:** on launch, reads your currently active CO (from BIOS or last session) and shows it in a banner — your form pre-fills with those values, you edit what you want to change
- **Diff-aware Apply:** the Apply button is disabled until you actually change something; tooltip shows the delta
- **Revert to launch values:** undo all your experiments in one click — restores whatever was active when you opened the app
- **Reset CO (panic):** instantly sets all cores to 0 — works mid-test, works from the Esc key, no confirmation dialog

### Stability testing
- **Test runner:** wraps CoreCycler. Selectable Prime95 mode: SSE (default, best for CO), AVX2, AVX512
- **User-defined cycle count:** default 1 (quick check), recommends 3+ for confidence, accepts up to 10000 for overnight runs
- **Manual mode (default):** you set CO, run test, get report, decide next move
- **Auto-Adjust mode (advanced):** opts into CoreCycler's AutomaticTestMode — when a core errors, CoreCycler bumps its offset upward (less negative) and retries, walking each core to its individual stable edge autonomously
- **Live status during tests:** which core is testing, current iteration, error counts, runtime
- **Stop button + Esc** during a test exits cleanly; CoreCycler config restored

### Report engine (Smart Suggestions)
After every test, a friendly verdict + recommendations:
- ✅ **PASSED** — all cores survived all iterations cleanly
- ❌ **FAILED** — at least one core errored or a WHEA event fired
- ⏱ **INCOMPLETE** — test stopped before completion (partial data)

Smart Suggestions are context-aware:
- *All-cores PASS:* "stable at −X — push deeper via Per-CCD"
- *Per-CCD PASS:* "switch to Per-core to find each core's individual ceiling"
- *Per-core PASS:* "now dial each back 2–3 points for thermal/seasonal margin"
- *Single-core FAIL:* "core N hit its limit at CO=Y — silicon lottery, that core just happens to be less tolerant. Dial back to Y+3 and retry."
- *Multiple V-Cache FAILS:* "V-Cache CCDs usually wall at −15 to −20. Drop CCD0 and step in 2-point increments."
- *WHEA detected:* "hardware-level corrected error — clear signal to back off."

### Live telemetry (always visible)
**Compact strip** always in view: package temp, package power (PPT), average voltage, max clock, with one click to expand.

**Expanded dashboard:** per-core grid showing voltage / clock / load for each core. CCDs are labeled (V-Cache marked on X3D parts). Color-coded background by temp (green / yellow / red).

**Peak tracking during tests:** the moment a test starts, "peaks" snapshot begins recording max temp, max power, max voltage, max clock per core. Shown in the post-test report so you can sanity-check thermals as well as stability.

Sensors read via the open-source [LibreHardwareMonitorLib](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) DLL — same low-level driver class CoreCycler already uses. No new permission ask, no separate install.

### WHEA Bodyguard
A background watcher subscribed to Windows' WHEA event log. Always on while the app is running.
- Event-driven (Windows pushes events to us — zero CPU when idle, zero polling)
- Real-time UI alert: header indicator turns red, toast notification appears
- Catches corrected hardware errors even between tests, while idle, or during gaming
- Persists across restarts (`runtime/bodyguard-log.json`)

### Profiles
- Save your CO settings as named JSON profiles with optional notes
- One-click reapply after reboot (CO values are temporary by Windows design — BIOS values return on every boot)
- Tagged with the CPU model — UI warns if you try to apply a profile saved on a different CPU
- Profiles live in `profiles/` as plain JSON — easy to inspect, copy, share

### Help (in-app)
A slide-out **?** panel with two tabs:
- **Quick Start** — what CO is, the silicon lottery, step-by-step usage, the Esc panic key
- **Advanced** — Auto-Adjust mode, V-Cache strategy, step-size guidance, WHEA explained, profile semantics, troubleshooting

---

## Supported CPUs

| Family | Generation | CO Support |
|---|---|---|
| Ryzen 5000 (Vermeer / Cezanne) | Zen 3 | ✅ (first generation with Curve Optimizer) |
| Ryzen 5000X3D (5800X3D) | Zen 3 + 3D V-Cache | ✅ (V-Cache CCD detected and labeled) |
| Ryzen 7000 (Raphael) | Zen 4 | ✅ |
| Ryzen 7000X3D (7800X3D / 7900X3D / 7950X3D) | Zen 4 + V-Cache | ✅ (V-Cache CCD0 detected and labeled) |
| Ryzen 9000 (Granite Ridge) | Zen 5 | ✅ |
| Ryzen 9000X3D (9800X3D / 9900X3D / 9950X3D) | Zen 5 + V-Cache | ✅ |
| Ryzen 3000 (Matisse) | Zen 2 | ❌ — CO was introduced in Zen 3, app will show friendly "not supported" screen |
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
- Internet connection for the installer to fetch CoreCycler + LibreHardwareMonitor (one-time)
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
2. Because `corecycler/` doesn't exist, the launcher runs the installer:
   - Queries GitHub for the latest CoreCycler release
   - Downloads the ZIP into `installer-cache/`
   - Extracts into `corecycler/`
   - Downloads LibreHardwareMonitorLib.dll into `vendor/`
3. Server starts on `http://127.0.0.1:8765` (or next free port up to 8775)
4. Your default browser opens the UI

Subsequent launches skip the installer and go straight to the server (~2 seconds to a usable browser tab).

### Manual install fallback
If the installer fails (rare — usually a flaky network during the GitHub download):
1. Run `Install.bat` manually — it prints exact error + recovery instructions
2. Or: download CoreCycler from https://github.com/sp00n/corecycler/releases, extract its contents into the `corecycler/` subfolder of this repo
3. Download LibreHardwareMonitorLib.dll from https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases into the `vendor/` subfolder
4. Re-run `Launch.bat`

---

## How it works (the actual mechanics)

```
┌─────────────────────────────────────────────────────────────────┐
│  Browser (localhost) — vanilla HTML/CSS/JS, no framework        │
│  Polls /api/status, /api/telemetry every 1s                     │
└──────────────────────────┬──────────────────────────────────────┘
                           │ HTTP (127.0.0.1 only, no auth needed)
┌──────────────────────────┴──────────────────────────────────────┐
│  PowerShell HTTP server (server.ps1)                            │
│   ├─ System.Net.HttpListener on port 8765+                      │
│   ├─ Custom router with parameterized paths                     │
│   ├─ Run-state machine: IDLE → APPLYING_CO → TESTING →          │
│   │                    STOPPING → REPORTING → IDLE              │
│   ├─ Always-on WHEA EventLog subscription                       │
│   └─ Subprocess manager for CoreCycler                          │
└────┬─────────────────────┬─────────────────────┬────────────────┘
     │ runs                │ runs                │ loads
┌────┴────────────┐  ┌─────┴─────────────┐  ┌────┴───────────────┐
│ ryzen-smu-cli   │  │ CoreCycler        │  │ LibreHardwareMonitor│
│ (reads/writes   │  │ (orchestrates     │  │ Lib.dll             │
│  CO via SMU)    │  │  Prime95, logs)   │  │ (temps/voltage/pwr) │
└─────────────────┘  └───────────────────┘  └─────────────────────┘
```

### The data flow

**On launch:**
1. `server.ps1` does an admin check (errors out cleanly if not elevated)
2. Detects CPU via `Get-CimInstance Win32_Processor`, classifies CCD layout
3. Initializes `ryzen-smu-cli` wrapper, reads current CO values, saves to `runtime/launch-snapshot.json`
4. Initializes LibreHardwareMonitorLib for sensors
5. Subscribes to Windows WHEA event log
6. Opens HTTP listener, opens browser

**When you set CO values:**
1. Browser POSTs `/api/co` with `{ mode: 'per-ccd', values: { ccd0: -10, ccd1: -20 } }`
2. Server expands the mode into a flat 16-int array
3. Calls `ryzen-smu-cli.exe --offset -10,-10,...,-20,-20`
4. ryzen-smu-cli writes to the SMU registers via its inpoutx64 / WinIo driver

**When you start a test:**
1. Server generates a `runtime/generated-config.ini` from your UI selections
2. Backs up CoreCycler's `config.ini`, swaps in ours
3. Spawns `script-corecycler.ps1` in a new console window (so you can see the test live)
4. Begins peak-tracking telemetry
5. Periodically tails CoreCycler's log file to report live status

**When a test finishes:**
1. Server detects the CoreCycler process exited (or you clicked Stop)
2. Stops peak tracking
3. Runs the log parser over `CoreCycler_*.log` + `Prime95_*.log`
4. Builds the report (verdict + cores failed/passed + peaks + smart suggestions)
5. State machine moves to REPORTING; browser polls `/api/status`, sees REPORTING, fetches `/api/report`

**Esc panic:**
- Browser sends POST `/api/reset-co`
- Server calls `ryzen-smu-cli --offset 0,0,...,0`
- All cores back to zero offset in under 1 second
- Works mid-test (state machine transitions REPORTING with INCOMPLETE verdict)

---

## File layout

```
Ryzen-Pro-Optimizer/
├── Launch.bat                ← entry point (self-elevates, runs installer if needed)
├── Install.bat               ← explicit installer entry
├── installer.ps1             ← fetches CoreCycler + LibreHardwareMonitor
├── server.ps1                ← HTTP server + route registrations
├── lib/
│   ├── logging.ps1           ← structured log with rotation
│   ├── router.ps1            ← parameterized route table
│   ├── http-server.ps1       ← HttpListener wrapper, JSON helpers
│   ├── cpu-detect.ps1        ← CPU model, CCDs, V-Cache, CO support check
│   ├── co-reader-writer.ps1  ← ryzen-smu-cli wrapper
│   ├── profile-store.ps1     ← JSON profile save/load/apply
│   ├── telemetry-poller.ps1  ← LibreHardwareMonitor reader
│   ├── state-machine.ps1     ← 6-state machine with validated transitions
│   ├── corecycler-runner.ps1 ← config gen, spawn, stop, log tail
│   ├── log-parser.ps1        ← CoreCycler + Prime95 log → report
│   ├── smart-suggestions.ps1 ← context-aware recommendations
│   └── whea-watcher.ps1      ← Event Log subscription, concurrent queue
├── web/
│   ├── index.html
│   ├── style.css             ← dark theme, AMD-red for danger, blue/cyan for actions
│   ├── app.js                ← vanilla JS, polls server, renders UI
│   └── help.html             ← Quick Start + Advanced
├── vendor/
│   └── LibreHardwareMonitorLib.dll   ← fetched by installer
├── corecycler/               ← fetched by installer (gitignored)
├── profiles/                 ← your saved CO profiles (gitignored)
├── runtime/                  ← transient: server log, generated config, state snapshots (gitignored)
├── tests/                    ← Pester test files (logging, router, cpu-detect, co-reader-writer, profile-store, etc.)
└── docs/superpowers/
    ├── specs/                ← design spec
    └── plans/                ← implementation plan
```

---

## API reference

All endpoints are JSON. Bound to `127.0.0.1` only.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/ping` | Liveness check |
| GET | `/api/cpu` | Detected CPU info (name, cores, CCDs, V-Cache, CO support) |
| GET | `/api/co/current` | Live CO values from SMU |
| GET | `/api/co/launch` | The snapshot captured when the server started |
| POST | `/api/co` | Apply CO values. Body: `{ mode: 'all-cores'\|'per-ccd'\|'per-core', values: {...} }` |
| POST | `/api/reset-co` | Set all cores to 0 (panic) |
| POST | `/api/co/revert` | Apply the launch-time snapshot |
| GET | `/api/profiles` | List saved profiles |
| POST | `/api/profiles` | Save a profile |
| DELETE | `/api/profiles/{name}` | Delete a profile |
| POST | `/api/profiles/{name}/apply` | Apply a saved profile to live CO |
| GET | `/api/telemetry` | Live sensor snapshot |
| GET | `/api/telemetry/history` | Last 60 seconds of sensor snapshots |
| GET | `/api/telemetry/peaks` | Max values seen during current/last test |
| POST | `/api/test/start` | Start a test. Body: `{ mode, iterations, autoAdjust?, autoMax?, autoInc?, coresToTest? }` |
| POST | `/api/test/stop` | Stop running test (Ctrl+C → fallback to kill) |
| GET | `/api/status` | State machine status + live test progress + WHEA events |
| GET | `/api/report` | Latest test report (verdict + cores failed + peaks + suggestions) |
| GET | `/api/whea` | Full WHEA event list |
| POST | `/api/whea/clear` | Clear stored WHEA events |

---

## Safety & semantics

- **CO writes are temporary.** They sit in SMU registers until the next reboot. After reboot, your BIOS values return. To make settings permanent, write them into BIOS. This app is for **finding** the right values — BIOS is where you **commit** them.
- **The Esc key resets everything to 0** at any time. No confirmation. Designed for emergencies when the system is partially unstable but the browser still responds.
- **The Reset CO button** is always visible, top-right, red. Works the same as Esc.
- **No auto-apply on Windows startup.** A bad profile auto-applied at boot could lock you out of Windows. You apply profiles manually after launch, by explicit click.
- **WHEA events** during a stress test are a strong signal: even if Prime95 doesn't error out, the CPU detected and corrected hardware errors. Back off the CO offset.
- **The "silicon lottery"** is real. Every CPU is unique, every core within it is unique. Your weakest core caps your all-cores limit. Expect trial and error. The Smart Suggestions are designed to keep you moving in the right direction without false promises.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| "must run as administrator" error | Not elevated | Use `Launch.bat` (auto-elevates) or right-click → Run as Administrator |
| Browser shows "Curve Optimizer Not Supported" | CPU older than Zen 3, or non-AMD, or unrecognized | Confirm your CPU is Ryzen 5000-series or newer |
| "ryzen-smu-cli not found" | Installer hasn't run successfully | Run `Install.bat`; check for network/firewall blocks to GitHub |
| Telemetry panel says "unavailable" | LibreHardwareMonitorLib.dll missing or failed to load | Run `Install.bat`; check `vendor/` folder has the DLL |
| Test ends immediately as INCOMPLETE | CoreCycler subprocess crashed (often config issue) | Check `corecycler/logs/` for the latest log; if Prime95 can't start, may be a Visual C++ runtime issue |
| Port 8765 already in use | Another app, or a previous session | App auto-walks to 8766, 8767, etc. up to 8775 — check the server console window for the actual URL |
| Browser doesn't open automatically | Default browser misconfig | Server window shows the URL — open it manually |
| WHEA indicator never goes green | Watcher failed to subscribe | Usually needs admin (which `Launch.bat` provides). Check `runtime/server.log` for `Failed to start` |

Server log lives at `runtime/server.log` (rotates at 5 MB).

---

## Credits & attribution

This project stands on the shoulders of:
- **[CoreCycler](https://github.com/sp00n/corecycler)** by sp00n — the actual stress-test engine
- **[LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)** by Libre Hardware Monitor team (MIT) — sensor library
- **[ryzen-smu-cli](https://github.com/rawhide-kobayashi/ryzen-smu-cli)** by rawhide-kobayashi — SMU register CLI (bundled by CoreCycler)
- **[Prime95](https://www.mersenne.org/download/)** by Mersenne Research — the actual CPU stress driver

This app is the UX wrapper that makes them friendly to use together for Curve Optimizer hunting.

## License

The Ryzen Pro Optimizer code (everything in this repo outside `corecycler/` and `vendor/`) is provided as-is, freely shared, no warranty. Use at your own risk — undervolting can crash your system, cause data loss, or in worst cases require a CMOS reset to recover. The Esc panic button and BIOS reversibility are your safety nets.

Bundled dependencies retain their own licenses (CoreCycler is open source; LibreHardwareMonitor is MIT).
