# Changelog

All notable changes to Ryzen Pro Optimizer, starting from the first
public release (`1.20260603`).

The format is loosely [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions are calendar-style: `1.YYYYMMDD` — major version + release date.

---

## [1.20260603] — 2026-06-03 · "First public release"

Initial public release. Everything the app does as of this date is
listed here; subsequent releases will only log what *changed*.

### Curve Optimizer

- Set per-core CO offsets from Windows (no BIOS reboot required) via
  the SMU. Three input modes: **All cores**, **Per-CCD**, **Per-core**.
- Detects the current CO at startup and pre-fills the form so you
  always know your starting point.
- **Apply** is diff-aware — disabled until you actually change
  something; tooltip shows the delta.
- **🔄 BIOS values** header button restores the SMU to the launch
  snapshot (= what BIOS had set when the server booted).
- **🔴 RESET CO** header button sets all cores to 0 instantly. Same
  panic action bound to the `Esc` key.
- **Panic-revert breadcrumb** persists the previous CO state on disk
  before every write; survives BSODs so the next boot can offer to
  roll back to safe values automatically.

### Stability testing

- Wraps [CoreCycler](https://github.com/sp00n/corecycler) so the
  proven stress-test machinery handles Prime95 orchestration.
- Three stress modes: **Prime95 SSE** (recommended for CO), **AVX2**,
  **AVX512**.
- Three test modes:
  - **Manual test** — stresses your current CO values, reports
    pass/fail per core with smart next-step suggestions.
  - **Auto-Adjust** — CoreCycler's per-core autotuning. Bumps each
    core's offset upward (less negative) on error and re-tests until
    every core sits at its individual stable edge.
  - **Smart Auto-Adjust (Pro)** — bisection search guided by live
    telemetry and prior crash history. Five Goal Modes (Daily
    Driver / Max Stable / Adaptive / Characterize / Overclock),
    direction toggle, V-Cache CCD awareness, cross-session learning.
- Tests + Auto-Adjust always **start from the launch (BIOS)
  snapshot**, so probes begin from a known-safe baseline. Whatever
  you had set is auto-saved as a `pre-auto-adjust-…` /
  `pre-smart-tune-…` profile first so it's never lost.
- **Live Status** card shows current core, iteration count, error +
  WHEA totals, runtime. Per-core progress grid below it colour-codes
  every probed core (passed/testing/failed) with inline error tags.

### Smart Auto-Adjust visibility

- **🎬 Tune Theater** — live narrative log of every algorithm step,
  per-scope ladder cards with bounds and probe counts, "currently
  probing" strip, overall progress percent + ETA.
- **🎯 Tune Results card** — per-core table that appears when the
  tune completes. One row per core: **Start CO** · **Recommended**
  (resolved per-core scope's locked value, falling back to parent
  CCD scope, then launch) · **SMU now** · scope · probe count ·
  outcome (Locked / Failed / Not tuned). Colour-coded green / amber
  / neutral. Action buttons: **▶ Apply recommended** ·
  **↺ Revert to launch** · **💾 Save as profile** · **Dismiss**.
- **Apply-mode** toggle on start: **Show report (default,
  recommended)** reverts SMU to launch values on tune completion so
  the user reviews the table and commits explicitly; **Apply as we
  go** keeps the SMU at whatever the tune ended at (legacy).
- **Recovery card** for paused / interrupted Smart Tune sessions:
  shows mode + status when stopped + last known-good per-core values
  in a per-CCD pill row, with **Resume**, **✎ Edit & resume**
  (editable inputs pre-filled with the last-good values), and
  **Discard** actions. Edited values are written to SMU before the
  bisection picks up again.

### 🎯 Live Curve Optimizer

- Always-visible panel showing the SMU's actual per-core CO values
  every 3 s. Three views: **Summary**, **Per-CCD**, **Per-core**.
- During a Smart Tune, every per-core pill gains an overlay badge
  derived from the scope's state: 🔒 locked (green border), ▶
  probing now (blue, pulsing), dashed/dimmed pending, ❌ failed.
- Auto-switches to **Per-core** view when a Smart Tune starts (one-
  shot — respects manual switches afterwards).

### 📊 Pro Dashboard

- Live charts: per-core clock (MHz), per-core voltage (V),
  temperature (°C — Pkg + per-CCD), package power (W), and a
  V/F boost-map scatter (current snapshot).
- Stats grid: Pkg Temp · Pkg Power · Avg Clock · Avg VID · Hottest
  Core · Avg Load — each with min / avg / max over the selected
  window.
- Time-window pills: 60s / 3m / 10m / 30m. Pause / reset / export
  controls.
- Per-core heatmap. Three-state legend on per-core charts: click to
  toggle a core, shift+click to solo it, shift+click again to
  restore all.
- **Open by default** on page load along with the per-core expanded
  telemetry grid — page lands directly on the full data view.

### Safety

- **🛡 Safety Guard** — configurable hard limits that abort an
  Auto-Adjust the instant they're exceeded. Default: 95°C package
  temp, 1.45 V VID. Hysteresis-based (avoids 1-tick spikes
  aborting). On trip: reverts SMU to launch snapshot and writes a
  panic-revert breadcrumb.
- **WHEA Bodyguard** — subscribes to Windows hardware error events.
  Configurable auto-abort + audio alert on WHEA fire during
  Auto-Adjust.
- Tab-close shutdown and Esc shutdown are **opt-in** (Chrome's
  memory-saver and RDP disconnects look like a closed tab and would
  otherwise kill the service mid-test).

### Profiles

- Save / Load / Apply per-core CO profiles. Standard list view with
  inline Details expansion (mode, CPU, core/CCD count, saved date,
  notes, summary, per-core CO pills).
- **Apply confirmation modal** — shows the per-CCD breakdown of the
  offsets and offers an inline **Save profile & apply** that
  snapshots as `set-curve-optimizer-<ts>` first.
- Auto-snapshot before every Auto-Adjust / Smart Auto-Adjust run as
  `pre-auto-adjust-…` / `pre-smart-tune-…`.

### Layout + i18n

- Full-width two-column layout: live data on the left
  (telemetry / Pro Dashboard / Tune Theater / Tune Results / Live
  CO / status / report), controls and configuration on the right
  (CO form / Test config / Profiles / Safety Guards / Settings).
  Recovery banners span full width.
- Collapses to a single column under 1080px for laptops.
- 9-language UI: English, French, Spanish, German, Russian, Hebrew,
  Arabic, Chinese (Simplified), Japanese. Language switcher in
  header; choice persists in localStorage; auto-detects browser
  language on first visit. **RTL** support for Hebrew and Arabic.
- Verbose paragraphs (risk disclaimer body, BIOS vendor walkthroughs)
  fall back to English where translation strings aren't yet defined
  — translator drop-in only needs to add keys to the relevant locale
  JSON, no code changes.

### Installer + updater

- **Install.bat** auto-fetches dependencies: CoreCycler (latest GitHub
  release zip), PawnIO driver (latest installer EXE), and
  LibreHardwareMonitor + companions (NuGet `net472` builds, the only
  build PS 5.1 can load).
- Self-heals an incompatible `.NET 10` LHM DLL by re-running the
  installer to fetch the `net472` build.
- **Launch.bat** self-elevates and runs the compatibility check; runs
  the installer automatically if anything is missing.
- **Auto-updater** built into Launch.bat (rate-limited to once per
  6 h). Queries the **GitHub Releases API** for the latest release
  tag; if newer than your local version, prompts `Y/N/S`. On `Y`:
  downloads the release zip (prefers attached `.zip` asset, otherwise
  the auto-generated source zip), snapshots non-preserved files to
  `installer-cache/backups/{old-version}-{timestamp}/`, then overlays.
  **Never touches** `runtime/`, `profiles/`, `corecycler/`, `vendor/`,
  `installer-cache/`. Refuses to run if another instance is on port
  8765 or a tune is mid-flight on disk. Pre-releases are skipped.
- **Update.bat** forces an immediate update check, bypassing the
  6-h cache and any skip-version marker.

### Notes for maintainers

`main` is the WIP branch — push freely; nothing on `main` reaches
users automatically. Users update from tagged GitHub Releases only.

To cut a release:

```
git tag v1.YYYYMMDD -m "..."
git push origin v1.YYYYMMDD
gh release create v1.YYYYMMDD --generate-notes [--prerelease]
```

`--prerelease` soak-tests on your own machine first; promote with
`gh release edit vX --prerelease=false`.

To pull a bad release:
- `gh release edit vX --prerelease` hides it from the updater.
- `gh release delete vX --cleanup-tag --yes` wipes it entirely.

Users who already updated keep the buggy code locally until the next
release fixes it; they can also restore from
`installer-cache/backups/{old}-{timestamp}/`.
