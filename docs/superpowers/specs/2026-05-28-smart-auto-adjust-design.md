# Smart Auto-Adjust — Design Spec

**Status:** Approved design, implementation pending
**Date:** 2026-05-28
**Project:** Ryzen Pro Optimizer

## Problem

CoreCycler's built-in `enableAutomaticAdjustment` does a single thing: when
a core errors during a stress test, it adds N points to that core's CO
offset and tries again. It's a linear search with no telemetry awareness,
no memory across sessions, no V-Cache awareness on X3D parts, and no
guardrail against the algorithm itself pushing the system into a BSOD.

Ryzen Pro Optimizer now has the infrastructure to do much better:

- Real telemetry (LibreHardwareMonitor, working under PS 5.1 again)
- A live Safety Guard that monitors temperature, VID, and WHEA
- A panic-revert breadcrumb that survives BSODs
- CPU topology awareness (V-Cache CCD identification on X3D parts)
- A history file we can write to and read from

Smart Auto-Adjust uses all of that to build a fundamentally better
auto-tuner — one that converges faster, learns across sessions, treats
the V-Cache CCD with appropriate caution, and crucially **shows the user
exactly what it's doing at every step** so multi-hour runs feel transparent
instead of opaque.

## Goals

1. **Stability is king.** Locked-in values must be reliably stable under
   real workloads, never the absolute edge. Margin > performance.
2. **Faster convergence.** Bisection-based search uses log₂ probes vs
   CoreCycler's linear search.
3. **Survives a crash.** A BSOD mid-tune becomes one data point. The next
   session resumes from where it stopped, without re-probing values
   we've already proven dangerous.
4. **Full transparency.** Every probe, every classification, every bound
   change is visible to the user in real time. "Stuck" is never a
   possibility — the UI always says what's happening and what's next.
5. **Pro-grade modes.** Five user-selectable goals from "find safe daily
   values in 30 min" to "characterize every core's full V/F curve."

## Non-goals

- Replacing CoreCycler. We orchestrate it in single-iteration bursts and
  ingest its pass/fail signal. Prime95 is still the stress engine.
- Parallel multi-core probing. Sequential only — attribution must be
  unambiguous.
- Cross-machine learning. History is per-CPU-model, never uploaded.

## User-facing modes

Five selectable goals (radio buttons in the Test card, default = Daily Driver):

| Mode | Direction | Time | Iterations/value | Per-CCD vs per-core | Safety margin |
|---|---|---|---|---|---|
| **Daily Driver** (default) | undervolt (–) | 30–60 min | 2 clean | per-CCD | +2 points |
| **Max Stable** | undervolt (–) | 3–6 h | 5 clean + cross-check | per-CCD then per-core refine | +1 point |
| **Adaptive** | undervolt (–) | hours/days, background | continuous re-verify | per-core, slow-growth | +2 points |
| **Characterize** | both | ~1 h | 1 short pass per probe point | per-core | n/a (insight only) |
| **Overclock** | overshoot (+) | 1–2 h | 3 clean | per-core | –1 point (toward safer) |

Mode determines the **policy** (verification depth, search bounds, step
sizes, termination criteria); the **algorithm engine is the same hybrid
bisection** for all modes.

## Architecture

```
lib/
  smart-tuner.ps1            ← NEW: orchestrator (state machine, scope
                                planner, CCD scheduler, mode policies,
                                narrative emitter)
  smart-tuner-search.ps1     ← NEW: pure bisection engine + step
                                calculator. No side effects, easy to
                                unit-test with synthetic inputs.
  smart-tuner-history.ps1    ← NEW: persistent append-only ledger.
                                Provides known_crash_floor, known_stable_
                                ceiling, confidence queries.
  corecycler-runner.ps1      ← MODIFIED: add a single-iteration single-
                                scope probe helper that returns
                                {PASS, FAIL_P95, FAIL_WHEA, ABORT, TIMEOUT}
  co-reader-writer.ps1       ← unchanged
  telemetry-poller.ps1       ← unchanged
  safety-guard.ps1           ← unchanged (we register a smarter abort
                                callback)
server.ps1                   ← MODIFIED: new POST /api/smart-tune/start,
                                /stop, /resume, /discard; GET /state,
                                /history
web/                         ← MODIFIED: Tune Theater panel in dashboard,
                                narrative log, bisection ladder vis
```

### Critical invariants (the "stability is king" guarantees)

1. Every CO write goes through `Save-PanicRevertState` first
2. Safety Guard armed for the entire session, never disarmed mid-tune
3. Final locked value is always shifted by the mode's safety margin
   **away from** the discovered edge (toward neutral / safer)
4. History is consulted before every probe — never probe at-or-below
   a previously-crashed value on the same scope/CPU
5. Sequential cores only — no parallel probing

## The hybrid bisection algorithm

Runs **per scope** (a "scope" = a CCD-group in Phase A or a single core in
Phase B). The orchestrator runs it N times per session.

### State carried per scope

```
known_stable   — deepest value we've proven passes (null if unknown)
known_unstable — shallowest value we've proven fails (from bounds or history)
candidate      — the value about to be probed
```

Termination: `|known_stable − known_unstable| ≤ 1`, or floor/ceiling
reached, or user abort.

### Candidate selection — telemetry-modulated bisection

```
midpoint = (known_stable + known_unstable) / 2

headroom = min(
  (max_vid_limit  - recent_vid_max)  / max_vid_limit,
  (max_temp_limit - recent_temp_max) / max_temp_limit
)   # ∈ [0, 1] — small = close to limit, big = lots of margin

step = clamp(
  (known_stable - midpoint) * (0.5 + headroom),
  step_min, step_max
)
candidate = known_stable − step   # for undervolt; sign flipped for OC
```

When the CPU is sweating, the algorithm creeps. When it's cool, it strides.
This is "telemetry-feedback" merged into the bisection — caution emerges
naturally before instability.

### Per-probe checks (before launching CoreCycler)

1. **History query** — if `candidate ≤ known_crash_floor(scope)`, skip,
   advance `known_unstable` to crash value, recompute
2. **Safety guard re-arm** with current mode limits
3. **Panic-revert write** — `Save-PanicRevertState($candidate_values, …)`
4. **CO apply** via `Set-AllCoreCo` (existing path)
5. **Sleep 2 s** for SMU settle

### Probe execution

A single short CoreCycler invocation:
- `coresToTest = [this scope's cores]`
- `maxIterations = 1`
- `runtimePerCore = mode.probe_runtime` (4 min Daily / 6 min Max / 90 s Characterize)
- Telemetry guard live throughout
- Result classification:
  - **PASS** → `known_stable = candidate`
  - **FAIL_P95** → `known_unstable = candidate`
  - **FAIL_WHEA** → `known_unstable = candidate`, marked as crash-class
    in history (worse than P95 — implies near-BSOD)
  - **ABORT_SAFETY** → `known_unstable = candidate + 1` (no stability signal)
  - **TIMEOUT** → treat as FAIL_P95 + alert in UI

### After each probe

- Append to `tuner-history.json` (atomic write)
- Clear `panic-revert.json` on PASS
- Emit narrative log entries
- Update Pro Dashboard bisection ladder

### Termination & lock-in

When bounds converge: `locked = known_stable − margin` (toward safer).
Run a verification pass at `locked` (`mode.verification_iterations`); if
it fails, set `known_stable = locked` and bisect once more. If `known_stable`
remains `null` (every probe in range failed), mark scope "no stable offset
found" and leave at launch value with a Smart Suggestion explaining.

### Walked example — Daily Driver, V-Cache CCD0, fresh history

```
mode = Daily Driver  ·  V-Cache CCD  ·  floor=-25  ·  ceiling=0  ·  margin=+2
seed = 0 (no history)

Iter 1: candidate=-13 (midpoint, no history)  → PASS  →  stable=-13, unstable=-26
Iter 2: candidate=-19 (mid, headroom big)      → PASS  →  stable=-19, unstable=-26
Iter 3: candidate=-22 (mid, headroom medium)   → FAIL_P95   →  stable=-19, unstable=-22
Iter 4: candidate=-20 (mid, narrow)            → PASS  →  stable=-20, unstable=-22
Iter 5: candidate=-21                          → FAIL_WHEA  →  stable=-20, unstable=-21 (CONVERGED)

Locked = -20 + 2 = -18  (shifted toward neutral by margin)
Verification: 2 iterations at -18 → PASS → COMMIT
History saved: CCD0 stable_ceiling=-19, crash_floor=-21
5 probes (~25 min) vs CoreCycler's typical ~15 probes for similar convergence.
```

## V-Cache CCD asymmetry handling

Auto-detected from CPU model (existing `cpu-detect.ps1` already knows
`VCacheCcdIndex`). When present:

- V-Cache CCD gets its own per-CCD policy: tighter floor (e.g., -20 vs
  -30 for Standard), tighter live VID guard, smaller `step_max`
- V-Cache CCD is probed **first** — failing fast there is safer than
  failing after a long Standard CCD run
- Standard CCD seeds its bisection from V-Cache's `known_stable` as a
  starting hint (V-Cache stable usually means Standard can go deeper)
- User can override per-CCD limits in Settings

## Persistence model

Three files under `runtime/`:

| File | Purpose | Format | Survives crash? |
|---|---|---|---|
| `tuner-history.json` | Per-CPU-model, per-core append-only probe ledger | JSONL | yes |
| `tuner-session.json` | Current session plan + progress | JSON | yes |
| `panic-revert.json` | Existing pre-CO-write breadcrumb | JSON | yes |

### `tuner-history.json` schema (JSONL)

```json
{"ts":"2026-05-28T09:14:22Z","cpuModel":"AMD Ryzen 9 7950X3D","scope":"CCD0","value":-21,"result":"FAIL_WHEA","probeRuntimeS":182,"peakTemp":78,"peakVid":1.42,"wheaDelta":1,"mode":"daily-driver","sessionId":"abc123"}
{"ts":"2026-05-28T09:18:01Z","cpuModel":"AMD Ryzen 9 7950X3D","scope":"CCD0","value":-20,"result":"PASS","probeRuntimeS":240,"peakTemp":76,"peakVid":1.38,"wheaDelta":0,"mode":"daily-driver","sessionId":"abc123"}
```

Per-CPU-model partitioning means swapping CPUs doesn't poison history.
Append-only because we only need aggregates.

### History queries (pure functions)

- `known_crash_floor(scope)` — never probe at-or-below this value again
- `known_stable_ceiling(scope)` — starting hint for the next session
- `confidence(scope, value)` — `PASS_count − FAIL_count` at exact value
- `instability_signature(scope)` — WHEA-fail / total-fail ratio; high
  ratio means this core hits near-BSOD before erroring clean → add extra
  margin

### `tuner-session.json` schema (rewritten atomically after each probe)

```json
{
  "sessionId": "abc123",
  "startedAt": "2026-05-28T09:00:00Z",
  "mode": "daily-driver",
  "cpuModel": "AMD Ryzen 9 7950X3D",
  "launchSnapshot": [-10,-10,...],
  "phase": "A",
  "scopes": [
    {"id":"CCD0","status":"COMPLETED","locked":-18,"probes":5},
    {"id":"CCD1","status":"IN_PROGRESS","bounds":{"floor":-25,"ceiling":0},
     "knownStable":-19,"knownUnstable":-22,"probesCompleted":3,
     "lastProbeValue":-21,"lastProbeResult":"FAIL_P95"}
  ],
  "safetyLimits": {"maxTempC":95,"maxVid":1.45,"abortOnWhea":true},
  "narrative": [/* last N entries — older entries dropped, full log in
                  history file */]
}
```

### Crash-recovery flow

```
1. System crashes mid-probe (panic-revert.json + tuner-session.json on disk)
2. User reboots, runs Launch.bat
3. server.ps1 startup banner: "Previous run crashed mid-tune"
4. UI offers TWO actions:
     - "Revert to launch snapshot" (uses panic-revert)
     - "Resume Smart Tune (record crash as data point)"
5. If resume: interrupted probe → history as result=ABORT_CRASH (worst
   class — never probe again on this scope/CPU). known_unstable shrunk.
   Bisection picks up at new midpoint.
6. If discard: history retains crash entry, session.json cleared,
   panic-revert.json cleared, CO at launch.
```

### Storage discipline

- `tuner-history.json` capped at 10,000 entries per CPU model (~1 MB)
- Crash entries (FAIL_WHEA, ABORT_CRASH) **never pruned** — most valuable signal
- Oldest non-crash entries pruned first on overflow
- All file ops `try/catch` — corrupted history degrades to "no history",
  never blocks tuning
- Session JSON written via `write-to-temp + rename` for atomicity

## UI integration — the Tune Theater

When Smart Auto-Adjust is active, the Pro Dashboard hosts a new full-width
"Tune Theater" panel above the live charts. Goal: the user can see
everything happening in a single viewport.

### Components (all simultaneously visible)

1. **Progress header** — overall %, phase %, per-scope status pills, ETA
   computed from `remaining_scopes × avg_probes × avg_probe_duration`
2. **"Currently" strip** — what the algorithm is doing this very second,
   plus prediction: "Will conclude PASS at 4m 00s if no error"
3. **Narrative log** — running story with icons (lifecycle, history,
   safety, planning, panic, probe-start, PASS, FAIL, WHEA, bounds,
   lock-in, retry/resume), autoscroll-pinnable
4. **Bisection ladder** — per-scope vertical number line, every probed
   value marked (colour by result), animated `[stable | candidate | unstable]`
   window
5. **Existing Pro Dashboard charts** — clock / temp / VID / power /
   boost-map keep streaming below
6. **Per-core heatmap** — gets a badge for locked cores
7. **Safety banner** — existing, above

### Narrative log format

Server-side: every state change in `smart-tuner.ps1` emits a
`Write-TunerNarrative -Icon X -Message Y -Payload {…}` entry. The client
polls `/api/smart-tune/state?since=<seqId>` at 1 Hz, appends new entries.

Icons: ⚙ lifecycle · 📊 history · 🛡 safety · 🎯 planning · 📌 panic ·
➤ probe-start · ✓ PASS · ✗ FAIL · ⚠ WHEA/warn · ↓↑ bounds · 🔒 lock · ↻ retry

### Live "Currently" strip examples

- During probe: `"Probing CCD1 at CO=-22 · Prime95 SSE · 3m 12s · Will conclude PASS at 4m 00s if no error"`
- Between probes: `"Computing next candidate from telemetry headroom (5s)"`
- During CO write: `"Writing CO=-21 to SMU (2s settle)"`
- During verification: `"Final verify · iteration 1 of 2 · 5m 32s remaining"`

### Stuck detection (anti-anxiety)

- Narrative silent >30 s during probe → `"Still running probe — Prime95 takes time to error, this is normal"`
- Silent >2 min → escalates: `"Probe ran longer than expected — heartbeat OK, telemetry OK"`

### Final results card (replaces Report card on completion)

- Locked values table (per-core final CO, delta from launch, mode, margin)
- Per-scope convergence stats
- Stability confidence: `"CCD0 -18 — 8 PASS / 0 FAIL over 3 sessions, 12 days"`
- Crash entries created this session (the new permanent guard rails)
- Apply / Save as profile / Save AND apply buttons (autogen name
  `"SmartTune-Daily-2026-05-28-1843"`)
- "Compare to previous Smart Tune" diff table

## Server endpoints

```
POST /api/smart-tune/start     body: { mode, direction, overrides:{margin,bounds,...} }
POST /api/smart-tune/stop      graceful — completes current probe, no lock-in
GET  /api/smart-tune/state     full session + new narrative since lastSeqId
POST /api/smart-tune/resume    resumes from tuner-session.json
POST /api/smart-tune/discard   clears session.json + panic-revert.json
GET  /api/smart-tune/history   paginated history for current CPU model
```

`/state` returns the session JSON plus only-new narrative entries since
the client's `lastSeqId` (keeps payload tiny on long sessions). Multiple
browser tabs are supported — all see the same narrative.

## Testing strategy

- **`smart-tuner-search.ps1`** is a pure function module: given
  `(scope_state, mode_policy, telemetry_history, crash_history)` returns
  next candidate. Unit-testable with synthetic inputs — no real CPU
  needed.
- **`smart-tuner-history.ps1`** is pure I/O over JSONL. Test with
  synthetic history files; assert query results.
- **`smart-tuner.ps1` orchestrator** tested via fake probe results: a
  mock `Invoke-Probe` that returns scripted outcomes. Assert the narrative
  emitted, the locked-in value, the history entries written.
- **End-to-end** requires a real CPU; deferred to manual QA on the
  developer's 7950X3D, with Characterize mode used as the smoke test
  (short probes, no commit).

## Open questions / future work

- Cross-mode history reuse: can a Daily Driver session's "stable" entries
  inform a Max Stable session? (Probably yes, but Max Stable should still
  re-verify before trusting them.)
- AVX2/AVX-512 stress matrix in Max Stable mode (currently SSE only).
- Per-core thermal budget — V-Cache CCD cores that consistently run
  hotter than their siblings could get a per-core temp guard, not just
  per-CCD.
- "Compare two CPUs" view if the user has history for multiple CPU
  models in `tuner-history.json`.
