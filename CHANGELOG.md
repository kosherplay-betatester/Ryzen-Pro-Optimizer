# Changelog

All notable changes to Ryzen Pro Optimizer.

The format is loosely [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow semantic intent (major.minor.patch) but the project hasn't
hit 1.0 yet — see the roadmap in [README.md](README.md#roadmap).

---

## [1.20260603] — 2026-06-03 · "First public release · release-aware auto-updater"

First version cut as an actual GitHub Release rather than a bumped
constant on `main`. Everything from 0.6.0 through 0.8.2 is rolled
into this. Going forward, `main` is the working branch and **users
update from tagged GitHub Releases only** — pushing a half-finished
commit no longer offers itself to the world as a candidate update.

### Versioning

Switched from semver-ish (0.x.y) to `1.YYYYMMDD` calendar versioning.
Reasoning: the project has no formal API; semver minor/patch
distinctions weren't load-bearing; release cadence is feature-driven
not API-driven; date-stamped versions read better in release notes
("got an update prompt on the 3rd? you're on 1.20260603"). YYYYMMDD
ordering is the only date format that sorts correctly as an integer
across month and year boundaries, so the auto-updater's
`[System.Version]`-based comparison stays correct forever.

### New

- **Auto-updater is now release-aware** (`lib/updater.ps1`):
  - `Get-RemoteRpoVersion` queries the GitHub Releases API
    (`/repos/.../releases/latest`) first and uses its `tag_name`
    as the canonical version. Tag is `v`-prefixed for git
    convention; the leading `v` is stripped before comparison
    against the local `$script:AppVersion` constant.
  - If the release has a `.zip` asset attached, that's downloaded
    in preference to the auto-generated source zip. Lets the
    maintainer ship a curated artifact when wanted (e.g.
    pre-fetched CoreCycler/PawnIO/LHM dependencies for an
    offline-friendly bundle).
  - Falls back to the legacy main-branch probe + main.zip download
    when no releases exist, so existing 0.7.x–0.8.2 installs can
    still pull this update via the path they already know. After
    this update lands, the new updater takes over and all future
    updates come from releases.
  - `$script:RpoRemoteSource` caches kind/tagName/downloadUrl
    between probe and download so `Invoke-RpoUpdate` knows where
    to fetch from without re-hitting the API.
  - `User-Agent: Ryzen-Pro-Optimizer-Updater` set on both API and
    download requests (GitHub rejects anonymous requests without
    one and applies stricter rate limits).
  - Archive extraction adapter: if the wildcard
    `Ryzen-Pro-Optimizer-*` directory isn't present (custom asset
    with a different top-level shape), falls back to scanning for
    the first subdir that contains a `server.ps1`. Future-proofs
    against curated zips that might extract as `app/` or similar.

### Notes for maintainers

Workflow shift: stop bumping `$script:AppVersion` on every commit.
Treat `main` as WIP. When ready to ship:

```
git tag v1.YYYYMMDD -m "..."
git push origin v1.YYYYMMDD
gh release create v1.YYYYMMDD --generate-notes [--prerelease]
```

`--prerelease` keeps the release out of the auto-updater's
"latest" pool — useful for soak-testing a new release on your own
machine before promoting. Promote with
`gh release edit vX --prerelease=false` once happy.

If a release ships a bug:
- `gh release edit vX --prerelease` to hide it from the updater,
  push a fixed release immediately after.
- `gh release delete vX --cleanup-tag --yes` to wipe it entirely;
  the updater falls back to whichever previous release is now
  marked latest.
- Users who already updated retain the buggy code locally; they
  recover via the next release prompt, or by restoring from
  `installer-cache/backups/{old}-{timestamp}/`.

---

## [0.8.2] — 2026-06-03 · "Wider i18n coverage + open-by-default views + footer scroll fix"

Three follow-ups based on first-use feedback after 0.8.1.

### New

- **~50 additional UI strings translated** across all 9 locales:
  - Disclaimer modal: title + accept/decline/dont-show buttons
  - Apply confirmation modal: title, lead, all three buttons
  - Tune Theater: "Waiting for first probe", "Narrative", "auto-scroll",
    "Overall", "ETA"
  - Pro Dashboard: all six stat tile labels (Pkg Temp, Pkg Power, Avg
    Clock, Avg VID, Hottest Core, Avg Load), min/avg/max/samples
    annotators, and all five chart titles + the "click to toggle ·
    shift+click to solo" hint
  - Test card: Stress test / Cycles labels, Max value / Increment by
    labels (already in en, now also marked-up on the elements),
    "Default 1 cycle…" hint, Smart Auto-Adjust hint, mode-info boxes
    for Manual test and Auto-Adjust (with embedded `<strong>/<em>`
    preserved via data-i18n-html)
  - Live CO: "What the chip is running with right now…" description
  - Safety Guards: intro paragraph, WHEA-abort label + description,
    Audio alert label + description
  - Settings/Shutdown behaviour: intro paragraph, both checkbox
    labels, "Settings are saved in your browser…", "Show risk
    disclaimer again" button + tooltip
- **Pro Dashboard and per-core expanded telemetry are now open by
  default** on page load. The user lands directly on the full data
  view — charts + per-core voltage / clock / load tiles + V-Cache CCD
  badges — instead of having to click "Open Pro Dashboard" and
  "expand". Both can still be collapsed.

### Fixed

- **Scrolling now reaches the bottom of the page.** The fixed
  three-line footer (warning + service info + version line) was being
  compensated for by `body { padding-bottom: 3rem }` — enough for one
  line, not three. The last card in either column was sliding under
  the footer and getting cut off. Bumped to `6rem` so all card
  content stays above the footer at full scroll.

### Notes

- Some verbose paragraphs remain English in the 8 non-English locales
  for now: the disclaimer body (lead / safety nets / use-at-risk), the
  tabclose-warn explanation, and BIOS vendor walkthroughs. They fall
  back via the lookup chain. A translator can add the missing keys to
  the relevant locale JSON without code changes.

---

## [0.8.1] — 2026-06-03 · "RTL polish · BIOS-baseline tests · BIOS reset button"

Three small but load-bearing follow-ups to 0.8.0 based on real-use feedback.

### New

- **🔄 BIOS values** button in the header — always visible (no need to
  scroll to the Set CO card). Restores the SMU to the launch snapshot
  (= whatever values BIOS had set when the server first booted). Sits
  next to the existing 🔴 RESET CO so the two recovery actions are
  side-by-side: BIOS values = back to the safe baseline you booted
  with; RESET CO = all zeros (more aggressive safety net). Translated
  in all 9 locales.
- **Auto-Adjust and Smart Auto-Adjust now reset SMU to launch (BIOS)
  values before starting**, so probes always begin from a known-safe
  baseline regardless of whatever the user had manually applied this
  session. The previous state isn't lost — it's auto-saved as a
  `pre-auto-adjust-…` / `pre-smart-tune-…` profile before the reset, so
  the user can load it back from the Profiles list. Predictable starting
  point makes tune results reproducible across sessions. Manual test
  mode keeps current behaviour (it explicitly stresses whatever the user
  set).

### Fixed

- **RTL layout polish** for Hebrew and Arabic. Physical `left`/`right`
  CSS properties throughout `style.css` swapped to logical
  (`inline-start`/`inline-end`): accent borders on info boxes,
  profile details, apply summaries, safety banners, theater scopes,
  bios steps; table column alignment; the help panel slide-out (now
  pins to the inline-end so it slides from the right in LTR and from
  the left in RTL with a flipped shadow + translateX); `#close-help`
  and the chart-title absolute positioning; list indents. Asymmetric
  `border-radius: 0 4px 4px 0` shorthand has an explicit RTL override
  block to mirror to `4px 0 0 4px` so the rounded side stays opposite
  the accent border in both directions.

---

## [0.8.0] — 2026-06-03 · "Full-width two-column layout + 9-language i18n"

Two-piece release that reshapes the UI for wide screens and adds
internationalization with eight non-English locales out of the box.

### New

- **Two-column full-width layout.** `<main>` is now a CSS Grid with a
  full-width recovery host on top and two columns underneath:
  - **Left column** carries the live data — CPU info, telemetry strip
    and expanded grid, Safety Guard banner, Tune Theater, Tune Results,
    Pro Dashboard, Live CO, Live Status, Report.
  - **Right column** carries controls and configuration — CO banner,
    BIOS setup card, Set CO form, Test config + start/stop, Profiles,
    Safety Guards, Shutdown behaviour.
  - **`#recovery-host`** is `.col-fullwidth` so panic-revert and
    Smart Tune Paused banners span both columns and read prominently.
  - Max width raised from 1100px to 1800px; collapses to single column
    under 1080px so smaller laptops stay usable.
  - Reorganisation happens via a one-shot JS DOM move on
    `DOMContentLoaded` (`applyTwoColumnLayout()`); source order stays
    semantic so screen readers + diffs aren't disrupted.
- **i18n with 9 locales** — `web/locales/{en,fr,es,de,ru,he,ar,zh,ja}.json`.
  - Lookup strategy: `localStorage.rpo.lang > navigator.language > 'en'`.
    Falls through current language → English → raw key, so partial
    translations still render gracefully.
  - HTML strings carry `data-i18n="ns.key"` (text content),
    `data-i18n-attr="attrname|ns.key"` (any attribute), or
    `data-i18n-html="ns.key"` (innerHTML). ~40 of the load-bearing
    strings — section headers, primary actions, tab labels, common
    status messages — are marked up and translated in all 9 locales.
    Verbose paragraphs (risk disclaimer, BIOS setup walkthroughs)
    stay English in this release and fall back via the chain; a
    translator can fill them in per-locale over time without code
    changes.
  - **Language switcher** in the header (subtle `<select>`); choice
    persists in `localStorage` and applies immediately without a page
    reload. Auto-detects the browser language on first visit.
  - **RTL support** for Hebrew and Arabic — `<html dir="rtl">` is set
    when the locale is `he` or `ar`. Logical CSS properties
    (`margin-inline`, `padding-inline`, `border-inline-start/end`)
    handle most of the mirroring; the recovery card border and
    profile-details accent get explicit RTL overrides in `style.css`.
  - Chinese is Simplified (`zh-CN`) — the variant Android ships as
    default in mainland China.

### Notes

- The 8 non-English locales currently translate the buttons, section
  titles, tab labels, mode names, common labels, recovery banners, and
  toast messages — about 50 strings each. Risk disclaimer paragraphs,
  BIOS setup steps, and tooltips stay English (fallback). A translator
  drop-in only needs to add keys to the relevant locale JSON file;
  no code changes required.
- The layout change is browser-only — no server contract change.
  Auto-updater will deliver the new HTML / CSS / JS / locale files on
  next `Launch.bat` to anyone on 0.6.0 or any 0.7.x.

---

## [0.7.3] — 2026-06-03 · "Smart Tune recovery card · edit & resume"

The pause/resume flow on the recovery card now shows what the previous
session actually found, and gives the user an explicit way to tweak the
per-core starting CO before continuing.

### New

- **Last known-good per-core values** are now rendered as a per-CCD pill
  row inside the recovery card. Resolution rule:
  `LOCKED scope.locked > scope.scopeState.knownStable (deepest stable
  probe) > launch fallback`, with per-core scopes taking precedence over
  their parent CCD scope where both have data. Matches the per-core
  resolution server-side (`Get-RecommendedCoFromTune`) so the table the
  user sees here is the same values that would be written if they
  picked plain Resume.
- **Edit & resume** button on the recovery card flips the values grid
  into per-core number inputs pre-filled with the last-good values.
  Range-clamped to `[-30, +30]`. Two new action buttons appear:
  - **Apply edits & resume** — `POST /api/smart-tune/resume` now accepts
    an optional `values: int[]` payload; if present and valid (length =
    cpu cores, each in range), the server writes the user-edited array
    to the SMU (with the standard panic-revert breadcrumb) before
    handing off to `Resume-SmartTune`. The bisection then continues
    from the user's chosen starting point.
  - **Cancel edits** — restores the read-only pill view, original
    Resume / Edit / Discard action row.
- Recovery card meta now also surfaces **"Scopes locked: M / N"** so the
  user can see at a glance how far the session got before it was
  interrupted.

### Fixed

- The pending-session info that previously only showed `Mode` and
  `Status when stopped` left the user with no concrete read on *what
  CO values* the resume would actually start from — a real concern
  after an hours-long tune that gets paused. Now both the values **and**
  the option to change them are surfaced explicitly.

---

## [0.7.2] — 2026-06-03 · "Telemetry handler hardening"

Defensive fix only — no behaviour or UI changes.

### Fixed

- **`/api/telemetry`, `/api/telemetry/history`, `/api/telemetry/peaks`
  no longer return `ERR_CONNECTION_RESET` when LHM hiccups.** The three
  routes called into `Read-TelemetrySnapshot` / `Get-TelemetryHistory`
  / `Get-Peaks` with no error handling; if a LibreHardwareMonitor
  sensor enumeration threw (driver glitch, SMU contention while a tune
  was running) the response never sent and the OS reset the TCP
  connection. The polling loop client-side logged `ERR_CONNECTION_RESET`
  on a 1Hz cadence and the only fix was a server restart. Each handler
  now wraps its body in a try/catch and turns a throw into a clean
  `{ ok: false, error: "..." }` 200 the UI can render and retry from.
  Hangs in the LHM call (sensor stuck rather than throwing) still
  require a restart - timing those out needs an async pattern that's a
  bigger change.

---

## [0.7.1] — 2026-06-03 · "Tune Results table + report-mode default"

Smart Auto-Adjust now ships with an explicit per-core results view and a
new default behaviour that protects the user from accidentally living
on whatever value the tune happened to end at.

### New

- **Tune Results card** — appears when Smart Auto-Adjust transitions to
  `COMPLETED`. One row per core showing **Start CO**, **Recommended CO**
  (per-core scope's locked value > parent CCD scope's locked value >
  launch fallback), **SMU now**, **owning scope**, **probe count**, and
  **outcome** (Locked / Failed / Not tuned). Colour-coded green / amber
  / neutral with first-column status bar. Four explicit action buttons:
  - **Apply recommended values** — `POST /api/smart-tune/apply-results`
    writes the resolved per-core CO to the SMU; same panic-revert
    breadcrumb pattern the safety guard uses, so a hung write on
    apply still has a rollback path on next boot.
  - **Revert to launch values** — reuses the existing `/api/co/revert`.
  - **Save as profile…** — names + persists the recommended values via
    the standard `/api/profiles` endpoint, so it appears in the regular
    Profiles list with full Load / Apply / Delete affordances.
  - **Dismiss** — hides the card; state persists server-side so it can
    be re-surfaced.
- **`applyMode` option on Smart Auto-Adjust start** — radio in the
  start form, with two values:
  - **`report`** *(new default, recommended)* — probes apply CO writes
    during the tune as they have to (you can't stress-test a value
    without writing it), but when the tune completes the server
    automatically restores the launch CO snapshot before flipping the
    state to `REPORTING`. The user reviews the Tune Results card and
    commits the recommended values explicitly via the Apply button.
    Safer-by-default for users walking away from a multi-hour run.
  - **`live`** *(opt-in)* — legacy behaviour. SMU stays at whatever the
    tune ended at. Use when you want continuous, in-place tuning and
    have eyes on the system.
- **`Get-RecommendedCoFromTune`** in `lib/smart-tuner.ps1` and the new
  **`POST /api/smart-tune/apply-results`** route — both sides agree on
  the same resolution rule: per-core scope wins over CCD scope when
  both locked; FAILED and PROBING bounds are not trustworthy, so those
  cores fall back to the launch value rather than the half-explored
  state machine bound. Refuses to apply unless the tune status is
  `COMPLETED` (no partial commits while probing is still in flight).

### Notes

- Basic Auto-Adjust (the CoreCycler-driven AutomaticTestMode) keeps its
  current behaviour this release. Adding report-mode there requires
  intercepting CoreCycler's own CO writes, which is a larger change;
  the per-core results table will be extended to surface it from the
  CoreCycler log tail in a follow-up.

---

## [0.7.0] — 2026-06-03 · "Auto-updater + per-core visibility"

Two themes: full per-core visibility during both stress tests and Smart
Tune, and a built-in auto-updater so users on `0.6.0` will be prompted
to install this release the next time they run `Launch.bat`.

### New

- **Auto-updater.** `Launch.bat` now probes
  `raw.githubusercontent.com/.../server.ps1` on every boot (rate-limited
  to once every 6 h), parses `$script:AppVersion`, and if a newer
  release is on `main` shows a coloured `Y/N/S` prompt that defaults to
  Yes. On Yes: downloads `main.zip`, snapshots non-preserved top-level
  files into `installer-cache/backups/{old-version}-{timestamp}/` for
  one-shot rollback, then overlays the extracted tree — leaving
  `runtime/` (state + history + logs), `profiles/` (user profiles),
  `corecycler/`, `vendor/`, and `installer-cache/` untouched. Refuses
  to apply if another instance is listening on `127.0.0.1:8765` or if a
  panic-revert / RUNNING tune session is on disk. A separate
  `Update.bat` triggers a manual force-check that bypasses both the
  rate-limit and any "skip this version" marker.
- **Per-core test progress grid.** New `Parse-LiveCoreStats` in
  `lib/corecycler-runner.ps1` walks the CoreCycler log forward,
  attributing iterations / per-core errors / WHEA-delta to whichever
  core was active at the time of the event. Surfaced via
  `s.live.perCore` and rendered as a pill grid under the existing Live
  Status line — one pill per probed core, color-coded by status (green
  passed / blue testing / amber failed) with inline `N err` / `N WHEA`
  tags. Persists between status polls so you can see the full picture
  of which cores already cleared their iterations and which are still
  in flight.
- **Smart Tune progress overlay on Live CO per-core pills.** Each
  per-core pill in the Live CO panel now shows the live SMU value
  *plus* a badge derived from `s.smartTune.scopes` — 🔒 for locked
  (green border), ▶ for currently probing (blue, pulsing), dashed
  border + dimmed for pending, ❌ for failed. Resolution prefers the
  per-core scope when it has state, falls back to the parent CCD
  scope otherwise — so during phase A (CCD bisection) all eight cores
  of CCD0 share its status; during phase B (per-core refinement) each
  core gets its own. Adds a small legend strip while a tune is RUNNING.
- **Live CO panel always visible.** Removed the `hidden` class and the
  `state === TESTING` gate. The SMU snapshot is useful idle (to verify
  the BIOS-applied CO matches your saved profile) as well as during a
  tune. `pollCurrentCo` already self-gates on `SupportsCurveOptimizer`
  so non-Ryzen / pre-Zen3 systems stay no-op.
- **Auto-switch Live CO to Per-core view on Smart Tune start.** Saves a
  click; respects any later manual switch (the auto-switch is one-shot
  per tune session and resets when the tune ends).

### Fixed

- **`Inspect-SafetySnapshot` 500-ing /api/status every tick** — second
  pass on the same endpoint hardened in 0.6.0. Two distinct bugs:
  - `@($violations)` against a `Generic.List[object]` raises
    `[System.ArgumentException] "Argument types do not match"` under
    PowerShell 7.5+. This was the runtime cause; `$violations.ToArray()`
    flattens to `Object[]` cleanly. Documented inline with the existing
    `[Math]::Max` antipattern, since both stem from PSObject-wrapping
    of hashtable values under StrictMode Latest.
  - The defensive catch shipped in 0.6.0 (commit `18d43f9`) had its own
    PowerShell parser bug — `Select-Object -First 3 -join ' | '`
    parsed `-join` as a non-existent parameter on `Select-Object`. So
    when the inner try threw, the catch's diagnostic log raised
    `ParameterBindingException` and propagated up to `Invoke-ServerLoop`,
    producing the very 500 the guard was meant to suppress. Fixed with
    explicit parens around the pipeline, plus an inner `try {} catch {}`
    around `Write-Log` so a future formatting mistake here can't
    re-introduce the same class of bug.

---

## [0.6.0] — 2026-06-02 · "Audit-hardened"

A long iteration day driven by a real-hardware smoke test on a 7950X3D,
followed by a multi-agent code audit and four batched fix tiers.

### New

- **Live Curve Optimizer panel.** Shows the SMU's actual current per-core
  CO values during a tune, refreshed every 3 s via `/api/co/current`.
  Visible only while state == TESTING. Three view tabs: Summary
  (one-line synopsis), Per-CCD (one row per CCD), Per-core (pill chips
  grouped by CCD with negative/zero/positive color coding). Auto-Adjust
  and Smart Tune writes are now visible in real time as the tuner walks
  through cores.
- **Pre-tune profile snapshots.** Before any Auto-Adjust or Smart
  Auto-Adjust run, the current CO is automatically saved as a regular
  profile named `pre-auto-adjust-<ts>` / `pre-smart-tune-<ts>`. Visible
  in the Profiles list; load-and-apply at any time to roll back. Filename
  uses millisecond precision so rapid double-starts don't overwrite the
  original baseline.
- **Apply confirmation modal.** Clicking Apply now opens a modal showing
  the per-CCD breakdown of the offsets being written, with three buttons:
  📸 Save profile & apply (auto-saves as `set-curve-optimizer-<ts>`),
  Apply only (write without saving), or Cancel.
- **Profile Details button.** Inline expansion below each profile row
  shows mode, CPU model, core/CCD count, saved date, notes, summary, and
  per-core CO values as pill chips. Lets you preview before Load/Apply.
- **Granularity transparency.** Smart Auto-Adjust Goal Mode dropdown now
  labels each option's tuning granularity ("per-CCD" vs "per-CCD +
  per-core"), and a new info-box explains what each mode does and what
  per-CCD vs per-core means. Auto-Adjust info-box gains a "per-core
  tuning" badge.
- **Three-state legend filter on Pro Dashboard charts.** Click a core in
  a per-core chart legend to toggle its visibility; shift+click to
  solo it (hide all others); shift+click the solo'd item to restore
  all. Small hint string next to each chart title for discoverability.
- **HTML chart tooltip.** Tooltips render as a `<div>` on `document.body`
  with `pointer-events: none` and viewport-edge-flipping, so the
  16-row per-core tooltip is no longer clipped by the canvas.
- **App version surfaced in the UI footer.** New `/api/version`
  endpoint; footer shows `v0.6.0` with a link to this CHANGELOG.

### Fixed

- **"Start failed: undefined" toast.** Root cause: `Write-TunerNarrative`
  ended with `$entry` as its last expression, leaking the record onto
  the pipeline. `Start-SmartTune` calls it twice during start; those
  entries bubbled up alongside the handler's `@{ok=$true; data=...}`
  hashtable, PowerShell collected them into a 3-element array, JSON
  serialized as array, frontend read `r.ok` on array → `undefined`,
  toast fired despite the tune actually starting successfully. Fixed by
  no longer returning `$entry`.
- **Legend clicks not registering on per-core charts.** Two layout root
  causes: (1) `canvas.height` attribute (Chart.js's logical space) =
  266 while CSS forced canvas to 240, so legend hit boxes recorded at
  y=246 fell outside the displayed canvas; (2) Chart.js sized the
  canvas to fill `parent.clientHeight` without accounting for the
  `.chart-title` sibling, so the canvas overshot the chart-box bottom
  and `elementFromPoint` at the legend position returned the parent
  grid, not the canvas. Fixed by absolute-positioning the title (out
  of normal flow), removing the `!important` canvas height override,
  and giving the chart-box explicit dimensions.
- **`Inspect-SafetySnapshot` 500s on `/api/status`.** Real-hardware
  session hit `[System.ArgumentException] Argument types do not match`
  inside the safety inspector. The most plausible trigger is overload
  resolution on `[Math]::Max(0, PSObject)` — PowerShell can wrap
  hashtable values in `PSObject` and the int/PSObject pair doesn't
  exact-match any `Math::Max` overload. Replaced with explicit `[int]`
  coercion and plain comparison. Also wrapped the whole inspection in
  try/catch so a transient snapshot issue degrades to no-op for one
  tick instead of 500'ing the polling endpoint.

### Audit-batch fixes (multi-agent code review, 4 tiers)

**Tier 1 — critical security and reliability:**

- Stored XSS escaping at 11 sites via new `escHtml()` helper: profile
  name/cpuModel/notes in `loadProfiles` + `toggleProfileDetails`
  (widened by the new Details panel), narrative `e.message` /
  `e.icon`, panic-revert `p.reason`, pending-session `p.mode` /
  `p.status`, `smartSuggestions`, `cpuInfo.Name`, report's failed-cores
  table, safety banner violations and `lastEvent`, theater scope id
  and "currently" strip.
- `Process` handle leak in `Get-AllCoreCo` / `Set-AllCoreCo` on the
  5-second timeout path: `Kill()` + `throw` skipped `Dispose()`. Now
  wrapped in try/finally so Dispose always runs.
- `Get-SafeProfileName` blocks Windows reserved device names
  (NUL/CON/PRN/AUX/COM1-9/LPT1-9). A profile named "NUL" silently
  wrote to the null device, data lost, `Get-Content` hung forever.
  Also strips trailing dots/spaces (Win32 API silently truncates,
  producing files that can't be deleted) and caps basename length.
- `ConvertTo-CoreArray` per-core mode now throws on missing keys
  instead of silently coercing to 0. A 16-core profile applied to a
  24-core CPU used to write CO=0 to cores 16–23 without warning.

**Tier 2 — high-impact correctness:**

- `$ValidTransitions['REPORTING']` now allows TESTING and
  APPLYING_CO. `/api/test/start` and `/api/smart-tune/start` both
  accept REPORTING as a valid starting state but the state machine
  used to throw "Invalid state transition" on the second back-to-back
  run from REPORTING.
- `Resume-SmartTune` carries `scopeState` forward for LOCKED/FAILED
  scopes. Previously dropped, so resumed scopes showed
  `probesCompleted=0` and phase-B per-core scopes had no parent CCD
  state to seed from.
- Phase-B per-core scopes seed from parent CCD's locked value
  (`SeedValue` + `KnownStableHint`) instead of cold-starting at 0.
  Burned probe budget walking through territory already proven stable.
- History CPU model comparison now normalizes (trim + collapse
  whitespace + lowercase) on both sides. Microcode-revision or stray
  whitespace differences between sessions used to silently produce no
  history hint and restart cold.
- `pollStatus` guarded by in-flight flag; `loadReport()` debounced to
  the transition into REPORTING. Previously the polling loop stacked
  on slow servers and `loadReport()` re-fetched + reset the report
  card's scroll position once per second while in REPORTING.
- Esc handler stops the active test/Smart Tune before resetting CO,
  and closes the apply-confirmation modal if open. Was silently
  writing zeros mid-run while the test kept going as if nothing
  happened.
- Double-Apply race guarded by `applyInFlight` flag at both entry
  points (form Apply modal + profile-list Apply button).

**Tier 3 — defensive correctness:**

- `Save-TuneSession` wrapped in try/catch. A `Set-Content` failure
  used to propagate as a terminating error and crash `Step-SmartTune`
  mid-probe, dropping all in-memory state. Best-effort + WARN log.
- `Test-LhmInstalled` checks every DLL in the pinned NuGet recipe,
  not just the main one. A partial install (NuGet 404, AV quarantine)
  left vendor/ with a subset of the 6-DLL stack, the next launch
  skipped repair, and LHM `Open()` crashed at runtime with
  `TypeLoadException`.
- Startup panic-revert / pending-session parse `catch {}` now logs +
  removes the corrupt file. A truncated recovery file silently
  disabled the very prompt it existed to enable.

**Tier 4 — defensive cleanup:**

- Path traversal canonicalization in `lib/http-server.ps1`. The
  `\.\.` regex caught the common case but missed absolute-path
  injection: `/C:/Windows/...` after `TrimStart('/')` became
  `"C:/Windows/..."` and `Join-Path` silently returned the right-hand
  absolute path, escaping `$WebRoot` entirely. Now
  `[IO.Path]::GetFullPath` both sides + `StartsWith` verification.
- `Invoke-GracefulShutdown` idempotent — `$script:ShutdownRequested`
  set at the top with an early-return. The tick callback fires from
  two places, so a rapid request burst overlapping a heartbeat
  timeout could double-invoke CO revert + `Stop-CoreCyclerRun`.
- `Enable-SafetyGuard` double-arm guard: warns + calls
  `Disable-SafetyGuard` first if already active, instead of silently
  overwriting `OnAbort`.
- `Set-CurrentState` same-state self-transition logged at DEBUG so a
  double-start race is at least findable in `server.log`.
- `log-parser.ps1` regex tightened: `core .* errored` →
  `\bcore \d+ (has )?errored\b`. The old pattern could match
  informational lines like "checking if core 4 has errored (none
  found)" and produce a false FAILED verdict on a passing run.
- `cpu-detect.ps1` heuristic now recognizes mobile/APU H/U/HS/HX
  suffixes as monolithic single-CCD (Cezanne 5800H, Phoenix 7840HS,
  Hawk Point 8945HS). The fallback `cores > 8 → dual-CCD` previously
  misclassified them.
- `help.html` `innerHTML` now goes through `DOMParser` with
  `<script>` / `on*=` / `javascript:` stripped. Habit defense even
  though the file is local-only.
- `ProDash.hide()` also hides `#chartjs-html-tooltip` so the orphan
  element doesn't sit on `document.body` at opacity 0 forever.

### Verified non-bugs (called out by the audit, kept as-is)

- `Test-CoWritesStuck`'s `stuck` flag is consistent end-to-end with
  the frontend's `writesStuck` handling. Variable name is misleading
  ("stuck" = "register stuck to wanted value"), logic is correct.
- `corecycler-runner.ps1` `stopOnError = if (X) { 0 } else { 0 }`
  looks like a paste error but the runtime is intentional: manual
  mode uses `skipOnError=1` to continue testing remaining cores,
  auto-adjust mode keeps re-testing failed cores after CO bump.
- WHEA baseline captures queue size at arm time; post-arm arrivals
  trigger the delta. Working as designed.
- `Get-LockInValue` overclock margin collapsing `knownStable=1 → 0`
  is consistent with the existing undervolt test contract; intentional
  conservative safety when stable is shallower than the margin.

### Process

- `bbeta_sandbox`-shaped dev/sandbox split (edits in dev clone, runtime
  state in `_beta_sandbox`). Live debug session for the legend-click
  fix used Chrome DevTools MCP to identify the canvas dimension
  mismatch root cause.
- 5 parallel code-review agents over PowerShell server, Smart Tune
  engine, safety/CoreCycler/CO, frontend, and persistence/installer.

### Tests

88/88 Pester green throughout the day. Four new tests for
`Save-PreTuneSnapshot` (filename format, mode, round-trip through
`Get-ProfileList`, invalid-process rejection).

---

## [0.5.0] — 2026-06-01 · "Smart Auto-Adjust on a real bench"

First real-hardware smoke test on a 7950X3D. Five bugs the 84-test
Pester suite missed, all shipped:

- `b1b2abf` — `lib/http-server.ps1` logs exception type + route + stack
  on handler error (diagnostic).
- `79877b3` — Smart Tune: capture `$script:Tune` locally before
  `.GetNewClosure()`. Closures created inside a dynamically-invoked
  route handler don't inherit `$script:` scope, so `$script:Tune.Scopes`
  was `$null` inside `$applyFn` even though `Step-SmartTune` saw it.
- `f82b3cf` — `lib/http-server.ps1` rebuilds the `HttpListener` on each
  port attempt. `Start()` failure nulls the `.Prefixes` collection, so
  retrying with the same instance crashed.
- `ed3dc22` — `/api/status` skips the TESTING→REPORTING auto-transition
  while Smart Tune is running. Smart Tune spawns one CoreCycler per
  probe and the server is idle between, so the auto-transition tripped
  within 1s of starting and disarmed the Safety Guard mid-tune.
- `7f9bb73` — `Invoke-Probe`: wrap `Get-Content` so 0/1-line logs bind
  to `[string[]]`. Used to fail with "Cannot bind argument to parameter
  'LogLines' because it is an empty string" whenever a probe exited
  fast.
- `02f30c8` — installer enforces TLS 1.2 before any web call. Windows
  PowerShell 5.1 inherits the system's default; on un-patched hosts
  this can still be Tls10/11, both of which GitHub and NuGet refuse.

---

## [0.4.0] — 2026-05-28 → 31 · "Smart Auto-Adjust"

A bisection-based, telemetry-aware, history-learning auto-tuner with
five user-selectable goal modes (Daily Driver, Max Stable, Adaptive,
Characterize, Overclock). Smart Tune narratives stream live via a
seqId-paginated narrative log. Crash-recovery resume from
`runtime/tuner-session.json`. Append-only per-CPU history ledger that
seeds future sessions and permanently records crash data points as
guard rails. V-Cache CCD tighter bounds + probe-first ordering. Safety
margin locked-in values shifted away from the discovered edge by the
mode's `marginPoints`. Tune Theater UI: progress header, "currently"
strip, per-scope bisection ladder cards, live narrative log with
icons.

84 Pester unit tests covering the search engine, history queries,
mode policies, narrative buffer, and orchestrator state machine.

---

## [0.3.0] — earlier · "Pro Dashboard + Safety Guard + BIOS helper"

- Pro Dashboard with Chart.js live charts: per-core clock, temperature
  (Pkg + CCD), per-core voltage, package power, V/F scatter, stats
  grid, per-core heatmap, history export.
- Safety Guard with hysteresis (3 consecutive breach samples before
  abort), hard-abort on temp/voltage/WHEA, abort callback that stops
  the test + steps every core back one increment toward neutral.
- Panic-revert breadcrumb survives BSODs: written before every CO
  write, deleted after success; presence on next boot signals
  "previous session crashed."
- Startup risk disclaimer with versioned acceptance in localStorage.
- First-run BIOS-setup helper: read-back verification of every CO
  write detects SMU-ignored writes (PBO/CO disabled in BIOS) and shows
  a per-vendor (ASUS/MSI/Gigabyte/ASRock + Generic) tabbed help card
  with menu paths.

---

## [0.2.0] — earlier · "Test runner + reports"

- CoreCycler integration with selectable Prime95 mode (SSE / AVX2 /
  AVX-512).
- Auto-Adjust mode that walks per-core CO toward each core's stable
  edge.
- Log parser turning CoreCycler + Prime95 logs into a pass/fail
  report with per-core failure breakdown.
- Smart Suggestions: context-aware next-step recommendations based on
  which cores failed and how.
- Peak tracking during tests for thermal sanity-checking.

---

## [0.1.0] — initial · "CO read/write from Windows"

- PowerShell HTTP server bound to `127.0.0.1`.
- ryzen-smu-cli wrapper for SMU register read/write via PawnIO.
- Vanilla JS + Chart.js UI: three modes (all-cores / per-CCD /
  per-core), profile save/load, panic-Esc reset.
- LibreHardwareMonitorLib live telemetry (Pkg temp / power / per-core
  V / clock / load), CCD-aware grouping, V-Cache CCD detection.
- WHEA Bodyguard: Event-Log subscription for hardware corrected-error
  detection.
- 6-state state machine: IDLE → APPLYING_CO → TESTING → STOPPING →
  REPORTING → IDLE (plus ERROR).
