# Ryzen Pro Optimizer — Design Spec

**Date:** 2026-05-28
**Status:** Draft, awaiting user review
**Target platform:** Windows 10/11, AMD Ryzen Zen 3+ (5000/7000/9000 series)

---

## 1. Goal

A local web-based UI that wraps CoreCycler to make per-core Curve Optimizer tuning safe, fast, and friendly for both novices and power users. The product equivalent of a free, open homemade "Hydra-lite" — but explicit and reversible rather than autonomous.

**Primary user story:**
> "I want to set Curve Optimizer values from Windows (all-cores / per-CCD / per-core), run a stress test, and get a friendly report telling me whether my CPU is stable and what to try next. If anything goes wrong, one button (or the Esc key) resets everything to default."

---

## 2. Scope

### In scope (MVP)

- **Detect existing Curve Optimizer values on launch** (read via `ryzen-smu-cli`) and use them as the starting state
- **Show a "current values" banner on launch** so user knows what's already active before they touch anything
- **"Revert to launch values" button** to restore whatever CO was active when the app started (separate from the panic Reset, which goes to 0)
- Apply CO values via `ryzen-smu-cli` (already bundled with CoreCycler)
- Three setting modes: All cores, Per-CCD, Per-core (CCD mode hidden on single-CCD chips)
- Stress testing via CoreCycler (Prime95 SSE / AVX2 / AVX512 dropdown; SSE default)
- User-configurable cycle count (default 1, with recommendation to use 3+)
- Manual workflow (default) and Auto-Adjust workflow (CoreCycler's AutomaticTestMode, as a "pro" toggle)
- Stop button + Esc panic key (instant CO reset)
- Reset CO button (always visible, always enabled, sets all cores to 0)
- Friendly post-test report with table of errors and Smart Suggestions
- WHEA Bodyguard background monitor (lightweight, event-driven, no polling)
- Save/load named profiles (JSON, on disk)
- Help section with Novice and Pro tabs (in-app, no external docs needed)
- CPU auto-detection (model, core count, CCD count, V-Cache identification)
- Graceful "Curve Optimizer not supported" screen for Zen 2 and older
- **Live telemetry panel** ("tweaker's heaven"): package & per-CCD temps, package power (PPT), per-core voltage, per-core clocks, per-core utilization, memory/FCLK, fan speeds — refreshing every 1s, with peak-during-test tracking and 60s sparklines (see §11.5)

### Out of scope (explicitly not building)

- Re-implementing the stress-test engine — CoreCycler does this
- Memory / FCLK / Infinity Fabric tuning — CO only (memory speed shown read-only as reference)
- Auto-apply on Windows startup — security/foot-gun risk, user explicitly rejected
- Multi-CPU / non-AMD support
- Cross-platform — Windows only
- Cloud profile sync, login, telemetry — local-only tool

---

## 3. Architecture

```
┌────────────────────────────────────────────────────────────────┐
│  Browser (UI layer)                                            │
│  index.html + style.css + app.js (vanilla, no framework)       │
│  Polls /api/status every 1s during active states               │
└─────────────────────┬──────────────────────────────────────────┘
                      │ HTTP, bound to 127.0.0.1 only
┌─────────────────────┴──────────────────────────────────────────┐
│  PowerShell HTTP server (server.ps1)                           │
│   • Static file server for UI                                  │
│   • JSON API endpoints (see §6)                                │
│   • State machine (see §5)                                     │
│   • WHEA event subscription (see §11)                          │
│   • Telemetry poller (LibreHardwareMonitorLib, see §11.5)      │
│   • Subprocess manager for CoreCycler                          │
└────┬──────────────────────┬─────────────────────┬──────────────┘
     │ spawns               │ spawns              │ loads .NET DLL
  ┌──┴──────────────┐  ┌────┴──────────────┐  ┌──┴──────────────────┐
  │ ryzen-smu-cli   │  │ CoreCycler        │  │ LibreHardwareMonitor│
  │ (CO read/write) │  │ (script-          │  │ Lib.dll             │
  │ tools/...       │  │  corecycler.ps1)  │  │ (temps/voltage/pwr) │
  └─────────────────┘  └───────────────────┘  └─────────────────────┘
```

**Why PowerShell HTTP server:**
- Zero install dependency — PowerShell ships with Windows
- Same admin/elevation model as CoreCycler
- Can spawn and signal subprocesses cleanly
- Same language as the rest of the project — easier for any maintainer
- `System.Net.HttpListener` is built-in and adequate for localhost JSON+static traffic

**Why vanilla JS, no framework:**
- No build step, no node_modules
- The UI is small enough that React/Vue would be overhead
- Anyone can edit a `.js` file and refresh — friendly for hacking

**Communication model:**
- Browser polls `GET /api/status` once per second when in active states (TESTING, APPLYING_CO, REPORTING)
- Browser polls every 5 seconds when IDLE (just to pick up Bodyguard alerts)
- All state-changing operations are `POST` with JSON body
- No WebSockets — adds PowerShell complexity for marginal benefit at our refresh rate

---

## 4. File Layout

```
CoreCycler-master/
├── Run CoreCycler.bat                  (untouched)
├── Launch Ryzen Pro Optimizer.bat      ← new, opens UI in browser
├── ryzen-pro-optimizer/                ← new folder, all UI files here
│   ├── server.ps1                      ← HTTP server + state machine
│   ├── lib/
│   │   ├── cpu-detect.ps1              ← detects model, cores, CCDs, V-Cache
│   │   ├── co-reader-writer.ps1        ← ryzen-smu-cli wrapper (read + write)
│   │   ├── corecycler-runner.ps1       ← spawns CoreCycler with generated config
│   │   ├── log-parser.ps1              ← parses CoreCycler + Prime95 logs into report data
│   │   ├── whea-watcher.ps1            ← Event Log subscription
│   │   ├── telemetry-poller.ps1        ← LibreHardwareMonitorLib wrapper
│   │   └── profile-store.ps1           ← JSON profile save/load
│   ├── vendor/
│   │   └── LibreHardwareMonitorLib.dll ← bundled, MIT-licensed sensor library
│   ├── web/
│   │   ├── index.html
│   │   ├── style.css
│   │   ├── app.js
│   │   └── help.html                   ← help content (loaded into slide-out)
│   ├── profiles/                       ← saved CO profiles (.json)
│   ├── runtime/                        ← transient: generated config.ini, run state
│   └── README.md
└── (existing CoreCycler files...)
```

---

## 5. Run-State Machine

```
                        ┌──────────────┐
                        │     IDLE     │ ← starting state
                        └──────┬───────┘
                               │
              ┌────────────────┼─────────────────┐
              │                │                 │
        [Apply CO]        [Start Test]      [Save Profile]
              │                │                 │
              ▼                ▼                 │
       ┌──────────────┐  ┌────────────┐         │
       │ APPLYING_CO  │  │APPLYING_CO │         │
       └──────┬───────┘  └─────┬──────┘         │
              │                │                │
              ▼                ▼                ▼
           IDLE         ┌────────────┐       IDLE
                        │  TESTING   │
                        └─────┬──────┘
                              │
              ┌───────────────┼─────────────────┐
              │               │                 │
        [Stop / Esc]    [Test completes]   [CoreCycler crash]
              │               │                 │
              ▼               ▼                 ▼
       ┌──────────────┐  ┌────────────┐  ┌──────────────┐
       │   STOPPING   │  │ REPORTING  │  │  ERROR       │
       └──────┬───────┘  └─────┬──────┘  └──────┬───────┘
              │                │                │
              ▼                ▼                ▼
         REPORTING          IDLE              IDLE
                          (after user
                          dismisses)
```

**Esc / Reset CO button is a hard interrupt:** any state → CO set to 0 → state set to IDLE. No confirmation dialog. The CoreCycler process (if running) is sent Ctrl+C; if it doesn't exit within 5s, killed.

**State is persisted to `ryzen-pro-optimizer/runtime/state.json`** so that if the server.ps1 process restarts (or browser is closed and reopened), the UI can pick up where it left off.

---

## 6. JSON API

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/` | Serve `index.html` |
| GET | `/static/*` | Serve `style.css`, `app.js`, `help.html` |
| GET | `/api/cpu` | One-shot CPU info: model, cores, CCDs, V-Cache detection, CO supported y/n |
| GET | `/api/co/current` | Read live CO values from SMU (per-core) |
| GET | `/api/co/launch` | The launch-time snapshot of CO values (for the Revert button) |
| GET | `/api/status` | Current state, current CO values, live test progress, recent WHEA events |
| POST | `/api/co` | Body: `{ mode, values }` — apply CO via ryzen-smu-cli |
| POST | `/api/reset-co` | Set all cores to 0 (panic) |
| POST | `/api/co/revert` | Apply the launch-time snapshot (restore initial values) |
| POST | `/api/test/start` | Body: test config — generate config.ini, spawn CoreCycler |
| POST | `/api/test/stop` | Send Ctrl+C to CoreCycler |
| GET | `/api/report` | Latest test report (parsed log analysis + Smart Suggestions) |
| GET | `/api/profiles` | List saved profiles |
| POST | `/api/profiles` | Save a profile |
| DELETE | `/api/profiles/{name}` | Delete a profile |
| POST | `/api/profiles/{name}/apply` | Load profile and apply CO |
| GET | `/api/telemetry` | Live sensor snapshot: temps, power, voltage, clocks, util, fans (§11.5) |
| GET | `/api/telemetry/history` | Last 60s of sensor data for sparklines |
| GET | `/api/telemetry/peaks` | Peak values seen during the current/last test run |

All endpoints bind to `127.0.0.1` only. No CORS, no authentication — purely local.

---

## 7. Curve Optimizer Reading & Writing

**Tool:** `tools/ryzen-smu-cli/ryzen-smu-cli.exe` (bundled with CoreCycler)

### 7a. Reading current CO values (BIOS detection)

On server launch (and on demand from the UI), read the current CO value of every core via `ryzen-smu-cli`. These values represent:
- **Fresh boot** → the values set in BIOS
- **After our tool wrote new values** → whatever we last applied (BIOS values still live in BIOS and will return on reboot)

```powershell
# Per-core read:
foreach ($i in 0..($coreCount - 1)) {
    $currentCO[$i] = & $ryzenSmuCli get-co-core $i
}
```

(Exact `ryzen-smu-cli` subcommand names verified during implementation — CoreCycler already uses this read path for its `startValues = CurrentValues` feature, so the mechanism is proven.)

We persist the result of the **first read after launch** to `runtime/launch-snapshot.json`. This becomes the "launch values" used by the Revert button and to detect whether the user has changed anything this session.

### 7b. Display & user awareness

- On launch, UI shows a banner: *"🎯 Detected current Curve Optimizer settings: CCD0 −10, CCD1 −20. These are loaded as your starting point."*
- The Curve form is **pre-filled** with the detected values — the user sees what's currently active, not blanks
- Each input shows a small "(current: −10)" label so deltas are obvious as the user edits
- The Apply button shows a brief diff in its tooltip: *"Will change CCD0 from −10 to −15"*
- If user has not changed any values, Apply is disabled (no-op)

### 7c. Writing CO values

```powershell
# All cores at -15:
& $ryzenSmuCli set-co-all -15

# Per-core (one call per core, indexed 0..N-1):
foreach ($i in 0..($coreCount - 1)) {
    & $ryzenSmuCli set-co-core $i $values[$i]
}
```

**Per-CCD is implemented as a convenience layer** in our UI:
- 7950X3D: CCD0 = cores 0–7, CCD1 = cores 8–15
- Per-CCD apply = expand into per-core calls under the hood

**Apply happens instantly** (sub-second). UI shows a brief "Applying…" spinner then "Applied ✓".

### 7d. Persistence and reset semantics

- **Reset CO (panic / Esc)** → all cores set to 0 (true neutral, removes any offset). For emergencies only.
- **Revert to launch values** → restore the snapshot from §7a. Useful when user experiments and wants to undo their session.
- **No mechanism persists across reboot** — by design. After a reboot, BIOS values return; user can re-apply a profile with one click. If user wants permanent settings, they should write them into BIOS.

---

## 8. Stress Testing via CoreCycler

**We do not modify CoreCycler.** Instead, for each test run:

1. Generate `ryzen-pro-optimizer/runtime/generated-config.ini` from user's UI selections
2. Spawn CoreCycler with `--config` pointing at our generated file (if supported) or by copying it to `config.ini` and backing up the original (fallback if `--config` isn't a flag — TBD on inspection)
3. Tail the latest `logs/CoreCycler_*.log` file as it's written, parse for live progress
4. On completion or stop, run the full log parser → report

**Mapping from UI choices to CoreCycler config:**

| UI choice | config.ini key |
|---|---|
| Test type (Prime95 SSE/AVX2/AVX512) | `[Prime95] mode` |
| Cycle count | `[General] maxIterations` |
| Cores to test (single/CCD/all) | `[General] coresToIgnore` (inverse) |
| Auto-Adjust toggle | `[AutomaticTestMode] enableAutomaticAdjustment` |
| Auto-Adjust starting values | `[AutomaticTestMode] startValues` |
| Auto-Adjust max (less-negative limit) | `[AutomaticTestMode] maxValue` |
| Auto-Adjust increment | `[AutomaticTestMode] incrementBy` |
| Per-core runtime | `[General] runtimePerCore` (default 6m, exposed as a "test thoroughness" slider) |

**Live status during TESTING is built from the tail of `CoreCycler_*.log`:**
- Current core (look for `Set to Core N`)
- Current iteration (look for `Iteration N/M`)
- Errors so far (look for `cores with an error: N`)
- WHEA events from our own subscription

---

## 9. Log Parser & Report Engine

**Inputs:** the two log files from the latest run:
- `logs/CoreCycler_<timestamp>_PRIME95_<mode>.log` — main script log
- `logs/Prime95_<timestamp>_<mode>.log` — Prime95 process output

**Parse rules:**

| Pattern | Means |
|---|---|
| `Set to Core N` | Core N test began |
| `Test completed in HH MM SS` | Core finished cleanly |
| `core_error` in EVENTLOG entries | CoreCycler flagged an error on the last-tested core |
| `cores with an error: N` (N > 0) | Total error count |
| `cores with a WHEA error: N` | WHEA error count |
| `FATAL ERROR` in Prime95 log | Prime95 calculation error |
| `Rounding was` in Prime95 log | Prime95 numerical error |
| `Self-test NK passed!` | Iteration passed |

**Output (report.json):**

```json
{
  "timestamp": "2026-05-28T03:42:11Z",
  "duration": "01h 23m 45s",
  "iterationsCompleted": 3,
  "iterationsRequested": 3,
  "testType": "PRIME95_SSE",
  "totalCores": 16,
  "coresTested": [...],
  "coresPassed": [0, 1, 2, ..., 15],
  "coresFailed": [
    {
      "core": 7,
      "ccd": 0,
      "ccdLabel": "CCD0 (V-Cache)",
      "coAtFailure": -15,
      "failedAtIteration": 2,
      "errorType": "Prime95 FATAL",
      "errorTime": "2026-05-28T02:48:33Z",
      "rawSnippet": "FATAL ERROR: Rounding was 0.5 ..."
    }
  ],
  "wheaEvents": [],
  "verdict": "FAILED",
  "smartSuggestions": [...]
}
```

**Verdict logic:**
- All cores passed all iterations, 0 WHEA → **PASSED**
- Any core errored OR any WHEA → **FAILED**
- Stopped by user before completion → **INCOMPLETE** (shows partial results, no verdict)

---

## 10. Smart Suggestions Engine

After every report, generate 1–4 contextual hints based on the result:

**Rule set:**

| Condition | Suggestion |
|---|---|
| Verdict = PASSED, mode = All cores | "All cores stable at −X. To push further, switch to Per-CCD: keep CCD0 at −X, try −[X+5] on CCD1." |
| Verdict = PASSED, mode = Per-CCD | "Per-CCD stable. To push further, switch to Per-core to find each core's individual ceiling." |
| Verdict = PASSED, mode = Per-core | "All cores at their individual ceilings — congrats. Dial each back by 2–3 points for a safe daily-use margin." |
| Verdict = FAILED, single core errored | "Core N hit its limit at −X. Dial that core back to −[X−3] and retry. Silicon lottery — that core happens to be slightly less tolerant." |
| Verdict = FAILED, multiple cores on CCD0 errored, V-Cache detected | "Multiple V-Cache cores errored. V-Cache CCDs typically wall between −15 and −20. Dial back CCD0 and step in 2-point increments from now." |
| Verdict = FAILED, WHEA events present | "WHEA events fired during the test — your system is masking errors at the hardware level. This is a clear signal to back off." |
| Verdict = INCOMPLETE | "Test was stopped early. Run at least 3 cycles for a confident result." |
| Iterations requested = 1 | (always append) "Tip: this was a 1-cycle test. For higher confidence, run 3+ cycles." |
| Mode = Per-core, weakest core 5+ points worse than median | "Your weakest core (#N) is significantly worse than the others. In All-cores mode, that one core caps your maximum." |

Suggestions are rendered as a list of friendly sentences under the report table, each with an icon (lightbulb 💡 for hints, warning ⚠ for danger).

---

## 11. WHEA Bodyguard

**Architecture:** event-driven, no polling, runs inside the existing server.ps1 process.

```powershell
$query = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery(
    "Microsoft-Windows-Kernel-WHEA/Errors",
    [System.Diagnostics.Eventing.Reader.PathType]::LogName,
    "*"
)
$watcher = New-Object System.Diagnostics.Eventing.Reader.EventLogWatcher($query)
$watcher.add_EventRecordWritten({
    $event = $EventArgs.EventRecord
    $script:wheaQueue.Enqueue(@{
        time = $event.TimeCreated
        eventId = $event.Id
        level = $event.LevelDisplayName
        message = $event.FormatDescription()
    })
})
$watcher.Enabled = $true
```

**Cost:** zero CPU when idle, ~few KB memory for the handler. The OS pushes events to us.

**Browser UI:**
- Small "🛡 Bodyguard: Active" indicator in the header, green when running, gray when disabled
- When event fires: indicator flashes red, browser plays a soft "ding", a toast appears with the event details
- All events accumulate in a collapsible "Bodyguard Log" at the bottom of the page, persisted to `runtime/bodyguard-log.json`

**Always-on:** the Bodyguard runs whenever the server is up, not just during tests. So if user applies a CO profile and walks away, then comes back to apps having crashed — they'll see exactly when WHEA fired.

---

## 11.5 Live Telemetry Panel (tweaker's heaven)

A real-time sensor dashboard, always visible while the app is running. The single most-watched view during a tuning session.

### Sensor source

**`LibreHardwareMonitorLib.dll`** — open-source (MIT-licensed) .NET library, loaded directly into our PowerShell process via `Add-Type -Path`. Same low-level driver class CoreCycler already uses, so no new permission/install ask.

```powershell
Add-Type -Path "$PSScriptRoot\..\vendor\LibreHardwareMonitorLib.dll"
$computer = New-Object LibreHardwareMonitor.Hardware.Computer
$computer.IsCpuEnabled = $true
$computer.IsMotherboardEnabled = $true
$computer.IsMemoryEnabled = $true
$computer.Open()
# Then poll $computer.Hardware[i].Sensors every 1s
```

### Sensors collected (1Hz poll)

| Sensor | Description | Display |
|---|---|---|
| CPU Package | Tctl/Tdie temperature | °C, color-coded (≤70 green, 70–85 yellow, ≥85 red) |
| CCD0 / CCD1 | Per-die temperature (dual-CCD only) | °C |
| CPU Package Power | PPT in watts | W, sparkline |
| Core VID (per-core) | Voltage requested by each core | V |
| Core Clock (per-core) | Effective frequency under load | MHz |
| Core Utilization (per-core) | % busy | % |
| Memory Clock | RAM transfer rate | MHz (read-only) |
| Fabric Clock | FCLK | MHz (read-only) |
| Fan Speeds | If motherboard exposes them | RPM |

All sensors stored in a circular buffer of 60 samples (60s @ 1Hz).

### Peak-during-test tracking

When state machine enters TESTING, telemetry poller records a separate "peaks" snapshot. For each sensor it tracks max value seen during the run. On test end, peaks are frozen into `runtime/last-test-peaks.json` and exposed via `/api/telemetry/peaks`. The report panel shows: *"Peak temp during test: 87°C @ core 7 (iteration 2). Peak package power: 142W."*

### UI presentation

**Compact strip** (always visible, below CPU info bar):
```
🌡 78°C  ⚡ 142W  ⚙ 1.32V avg  📊 [▁▃▅▇▆▅▃▂]  ⏵ expand
```

**Expanded dashboard** (click expand or always-on for wide screens):
- Top row: 4 big-number tiles — Package Temp / Package Power / Avg Voltage / Max Core MHz, each with a 60s sparkline
- Per-core grid: 16 small tiles (4×4 for 7950X3D), each showing core# / temp / voltage / clock / util, color-coded background by load
- Memory/FCLK row at bottom
- During test: peak markers overlay the sparklines, "session max" badges on each tile

### Cost

LibreHardwareMonitorLib polls efficiently — typical CPU cost is well under 1% on a modern CPU. Sensor reads run on a dedicated background thread; the HTTP server thread just reads the latest snapshot from a thread-safe variable. UI fetches via `/api/telemetry` once per second.

### Failure handling

If `LibreHardwareMonitorLib.dll` fails to load or sensor enumeration finds nothing useful:
- Telemetry panel shows a small "⚠ Sensor library unavailable — telemetry disabled" badge
- App remains fully functional for everything else (CO setting, testing, reporting)
- User can dismiss the badge

---

## 12. Profiles

**Format:** `ryzen-pro-optimizer/profiles/<name>.json`

```json
{
  "name": "Daily Stable",
  "createdAt": "2026-05-28T03:42:11Z",
  "cpuModel": "AMD Ryzen 9 7950X3D",
  "coreCount": 16,
  "ccdCount": 2,
  "mode": "per-ccd",
  "values": {
    "ccd0": -10,
    "ccd1": -20
  },
  "notes": "4h Prime95 SSE clean, May 27 2026"
}
```

**For `mode: "per-core"`:**
```json
"values": { "0": -10, "1": -12, ..., "15": -22 }
```

**For `mode: "all-cores"`:**
```json
"values": { "all": -15 }
```

**UI behaviour:**
- Sidebar list of profiles with name, mode, summary value, date
- Click profile name → load into the curve setting form (does NOT auto-apply)
- "Apply" button on each profile → directly applies without loading into form (one-click reapply after reboot)
- "Save current as…" button in the curve form → prompts for name + notes
- Profiles are tagged with `cpuModel` — UI warns if user tries to apply a profile saved on a different CPU model

---

## 13. Help Section

A `?` icon top-right opens a slide-out panel with two tabs.

### Quick Start tab

1. **What is Curve Optimizer?** (3 short paragraphs, plain English)
2. **A word about the silicon lottery** (the explainer we agreed on — every chip is unique, every core within it is unique)
3. **Step 1: Pick your mode** (All cores / Per-CCD / Per-core, with when to use each)
4. **Step 2: Set values** (start gentle, e.g. −10, work down)
5. **Step 3: Choose a test** (Prime95 SSE recommended explanation)
6. **Step 4: Read the report** (what the verdict and Smart Suggestions mean)
7. **The Esc panic button** (always available — bound to Esc, or click the red RESET CO button top-right)
8. **Settings reset on reboot** (when you find your sweet spot, set it in BIOS for permanent)

### Advanced tab

1. **Auto-Adjust mode** — what it does, when to use it
2. **Per-CCD strategy for V-Cache chips** — CCD0 is more sensitive
3. **Step-size strategy** — start with 5, narrow to 2, then 1 as you approach the edge
4. **What WHEA events mean** — Bodyguard's role
5. **Profile management** — what's saved, what persists, why no auto-apply on boot
6. **Reading the report** — verdict logic, what FAILED vs INCOMPLETE means
7. **Troubleshooting** — common error states + fixes

Help content lives in `web/help.html` so it can be edited without touching the app.

---

## 14. Error Handling

| Scenario | Behavior |
|---|---|
| App launched without admin | Modal: "Ryzen Pro Optimizer needs administrator rights to write Curve Optimizer values. Click here to re-launch as admin." Button triggers UAC re-launch. |
| `ryzen-smu-cli.exe` missing | Modal: "Required tool not found at expected path: …\tools\ryzen-smu-cli\ryzen-smu-cli.exe. Please reinstall CoreCycler." |
| CPU is Zen 2 or older | Full-screen friendly message: "Your CPU (model) doesn't support per-core Curve Optimizer (introduced with Ryzen 5000). This tool can't help you here." |
| CPU is non-AMD | Same friendly message tailored to "Intel/other CPU" |
| CPU detection fails entirely | Fall back to single "All cores + Per-core (assume 16 cores)" with a yellow banner: "CPU auto-detect failed — using safe defaults." Logs a warning. |
| Port 8765 (default) in use | Server tries 8766, 8767, … up to 8775. .bat shows actual URL. |
| Browser doesn't auto-open | .bat console window stays open and shows the URL prominently for manual open. |
| CoreCycler subprocess dies mid-test | State → REPORTING with partial data, verdict = INCOMPLETE, message: "Test ended unexpectedly. Here's what we got — check the CoreCycler log for details." |
| `ryzen-smu-cli` returns non-zero | Toast: "Failed to apply CO values. Output: …" Stays in current state, doesn't change CO. |
| User closes browser tab mid-test | Server keeps running (the test continues). Reopening the URL resumes the live view. |
| User closes the server .bat window | Test continues (subprocess is detached). On next launch, runtime/state.json is read and the report is shown. CO values reset only on reboot. |

---

## 15. UI Layout (text mockup)

```
┌──────────────────────────────────────────────────────────────────┐
│ ⚡ Ryzen Pro Optimizer       🛡 Bodyguard: Active   ? Help  🔴 RESET CO │
├──────────────────────────────────────────────────────────────────┤
│ AMD Ryzen 9 7950X3D  ·  16 cores  ·  2 CCDs (CCD0=V-Cache, CCD1=std) │
├──────────────────────────────────────────────────────────────────┤
│ 🌡 Pkg 64°C  CCD0 61°C  CCD1 66°C    ⚡ 38W    ⚙ 1.18V    📊 ⏵ expand │
├──────────────────────────────────────────────────────────────────┤
│ 🎯 Detected current Curve Optimizer settings:                    │
│    CCD0 −10  ·  CCD1 −20  (loaded as your starting point)        │
│    [ dismiss ]                                                   │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─ 1. Set Curve Optimizer ─────────────────────────────────┐    │
│  │  Mode:  [ All cores ] [ Per-CCD ] [ Per-core ]           │    │
│  │                                                          │    │
│  │  CCD0 (V-Cache): [ -10 ▾ ]  (current: -10)               │    │
│  │  CCD1 (Standard):[ -20 ▾ ]  (current: -20)               │    │
│  │                                                          │    │
│  │  [  Apply  ]  [ Revert to launch ]  [ Save as profile… ] │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─ 2. Test Stability ──────────────────────────────────────┐    │
│  │  Test:    [ Prime95 SSE ▾ ]                              │    │
│  │  Cycles:  [ 1 ] (3+ recommended for confidence)          │    │
│  │  Mode:    ( ) Manual   ( ) Auto-Adjust (advanced)        │    │
│  │                                                          │    │
│  │  [  ▶ Start Test  ]                                      │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─ 3. Live Status ──────────────  hidden until TESTING ───┐    │
│  │  ●  Testing core 7 (CCD0, V-Cache) at -10                │    │
│  │     Iteration 2 of 3  ·  Runtime 00h 14m 22s             │    │
│  │     Errors so far: 0    WHEA events: 0                   │    │
│  │  [████████░░░░░░░░░░] 41%                                │    │
│  │                                                          │    │
│  │  [ ■ Stop test ]                                         │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─ 4. Report ───────────────────  hidden until REPORTING ─┐    │
│  │  Verdict: ✅ PASSED — All cores stable                    │    │
│  │  Duration: 01h 23m 45s  ·  3 cycles  ·  16 cores tested  │    │
│  │                                                          │    │
│  │  💡 Smart Suggestions:                                   │    │
│  │   • Want to push further? Try Per-CCD: keep CCD0 at -10, │    │
│  │     try -25 on CCD1.                                     │    │
│  │   • Once you find your edge, dial back 2-3 pts for safety│    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─ Profiles ───────────────────────────────────  collapsed ─┐    │
│  │  • Daily Stable           CCD0:-10 CCD1:-20  [Apply][⋯]   │    │
│  │  • Aggressive (4hr clean) CCD0:-15 CCD1:-25  [Apply][⋯]   │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│  ⚠ Stuck or unstable? Press Esc to instantly reset all cores.    │
└──────────────────────────────────────────────────────────────────┘
```

**Expanded telemetry dashboard (when user clicks ⏵ expand):**

```
┌─ Live Telemetry ──────────────────────────────  collapse ⏶ ─┐
│                                                              │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────┐ │
│  │ 🌡 Pkg Temp  │ │ ⚡ Pkg Power │ │ ⚙ Avg VID    │ │ 🔁 Max│ │
│  │   78 °C      │ │   142 W      │ │   1.32 V     │ │5450MHz│ │
│  │ peak 87°C    │ │ peak 168W    │ │ peak 1.41V   │ │       │ │
│  │▁▃▅▇▆▅▃▂▁▂▃▅▇│ │▂▃▅▆▇▇▆▆▅▆▆▇▇│ │▃▄▄▅▅▅▄▄▄▄▅▅▅│ │       │ │
│  └──────────────┘ └──────────────┘ └──────────────┘ └──────┘ │
│                                                              │
│  Per-core (CCD0 V-Cache · CCD1 Standard):                    │
│  ┌────┐┌────┐┌────┐┌────┐┌────┐┌────┐┌────┐┌────┐            │
│  │C0  ││C1  ││C2  ││C3  ││C4  ││C5  ││C6  ││C7  │ CCD0       │
│  │78° ││79° ││76° ││77° ││78° ││76° ││79° ││82° │            │
│  │1.28││1.30││1.27││1.29││1.30││1.28││1.30││1.34│  V         │
│  │5.15││5.18││5.10││5.15││5.18││5.10││5.20││5.25│  GHz       │
│  │ 99%││ 99%││ 99%││ 99%││ 99%││ 99%││ 99%││ 99%│            │
│  └────┘└────┘└────┘└────┘└────┘└────┘└────┘└────┘            │
│  ┌────┐┌────┐┌────┐┌────┐┌────┐┌────┐┌────┐┌────┐            │
│  │C8  ││C9  ││C10 ││C11 ││C12 ││C13 ││C14 ││C15 │ CCD1       │
│  │74° ││75° ││73° ││74° ││75° ││73° ││76° ││74° │            │
│  │1.35││1.36││1.34││1.35││1.36││1.34││1.37││1.35│            │
│  │5.65││5.68││5.62││5.65││5.68││5.62││5.70││5.65│            │
│  │ 99%││ 99%││ 99%││ 99%││ 99%││ 99%││ 99%││ 99%│            │
│  └────┘└────┘└────┘└────┘└────┘└────┘└────┘└────┘            │
│                                                              │
│  Memory: 6000 MT/s   FCLK: 2000 MHz   Fans: CPU 1850 RPM     │
└──────────────────────────────────────────────────────────────┘
```

**Color coding (background of per-core tile):**
- Temp ≤ 70°C: green tint
- 70–85°C: yellow tint
- ≥ 85°C: red tint
- Utilization < 50%: dim; ≥ 50%: brighter

**Visual style:**
- Dark theme by default (most enthusiasts prefer it)
- Accent color: AMD-ish red `#ED1C24` only for danger (Reset, errors)
- Primary action: cool blue `#3B82F6`
- Success: green `#10B981`
- Telemetry chart lines: cyan `#06B6D4` (temp), amber `#F59E0B` (power), violet `#8B5CF6` (voltage)
- Typography: system stack (Segoe UI on Windows)
- Layout: vertical card stack, max-width ~720px in standard mode; widens to ~1100px when telemetry dashboard is expanded

---

## 16. Tech Stack Summary

| Layer | Choice |
|---|---|
| Backend | PowerShell 5+ (`System.Net.HttpListener`) |
| Frontend | HTML + CSS + vanilla JS (ES2020) |
| Communication | HTTP JSON, polling at 1s active / 5s idle |
| CO writing | `ryzen-smu-cli.exe` (bundled with CoreCycler) |
| Stress testing | CoreCycler (existing) |
| WHEA monitoring | `EventLogWatcher` (built-in, event-driven) |
| Persistence | Local JSON files in `ryzen-pro-optimizer/profiles/` and `/runtime/` |
| Entry point | `Launch Ryzen Pro Optimizer.bat` (elevates via UAC, starts server, opens browser) |

---

## 17. Non-Goals

- **Not a CoreCycler replacement.** It runs CoreCycler under the hood.
- **Not a full PBO/memory tuning suite.** CO only.
- **Not a substitute for BIOS.** Values do not persist across reboot. Find your sweet spot here, then write it into BIOS for permanent.
- **Not autonomous.** Manual mode is the default; Auto-Adjust is a pro option for users who explicitly opt in.
- **Not cloud-connected.** No telemetry, no profile sync, no login. Everything is local.

---

## 18. Open Questions / Things to verify during implementation

1. **Does CoreCycler accept a custom config path via CLI flag**, or do we need to swap `config.ini` (and restore the original after)? — needs source inspection.
2. **Exact `ryzen-smu-cli` subcommand for reading current CO values** — CoreCycler uses this for its `startValues = CurrentValues` feature, so the mechanism exists; need to confirm exact CLI syntax during Phase 1.
3. **Does `ryzen-smu-cli.exe` need a separate driver install** (something like winring0)? Usually CoreCycler handles this; verify the path is clean.
4. **WHEA Event Log path on Windows 11** — confirm `Microsoft-Windows-Kernel-WHEA/Errors` matches. (Should, but verify.)
5. **CPU model → CCD count detection for edge cases** (e.g. 5950X is 16 cores dual, but a future 8-core dual-CCD wouldn't fit the >8 rule). For MVP, ">8 cores = dual" + a hardcoded override map for known exceptions is fine.
6. **Whether to use system toast notifications** (via BurntToast PS module or direct WinRT) or stick to browser-only notifications. MVP: browser-only, add system toast as a nice-to-have.
7. **`LibreHardwareMonitorLib.dll` version & sensor mapping per CPU family** — sensor names differ slightly across Ryzen 5000/7000/9000. Need to map by CPU family during Phase 3. Library handles most of this internally, but per-core voltage may not be exposed on all generations.

---

## 19. Success criteria

When the MVP ships, a user should be able to:

1. Double-click `Launch Ryzen Pro Optimizer.bat`
2. See their detected CPU, CCD layout, supported modes, and **existing CO values from BIOS** within 2 seconds
3. Pre-filled form shows their current values — they edit only what they want to change
4. Click Apply — values active in under 1 second; tooltip showed the diff before they clicked
5. Start a 3-cycle Prime95 SSE test and walk away
6. Come back to a clean PASS/FAIL report with friendly next-step suggestions
7. Save the working config as a named profile
8. Click "Revert to launch values" if they want to undo all their experiments and return to where they started this session
9. Reboot, re-launch the app, click their profile → instantly reapplied
10. Hit Esc at any time for an emergency reset to neutral (all zeros)
11. **Watch live CPU temps, power, voltage, and per-core clocks** the whole time — both at idle and under test load, with peak-during-test markers visible in the post-run report

If a WHEA event fires while their app is in their browser idle tab, the indicator turns red and a notification appears.

---

## 20. Build phases (rough)

(Detailed plan will be created by the writing-plans skill after this spec is approved.)

- **Phase 1:** PowerShell HTTP server skeleton + static UI shell + CPU detection + **CO read (BIOS detection)** + launch banner + Help section
- **Phase 2:** CO writing (all-cores, per-CCD, per-core) + Revert to launch + profile save/load + Reset/Esc panic
- **Phase 3:** **Live telemetry panel** (LibreHardwareMonitorLib integration, compact strip + expanded dashboard, sparklines)
- **Phase 4:** Test orchestration (config.ini generation + CoreCycler spawn + live log tail + state machine) + telemetry peak-during-test tracking
- **Phase 5:** Log parser + Report engine + Smart Suggestions (including peak telemetry in the report)
- **Phase 6:** WHEA Bodyguard + system toast polish
- **Phase 7:** Auto-Adjust mode toggle + edge-case error handling + final UX polish

End of spec.
