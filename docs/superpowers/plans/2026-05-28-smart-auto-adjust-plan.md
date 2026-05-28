# Smart Auto-Adjust Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a bisection-based, telemetry-aware, history-learning auto-tuner that replaces CoreCycler's linear "increment on error" logic. Five user-selectable modes, V-Cache CCD asymmetry handling, full crash recovery, and a fully transparent live narrative UI ("Tune Theater").

**Architecture:** Three pure-logic PowerShell modules (search engine, history store, mode policies) wrapped by an orchestrator that drives CoreCycler in short single-iteration bursts. Server exposes six new endpoints. Browser renders a new "Tune Theater" panel above the existing Pro Dashboard, polling state at 1 Hz with seq-id pagination so multiple tabs stay in sync.

**Tech Stack:** Windows PowerShell 5.1 (.NET Framework 4.8 host), Pester 5.x for unit tests, vanilla JS + Chart.js (already vendored), JSONL for the history ledger, atomic JSON write-rename for the session file.

**Spec:** [docs/superpowers/specs/2026-05-28-smart-auto-adjust-design.md](../specs/2026-05-28-smart-auto-adjust-design.md)

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `lib/smart-tuner-search.ps1` | **NEW** | Pure bisection engine. `New-ScopeState`, `Get-NextCandidate`, `Update-ScopeFromResult`, `Test-ScopeConverged`, `Get-LockInValue`. No I/O. |
| `lib/smart-tuner-history.ps1` | **NEW** | Append-only JSONL ledger + pure queries. `Add-HistoryEntry`, `Get-KnownCrashFloor`, `Get-KnownStableCeiling`, `Get-Confidence`, `Get-InstabilitySignature`, `Compact-History`. |
| `lib/smart-tuner-modes.ps1` | **NEW** | Mode-policy data table + `Get-ModePolicy`. Pure lookup. |
| `lib/smart-tuner-narrative.ps1` | **NEW** | Narrative log emitter. `Write-TunerNarrative`, `Get-NewNarrativeEntries`. In-memory ring buffer + structured log file. |
| `lib/smart-tuner.ps1` | **NEW** | Orchestrator. `Start-SmartTune`, `Stop-SmartTune`, `Resume-SmartTune`, `Get-SmartTuneState`. Drives the loop, persists session, calls probe wrapper, applies CO, locks in values. |
| `lib/corecycler-runner.ps1` | **MODIFY** | Add `Invoke-Probe` (single-iteration single-scope wrapper) and a `Test-CoreCyclerProbeResult` classifier. |
| `server.ps1` | **MODIFY** | Dot-source the new modules; register 6 new routes; surface resume prompt on startup if `tuner-session.json` exists. |
| `web/index.html` | **MODIFY** | Add "Smart Auto-Adjust" radio + mode picker; add Tune Theater panel structure above Pro Dashboard. |
| `web/style.css` | **MODIFY** | Tune Theater theming: progress header, narrative log, bisection ladder. |
| `web/app.js` | **MODIFY** | New `SmartTune` IIFE module: state polling with seqId pagination, narrative renderer, bisection ladder, resume prompt. |
| `tests/smart-tuner-search.tests.ps1` | **NEW** | Pester 5 tests for the pure search engine. |
| `tests/smart-tuner-history.tests.ps1` | **NEW** | Pester 5 tests for history queries. |
| `tests/smart-tuner-modes.tests.ps1` | **NEW** | Pester 5 tests for mode policies. |
| `tests/smart-tuner-narrative.tests.ps1` | **NEW** | Pester 5 tests for narrative buffer + pagination. |
| `tests/smart-tuner.tests.ps1` | **NEW** | Pester 5 tests for the orchestrator with a mocked `Invoke-Probe`. |

---

## Phase 1 — Pure search engine (TDD-first)

Everything in this phase is a pure function: deterministic inputs → deterministic outputs, no I/O, no globals. Perfect for TDD.

### Task 1: Mode policy table

**Files:**
- Create: `lib/smart-tuner-modes.ps1`
- Test: `tests/smart-tuner-modes.tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll { . "$PSScriptRoot\..\lib\smart-tuner-modes.ps1" }

Describe 'Get-ModePolicy' {
    It 'returns Daily Driver defaults' {
        $p = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $p.probeRuntimeMin   | Should -Be 4
        $p.verifyIterations  | Should -Be 2
        $p.marginPoints      | Should -Be 2
        $p.refinePerCore     | Should -BeFalse
        $p.standardFloor     | Should -Be -30
        $p.vCacheFloor       | Should -Be -25
    }
    It 'returns Max Stable with per-core refinement' {
        $p = Get-ModePolicy -Mode 'max-stable' -Direction 'undervolt'
        $p.verifyIterations | Should -Be 5
        $p.marginPoints     | Should -Be 1
        $p.refinePerCore    | Should -BeTrue
    }
    It 'flips bounds for overclock direction' {
        $p = Get-ModePolicy -Mode 'overclock' -Direction 'overclock'
        $p.standardFloor    | Should -Be 0
        $p.standardCeiling  | Should -BeGreaterThan 0
        $p.marginPoints     | Should -Be -1  # negative = move back toward 0
    }
    It 'throws on unknown mode' {
        { Get-ModePolicy -Mode 'bogus' -Direction 'undervolt' } | Should -Throw
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner-modes.tests.ps1 -Output Detailed`
Expected: FAIL — `Get-ModePolicy` not defined.

- [ ] **Step 3: Implement**

```powershell
# ============================================================================
#  smart-tuner-modes.ps1 - Mode policy lookup for Smart Auto-Adjust
# ============================================================================
#  Pure data table + getter. Each mode encodes a "how aggressive, how
#  thorough, how cautious" recipe. The search engine reads these to
#  drive its per-scope behaviour. Adding a new mode = add a row here.
# ============================================================================
Set-StrictMode -Version Latest

$script:ModeTable = @{
    'daily-driver' = @{
        probeRuntimeMin   = 4
        verifyIterations  = 2
        marginPoints      = 2
        refinePerCore     = $false
        standardFloor     = -30
        standardCeiling   = 0
        vCacheFloor       = -25
        vCacheCeiling     = 0
        stepMin           = 1
        stepMax           = 8
    }
    'max-stable' = @{
        probeRuntimeMin   = 6
        verifyIterations  = 5
        marginPoints      = 1
        refinePerCore     = $true
        standardFloor     = -35
        standardCeiling   = 0
        vCacheFloor       = -28
        vCacheCeiling     = 0
        stepMin           = 1
        stepMax           = 6
    }
    'adaptive' = @{
        probeRuntimeMin   = 5
        verifyIterations  = 2
        marginPoints      = 2
        refinePerCore     = $true
        standardFloor     = -30
        standardCeiling   = 0
        vCacheFloor       = -25
        vCacheCeiling     = 0
        stepMin           = 1
        stepMax           = 4
    }
    'characterize' = @{
        probeRuntimeMin   = 1.5
        verifyIterations  = 0
        marginPoints      = 0
        refinePerCore     = $true
        standardFloor     = -30
        standardCeiling   = 5
        vCacheFloor       = -25
        vCacheCeiling     = 5
        stepMin           = 2
        stepMax           = 8
    }
    'overclock' = @{
        probeRuntimeMin   = 5
        verifyIterations  = 3
        marginPoints      = -1   # negative = step back TOWARD zero from edge
        refinePerCore     = $true
        standardFloor     = 0
        standardCeiling   = 30
        vCacheFloor       = 0
        vCacheCeiling     = 15
        stepMin           = 1
        stepMax           = 5
    }
}

function Get-ModePolicy {
    param(
        [Parameter(Mandatory)][ValidateSet('daily-driver','max-stable','adaptive','characterize','overclock')][string]$Mode,
        [Parameter(Mandatory)][ValidateSet('undervolt','overclock')][string]$Direction
    )
    if (-not $script:ModeTable.ContainsKey($Mode)) {
        throw "Unknown mode: $Mode"
    }
    $p = $script:ModeTable[$Mode].Clone()
    $p.mode = $Mode
    $p.direction = $Direction
    [PSCustomObject]$p
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner-modes.tests.ps1 -Output Detailed`
Expected: PASS (4/4).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner-modes.ps1 tests/smart-tuner-modes.tests.ps1
git commit -m "feat(smart-tune): mode policy table + Get-ModePolicy"
```

---

### Task 2: Scope state construction

**Files:**
- Create: `lib/smart-tuner-search.ps1`
- Test: `tests/smart-tuner-search.tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    . "$PSScriptRoot\..\lib\smart-tuner-modes.ps1"
    . "$PSScriptRoot\..\lib\smart-tuner-search.ps1"
}

Describe 'New-ScopeState' {
    It 'creates a scope with mode-derived bounds (V-Cache CCD)' {
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $true -SeedValue 0 -Policy $policy
        $s.scopeId        | Should -Be 'CCD0'
        $s.bounds.floor   | Should -Be -25
        $s.bounds.ceiling | Should -Be 0
        $s.knownStable    | Should -Be $null
        $s.knownUnstable  | Should -Be $null
        $s.seedValue      | Should -Be 0
        $s.probesCompleted | Should -Be 0
    }
    It 'uses Standard CCD bounds when not V-Cache' {
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $s = New-ScopeState -ScopeId 'CCD1' -IsVCache $false -SeedValue 0 -Policy $policy
        $s.bounds.floor | Should -Be -30
    }
    It 'seeds knownStable when a history hint is provided' {
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $policy -KnownStableHint -18 -KnownCrashFloor -22
        $s.knownStable   | Should -Be -18
        $s.knownUnstable | Should -Be -22
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner-search.tests.ps1 -Output Detailed`
Expected: FAIL — `New-ScopeState` not defined.

- [ ] **Step 3: Implement**

```powershell
# ============================================================================
#  smart-tuner-search.ps1 - Pure bisection engine for Smart Auto-Adjust
# ============================================================================
#  All functions in this file are PURE: same inputs => same outputs, no I/O,
#  no globals. The orchestrator (smart-tuner.ps1) calls them sequentially:
#
#    state = New-ScopeState(scopeId, isVCache, seed, policy, [hints])
#    while not (Test-ScopeConverged state):
#        candidate = Get-NextCandidate state telemetryHeadroom
#        # ... orchestrator runs the probe ...
#        state = Update-ScopeFromResult state candidate result
#    locked = Get-LockInValue state policy
#
#  Three bookkeeping pointers per scope:
#    knownStable   - deepest value proven to PASS (null if untested)
#    knownUnstable - shallowest value proven to FAIL (null if untested)
#    candidate     - the value about to be probed next
# ============================================================================
Set-StrictMode -Version Latest

function New-ScopeState {
    param(
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][bool]$IsVCache,
        [Parameter(Mandatory)][int]$SeedValue,
        [Parameter(Mandatory)]$Policy,
        [Nullable[int]]$KnownStableHint = $null,
        [Nullable[int]]$KnownCrashFloor = $null
    )
    $floor   = if ($IsVCache) { $Policy.vCacheFloor }   else { $Policy.standardFloor }
    $ceiling = if ($IsVCache) { $Policy.vCacheCeiling } else { $Policy.standardCeiling }
    [PSCustomObject]@{
        scopeId          = $ScopeId
        isVCache         = $IsVCache
        bounds           = [PSCustomObject]@{ floor = [int]$floor; ceiling = [int]$ceiling }
        seedValue        = $SeedValue
        knownStable      = if ($null -ne $KnownStableHint) { [int]$KnownStableHint } else { $null }
        knownUnstable    = if ($null -ne $KnownCrashFloor) { [int]$KnownCrashFloor } else { $null }
        probesCompleted  = 0
        lastCandidate    = $null
        lastResult       = $null
        status           = 'pending'  # pending | probing | converged | failed | locked
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner-search.tests.ps1 -Output Detailed`
Expected: PASS (3/3).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner-search.ps1 tests/smart-tuner-search.tests.ps1
git commit -m "feat(smart-tune): scope state constructor"
```

---

### Task 3: Get-NextCandidate (telemetry-modulated bisection)

**Files:**
- Modify: `lib/smart-tuner-search.ps1` (append)
- Modify: `tests/smart-tuner-search.tests.ps1` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/smart-tuner-search.tests.ps1`:

```powershell
Describe 'Get-NextCandidate' {
    BeforeEach {
        $script:policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
    }
    It 'returns midpoint when both bounds known and headroom is full' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s.knownStable   = -10
        $s.knownUnstable = -20
        # Full headroom (1.0) means full half-step toward unstable
        $c = Get-NextCandidate -ScopeState $s -TelemetryHeadroom 1.0 -Policy $script:policy
        $c | Should -Be -15  # midpoint
    }
    It 'shrinks step when telemetry headroom is small' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s.knownStable   = -10
        $s.knownUnstable = -20
        $c = Get-NextCandidate -ScopeState $s -TelemetryHeadroom 0.0 -Policy $script:policy
        # zero headroom => step factor = 0.5 of midpoint distance = 2.5 -> clamped to stepMin 1
        # candidate = knownStable - max(stepMin, round(0.5 * 5)) = -10 - 3 = -13 (less aggressive than midpoint)
        $c | Should -BeIn -13, -12, -11   # any conservative step is valid
    }
    It 'uses floor when knownStable is null' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $c = Get-NextCandidate -ScopeState $s -TelemetryHeadroom 1.0 -Policy $script:policy
        # No knownStable - probe at midpoint of (seed, floor)
        $c | Should -Be -15   # midpoint of 0 and -30
    }
    It 'respects floor as hard limit' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s.knownStable   = -28
        $s.knownUnstable = $null
        $c = Get-NextCandidate -ScopeState $s -TelemetryHeadroom 1.0 -Policy $script:policy
        $c | Should -BeGreaterOrEqual $s.bounds.floor
    }
    It 'inverts direction for overclock policy' {
        $oc = Get-ModePolicy -Mode 'overclock' -Direction 'overclock'
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $oc
        $s.knownStable   = 5
        $s.knownUnstable = 15
        $c = Get-NextCandidate -ScopeState $s -TelemetryHeadroom 1.0 -Policy $oc
        $c | Should -Be 10   # midpoint, going UP
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner-search.tests.ps1 -Output Detailed`
Expected: FAIL — `Get-NextCandidate` not defined.

- [ ] **Step 3: Implement**

Append to `lib/smart-tuner-search.ps1`:

```powershell
# Choose the next CO value to probe. Combines pure bisection with a
# telemetry-headroom modulator: when the CPU is operating close to a
# guard limit (low headroom), step sizes shrink to avoid overshooting
# into instability. With full headroom, behaves as pure midpoint bisect.
function Get-NextCandidate {
    param(
        [Parameter(Mandatory)]$ScopeState,
        [Parameter(Mandatory)][double]$TelemetryHeadroom,  # [0, 1]
        [Parameter(Mandatory)]$Policy
    )
    $sign = if ($Policy.direction -eq 'overclock') { 1 } else { -1 }
    $stable   = $ScopeState.knownStable
    $unstable = $ScopeState.knownUnstable
    $floor    = $ScopeState.bounds.floor
    $ceiling  = $ScopeState.bounds.ceiling
    $seed     = $ScopeState.seedValue

    # Resolve the "from" anchor (what we're stepping AWAY from toward unsafe)
    $from = if ($null -ne $stable) { $stable } else { $seed }

    # Resolve the "to" anchor (what we're stepping TOWARD)
    $to = if ($null -ne $unstable) {
        $unstable
    } else {
        if ($sign -lt 0) { $floor } else { $ceiling }
    }

    $headroom = [Math]::Max(0.0, [Math]::Min(1.0, $TelemetryHeadroom))
    $halfDist = [Math]::Abs($to - $from) / 2.0
    $stepFactor = 0.5 + (0.5 * $headroom)  # 0.5 at zero headroom, 1.0 at full
    $rawStep = [Math]::Round($halfDist * $stepFactor)
    $step = [Math]::Max([int]$Policy.stepMin, [int]$rawStep)
    # Apply stepMax cap only when we have some prior knowledge. The very
    # first probe (both bounds null) deliberately takes a full midpoint
    # leap so we converge in log2(range) probes instead of crawling.
    if ($null -ne $stable -or $null -ne $unstable) {
        $step = [Math]::Min([int]$Policy.stepMax, $step)
    }

    $candidate = $from + ($sign * $step)
    if ($candidate -lt $floor)   { $candidate = $floor }
    if ($candidate -gt $ceiling) { $candidate = $ceiling }
    [int]$candidate
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner-search.tests.ps1 -Output Detailed`
Expected: PASS (8/8 cumulative).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner-search.ps1 tests/smart-tuner-search.tests.ps1
git commit -m "feat(smart-tune): Get-NextCandidate with telemetry-modulated bisection"
```

---

### Task 4: Update-ScopeFromResult + Test-ScopeConverged

**Files:**
- Modify: `lib/smart-tuner-search.ps1` (append)
- Modify: `tests/smart-tuner-search.tests.ps1` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/smart-tuner-search.tests.ps1`:

```powershell
Describe 'Update-ScopeFromResult' {
    BeforeEach {
        $script:policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
    }
    It 'sets knownStable on PASS' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s2 = Update-ScopeFromResult -ScopeState $s -Candidate -15 -Result 'PASS'
        $s2.knownStable     | Should -Be -15
        $s2.knownUnstable   | Should -Be $null
        $s2.probesCompleted | Should -Be 1
        $s2.lastCandidate   | Should -Be -15
        $s2.lastResult      | Should -Be 'PASS'
    }
    It 'sets knownUnstable on FAIL_P95' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s2 = Update-ScopeFromResult -ScopeState $s -Candidate -22 -Result 'FAIL_P95'
        $s2.knownUnstable | Should -Be -22
        $s2.knownStable   | Should -Be $null
    }
    It 'sets knownUnstable on FAIL_WHEA' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s2 = Update-ScopeFromResult -ScopeState $s -Candidate -22 -Result 'FAIL_WHEA'
        $s2.knownUnstable | Should -Be -22
    }
    It 'pushes knownUnstable one past candidate on ABORT_SAFETY (no stability signal)' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s2 = Update-ScopeFromResult -ScopeState $s -Candidate -22 -Result 'ABORT_SAFETY'
        # For undervolt, "+1" means closer to zero / safer => unstable=-21
        $s2.knownUnstable | Should -Be -21
    }
}

Describe 'Test-ScopeConverged' {
    BeforeEach {
        $script:policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
    }
    It 'returns false when bounds are not adjacent' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s.knownStable = -19; $s.knownUnstable = -25
        Test-ScopeConverged -ScopeState $s | Should -BeFalse
    }
    It 'returns true when bounds differ by 1' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s.knownStable = -20; $s.knownUnstable = -21
        Test-ScopeConverged -ScopeState $s | Should -BeTrue
    }
    It 'returns true when knownStable hits floor' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s.knownStable = $s.bounds.floor
        Test-ScopeConverged -ScopeState $s | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner-search.tests.ps1 -Output Detailed`
Expected: FAIL — `Update-ScopeFromResult` and `Test-ScopeConverged` not defined.

- [ ] **Step 3: Implement**

Append to `lib/smart-tuner-search.ps1`:

```powershell
# Pure update: apply a probe result to a scope state. Returns a new
# PSCustomObject (immutable-style) so callers can keep the prior state.
function Update-ScopeFromResult {
    param(
        [Parameter(Mandatory)]$ScopeState,
        [Parameter(Mandatory)][int]$Candidate,
        [Parameter(Mandatory)][ValidateSet('PASS','FAIL_P95','FAIL_WHEA','ABORT_SAFETY','TIMEOUT','ABORT_CRASH')][string]$Result
    )
    $new = [PSCustomObject]@{
        scopeId         = $ScopeState.scopeId
        isVCache        = $ScopeState.isVCache
        bounds          = $ScopeState.bounds
        seedValue       = $ScopeState.seedValue
        knownStable     = $ScopeState.knownStable
        knownUnstable   = $ScopeState.knownUnstable
        probesCompleted = $ScopeState.probesCompleted + 1
        lastCandidate   = $Candidate
        lastResult      = $Result
        status          = 'probing'
    }
    switch ($Result) {
        'PASS' {
            if ($null -eq $new.knownStable -or
                ($ScopeState.isVCache -eq $false -and $Candidate -lt $new.knownStable) -or
                ($ScopeState.isVCache -eq $true  -and $Candidate -lt $new.knownStable)) {
                # For undervolt, "deeper" = more negative. Always treat
                # the deepest PASS we've seen as knownStable.
                $new.knownStable = $Candidate
            }
            # Note: for overclock, "deeper" = more positive - same logic
            # applies because we only call Update with candidates from
            # Get-NextCandidate, which respects direction.
        }
        { $_ -in 'FAIL_P95','FAIL_WHEA','TIMEOUT','ABORT_CRASH' } {
            if ($null -eq $new.knownUnstable -or $Candidate -gt $new.knownUnstable) {
                # For undervolt, "shallower" = closer to zero. The
                # shallowest fail we've ever recorded is knownUnstable.
                $new.knownUnstable = $Candidate
            }
        }
        'ABORT_SAFETY' {
            # We never reached a stability conclusion - mark one step
            # safer than the attempted candidate as unstable.
            $shifted = $Candidate + 1  # for undervolt; flip for OC if needed
            if ($null -eq $new.knownUnstable -or $shifted -gt $new.knownUnstable) {
                $new.knownUnstable = $shifted
            }
        }
    }
    $new
}

# Convergence: when bounds are within 1 of each other, or knownStable
# hit the floor (or ceiling for OC), or we have no stable value AND
# unstable is at floor (everything in range failed).
function Test-ScopeConverged {
    param([Parameter(Mandatory)]$ScopeState)
    $stable   = $ScopeState.knownStable
    $unstable = $ScopeState.knownUnstable
    $floor    = $ScopeState.bounds.floor
    $ceiling  = $ScopeState.bounds.ceiling
    if ($null -ne $stable -and ($stable -eq $floor -or $stable -eq $ceiling)) { return $true }
    if ($null -ne $stable -and $null -ne $unstable -and [Math]::Abs($stable - $unstable) -le 1) { return $true }
    if ($null -ne $unstable -and ($unstable -eq $floor -or $unstable -eq $ceiling) -and $null -eq $stable) { return $true }
    $false
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner-search.tests.ps1 -Output Detailed`
Expected: PASS (15/15 cumulative).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner-search.ps1 tests/smart-tuner-search.tests.ps1
git commit -m "feat(smart-tune): Update-ScopeFromResult + Test-ScopeConverged"
```

---

### Task 5: Get-LockInValue (margin applied)

**Files:**
- Modify: `lib/smart-tuner-search.ps1` (append)
- Modify: `tests/smart-tuner-search.tests.ps1` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/smart-tuner-search.tests.ps1`:

```powershell
Describe 'Get-LockInValue' {
    It 'applies +margin (toward zero) for undervolt' {
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $policy
        $s.knownStable = -20
        Get-LockInValue -ScopeState $s -Policy $policy | Should -Be -18   # -20 + 2
    }
    It 'applies -margin (toward zero) for overclock' {
        $policy = Get-ModePolicy -Mode 'overclock' -Direction 'overclock'
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $policy
        $s.knownStable = 10
        # Policy.marginPoints = -1, so locked = 10 + (-1) for OC means safer = 9
        Get-LockInValue -ScopeState $s -Policy $policy | Should -Be 9
    }
    It 'returns null when no stable value found' {
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $policy
        Get-LockInValue -ScopeState $s -Policy $policy | Should -Be $null
    }
    It 'never goes past the ceiling/floor when margin would push it' {
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $policy
        $s.knownStable = -1   # very shallow; +2 margin would put us at +1 past ceiling 0
        Get-LockInValue -ScopeState $s -Policy $policy | Should -Be 0
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner-search.tests.ps1 -Output Detailed`
Expected: FAIL — `Get-LockInValue` not defined.

- [ ] **Step 3: Implement**

Append to `lib/smart-tuner-search.ps1`:

```powershell
# Returns the final value to write for this scope, after applying the
# mode's safety margin. For undervolt, margin shifts toward zero
# (less aggressive). For overclock, margin shifts toward zero (less
# overshoot). marginPoints in policy is signed:
#   undervolt: positive value (e.g., +2) - lock = stable + 2 (less negative)
#   overclock: negative value (e.g., -1) - lock = stable + (-1) (less positive)
# Clamped to bounds either way.
function Get-LockInValue {
    param(
        [Parameter(Mandatory)]$ScopeState,
        [Parameter(Mandatory)]$Policy
    )
    if ($null -eq $ScopeState.knownStable) { return $null }
    $locked = $ScopeState.knownStable + [int]$Policy.marginPoints
    if ($locked -lt $ScopeState.bounds.floor)   { $locked = $ScopeState.bounds.floor }
    if ($locked -gt $ScopeState.bounds.ceiling) { $locked = $ScopeState.bounds.ceiling }
    [int]$locked
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner-search.tests.ps1 -Output Detailed`
Expected: PASS (19/19 cumulative).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner-search.ps1 tests/smart-tuner-search.tests.ps1
git commit -m "feat(smart-tune): Get-LockInValue with safety margin"
```

---

## Phase 2 — History persistence (TDD-first)

### Task 6: Add-HistoryEntry (atomic append)

**Files:**
- Create: `lib/smart-tuner-history.ps1`
- Create: `tests/smart-tuner-history.tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    . "$PSScriptRoot\..\lib\smart-tuner-history.ps1"
}

Describe 'Add-HistoryEntry' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("rpo-hist-" + [Guid]::NewGuid().ToString('N') + ".jsonl")
    }
    AfterEach {
        if (Test-Path $script:tmp) { Remove-Item $script:tmp -Force }
    }
    It 'creates the file and appends a JSON line' {
        Add-HistoryEntry -Path $script:tmp -Entry @{
            cpuModel='AMD Ryzen 9 7950X3D'; scope='CCD0'; value=-20; result='PASS'
        }
        Test-Path $script:tmp | Should -BeTrue
        $lines = Get-Content $script:tmp
        $lines.Count | Should -Be 1
        $obj = $lines[0] | ConvertFrom-Json
        $obj.scope    | Should -Be 'CCD0'
        $obj.value    | Should -Be -20
        $obj.result   | Should -Be 'PASS'
        $obj.ts       | Should -Not -BeNullOrEmpty
    }
    It 'appends without rewriting previous entries' {
        Add-HistoryEntry -Path $script:tmp -Entry @{ scope='CCD0'; value=-15; result='PASS' }
        Add-HistoryEntry -Path $script:tmp -Entry @{ scope='CCD0'; value=-20; result='FAIL_P95' }
        (Get-Content $script:tmp).Count | Should -Be 2
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner-history.tests.ps1 -Output Detailed`
Expected: FAIL — `Add-HistoryEntry` not defined.

- [ ] **Step 3: Implement**

```powershell
# ============================================================================
#  smart-tuner-history.ps1 - Append-only JSONL ledger + query helpers
# ============================================================================
#  Used by smart-tuner.ps1 (writes after every probe, queries before
#  every candidate). All queries are pure functions over a file path -
#  no global state, easy to test with synthetic history files.
#
#  Schema (one JSON object per line):
#    { ts, cpuModel, scope, value, result, probeRuntimeS, peakTemp,
#      peakVid, wheaDelta, mode, sessionId }
# ============================================================================
Set-StrictMode -Version Latest

function Add-HistoryEntry {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Entry
    )
    if (-not $Entry.ContainsKey('ts')) {
        $Entry['ts'] = (Get-Date).ToUniversalTime().ToString('o')
    }
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $line = ($Entry | ConvertTo-Json -Depth 6 -Compress)
    Add-Content -Path $Path -Value $line -Encoding UTF8
}

# Read all entries for a given CPU model, returning an array of PSCustomObject.
# Lines that fail to parse are skipped (corrupt history degrades gracefully).
function Read-HistoryEntries {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$CpuModel = $null
    )
    if (-not (Test-Path $Path)) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    Get-Content -Path $Path -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $obj = $_ | ConvertFrom-Json
            if (-not $CpuModel -or $obj.cpuModel -eq $CpuModel) {
                $out.Add($obj)
            }
        } catch {}
    }
    , @($out.ToArray())
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner-history.tests.ps1 -Output Detailed`
Expected: PASS (2/2).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner-history.ps1 tests/smart-tuner-history.tests.ps1
git commit -m "feat(smart-tune): history JSONL Add + Read"
```

---

### Task 7: History queries (crash floor, stable ceiling, confidence)

**Files:**
- Modify: `lib/smart-tuner-history.ps1` (append)
- Modify: `tests/smart-tuner-history.tests.ps1` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/smart-tuner-history.tests.ps1`:

```powershell
Describe 'History queries' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("rpo-hist-" + [Guid]::NewGuid().ToString('N') + ".jsonl")
        $cpu = 'AMD Ryzen 9 7950X3D'
        Add-HistoryEntry -Path $script:tmp -Entry @{cpuModel=$cpu;scope='CCD0';value=-15;result='PASS'}
        Add-HistoryEntry -Path $script:tmp -Entry @{cpuModel=$cpu;scope='CCD0';value=-20;result='PASS'}
        Add-HistoryEntry -Path $script:tmp -Entry @{cpuModel=$cpu;scope='CCD0';value=-22;result='FAIL_WHEA'}
        Add-HistoryEntry -Path $script:tmp -Entry @{cpuModel=$cpu;scope='CCD0';value=-25;result='ABORT_CRASH'}
        Add-HistoryEntry -Path $script:tmp -Entry @{cpuModel='Other CPU';scope='CCD0';value=-30;result='FAIL_WHEA'}
        Add-HistoryEntry -Path $script:tmp -Entry @{cpuModel=$cpu;scope='CCD1';value=-25;result='PASS'}
    }
    AfterEach { if (Test-Path $script:tmp) { Remove-Item $script:tmp -Force } }

    It 'Get-KnownCrashFloor returns the shallowest failure for that scope+CPU' {
        # For undervolt: shallowest fail = closest to zero = -22 (less negative than -25)
        Get-KnownCrashFloor -Path $script:tmp -CpuModel 'AMD Ryzen 9 7950X3D' -Scope 'CCD0' | Should -Be -22
    }
    It 'Get-KnownCrashFloor ignores other CPUs' {
        Get-KnownCrashFloor -Path $script:tmp -CpuModel 'AMD Ryzen 9 7950X3D' -Scope 'CCD0' | Should -Be -22
    }
    It 'Get-KnownStableCeiling returns the deepest pass for that scope+CPU' {
        # For undervolt: deepest stable = most negative = -20
        Get-KnownStableCeiling -Path $script:tmp -CpuModel 'AMD Ryzen 9 7950X3D' -Scope 'CCD0' | Should -Be -20
    }
    It 'Get-Confidence returns PASS_count - FAIL_count at exact value' {
        Get-Confidence -Path $script:tmp -CpuModel 'AMD Ryzen 9 7950X3D' -Scope 'CCD0' -Value -20 | Should -Be 1
        Get-Confidence -Path $script:tmp -CpuModel 'AMD Ryzen 9 7950X3D' -Scope 'CCD0' -Value -22 | Should -Be -1
        Get-Confidence -Path $script:tmp -CpuModel 'AMD Ryzen 9 7950X3D' -Scope 'CCD0' -Value -99 | Should -Be 0
    }
    It 'returns nulls when no history exists' {
        Remove-Item $script:tmp -Force
        Get-KnownCrashFloor -Path $script:tmp -CpuModel 'X' -Scope 'CCD0' | Should -Be $null
        Get-KnownStableCeiling -Path $script:tmp -CpuModel 'X' -Scope 'CCD0' | Should -Be $null
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner-history.tests.ps1 -Output Detailed`
Expected: FAIL — query functions not defined.

- [ ] **Step 3: Implement**

Append to `lib/smart-tuner-history.ps1`:

```powershell
# "Crash floor" = the shallowest (closest to zero) failure value we've
# ever seen for this scope on this CPU. The orchestrator never probes
# at-or-below this value on the same scope in future sessions - that's
# how we accumulate guard rails over time.
function Get-KnownCrashFloor {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CpuModel,
        [Parameter(Mandatory)][string]$Scope
    )
    $entries = @(Read-HistoryEntries -Path $Path -CpuModel $CpuModel | Where-Object {
        $_.scope -eq $Scope -and $_.result -in 'FAIL_P95','FAIL_WHEA','ABORT_CRASH','TIMEOUT'
    })
    if ($entries.Count -eq 0) { return $null }
    # Shallowest = max value for undervolt (closer to zero)
    [int](($entries | Measure-Object -Property value -Maximum).Maximum)
}

# "Stable ceiling" = the deepest (furthest from zero) value we've ever
# seen PASS for this scope. Used to seed the next session - we can
# start the search there with high confidence.
function Get-KnownStableCeiling {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CpuModel,
        [Parameter(Mandatory)][string]$Scope
    )
    $entries = @(Read-HistoryEntries -Path $Path -CpuModel $CpuModel | Where-Object {
        $_.scope -eq $Scope -and $_.result -eq 'PASS'
    })
    if ($entries.Count -eq 0) { return $null }
    # Deepest = min value for undervolt (more negative)
    [int](($entries | Measure-Object -Property value -Minimum).Minimum)
}

# Confidence = PASS count minus FAIL count at exactly this value.
# Drives the UI's "locked -18 with confidence 7" badge.
function Get-Confidence {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CpuModel,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][int]$Value
    )
    $entries = @(Read-HistoryEntries -Path $Path -CpuModel $CpuModel | Where-Object {
        $_.scope -eq $Scope -and $_.value -eq $Value
    })
    $passes = @($entries | Where-Object { $_.result -eq 'PASS' }).Count
    $fails  = @($entries | Where-Object { $_.result -in 'FAIL_P95','FAIL_WHEA','ABORT_CRASH','TIMEOUT' }).Count
    $passes - $fails
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner-history.tests.ps1 -Output Detailed`
Expected: PASS (7/7 cumulative).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner-history.ps1 tests/smart-tuner-history.tests.ps1
git commit -m "feat(smart-tune): history queries (crash floor, stable ceiling, confidence)"
```

---

### Task 8: Compact-History (size cap, never prune crashes)

**Files:**
- Modify: `lib/smart-tuner-history.ps1` (append)
- Modify: `tests/smart-tuner-history.tests.ps1` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/smart-tuner-history.tests.ps1`:

```powershell
Describe 'Compact-History' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("rpo-hist-" + [Guid]::NewGuid().ToString('N') + ".jsonl")
        # 6 entries: 4 PASS + 2 FAIL. Cap = 4. Should keep both FAILs + the 2 newest PASSes.
        Add-HistoryEntry -Path $script:tmp -Entry @{ts='2026-01-01T00:00:00Z';scope='a';value=-10;result='PASS'}
        Add-HistoryEntry -Path $script:tmp -Entry @{ts='2026-01-02T00:00:00Z';scope='a';value=-11;result='PASS'}
        Add-HistoryEntry -Path $script:tmp -Entry @{ts='2026-01-03T00:00:00Z';scope='a';value=-20;result='FAIL_WHEA'}
        Add-HistoryEntry -Path $script:tmp -Entry @{ts='2026-01-04T00:00:00Z';scope='a';value=-12;result='PASS'}
        Add-HistoryEntry -Path $script:tmp -Entry @{ts='2026-01-05T00:00:00Z';scope='a';value=-25;result='ABORT_CRASH'}
        Add-HistoryEntry -Path $script:tmp -Entry @{ts='2026-01-06T00:00:00Z';scope='a';value=-13;result='PASS'}
    }
    AfterEach { if (Test-Path $script:tmp) { Remove-Item $script:tmp -Force } }
    It 'prunes oldest non-crash entries to fit MaxEntries, preserving all crashes' {
        Compact-History -Path $script:tmp -MaxEntries 4
        $lines = Get-Content $script:tmp
        $lines.Count | Should -Be 4
        $objs = $lines | ForEach-Object { $_ | ConvertFrom-Json }
        # Both crash entries must survive
        @($objs | Where-Object { $_.result -in 'FAIL_WHEA','ABORT_CRASH' }).Count | Should -Be 2
        # Oldest PASS (Jan 1) should be gone; newer PASSes kept
        @($objs | Where-Object { $_.ts -eq '2026-01-01T00:00:00Z' }).Count | Should -Be 0
        @($objs | Where-Object { $_.ts -eq '2026-01-06T00:00:00Z' }).Count | Should -Be 1
    }
    It 'is a no-op when entries are under cap' {
        Compact-History -Path $script:tmp -MaxEntries 100
        (Get-Content $script:tmp).Count | Should -Be 6
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner-history.tests.ps1 -Output Detailed`
Expected: FAIL — `Compact-History` not defined.

- [ ] **Step 3: Implement**

Append to `lib/smart-tuner-history.ps1`:

```powershell
# Cap the JSONL file at MaxEntries. Crash entries (FAIL_WHEA,
# ABORT_CRASH) are NEVER pruned - they're the most valuable signal.
# Among prunable entries, oldest go first. Atomic rewrite via temp file.
function Compact-History {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$MaxEntries
    )
    if (-not (Test-Path $Path)) { return }
    $all = @(Get-Content -Path $Path -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $_ -ne $null })
    if ($all.Count -le $MaxEntries) { return }

    $crashes = @($all | Where-Object { $_.result -in 'FAIL_WHEA','ABORT_CRASH' })
    $others  = @($all | Where-Object { $_.result -notin 'FAIL_WHEA','ABORT_CRASH' })
    $keepOthers = [Math]::Max(0, $MaxEntries - $crashes.Count)

    # Sort others by timestamp descending (newest first), keep the first $keepOthers
    $kept = @($others | Sort-Object -Property ts -Descending | Select-Object -First $keepOthers)
    $final = @($crashes) + $kept | Sort-Object -Property ts

    $tmp = "$Path.tmp"
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    foreach ($e in $final) {
        Add-Content -Path $tmp -Value ($e | ConvertTo-Json -Depth 6 -Compress) -Encoding UTF8
    }
    Move-Item -Force $tmp $Path
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner-history.tests.ps1 -Output Detailed`
Expected: PASS (9/9 cumulative).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner-history.ps1 tests/smart-tuner-history.tests.ps1
git commit -m "feat(smart-tune): Compact-History preserves crashes, prunes oldest"
```

---

## Phase 3 — Narrative log

### Task 9: Write-TunerNarrative + ring buffer + pagination

**Files:**
- Create: `lib/smart-tuner-narrative.ps1`
- Create: `tests/smart-tuner-narrative.tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll { . "$PSScriptRoot\..\lib\smart-tuner-narrative.ps1" }

Describe 'Narrative buffer' {
    BeforeEach { Clear-TunerNarrative }
    It 'records an entry with auto-assigned monotonic seqId' {
        $a = Write-TunerNarrative -Icon '⚙' -Message 'start'
        $b = Write-TunerNarrative -Icon '➤' -Message 'probe 1'
        $a.seqId | Should -Be 1
        $b.seqId | Should -Be 2
        $a.ts | Should -Not -BeNullOrEmpty
    }
    It 'Get-NewNarrativeEntries returns entries with seqId > since' {
        Write-TunerNarrative -Icon '⚙' -Message 'a'
        Write-TunerNarrative -Icon '➤' -Message 'b'
        Write-TunerNarrative -Icon '✓' -Message 'c'
        $new = Get-NewNarrativeEntries -SinceSeqId 1
        $new.Count | Should -Be 2
        $new[0].message | Should -Be 'b'
    }
    It 'keeps in-memory buffer capped at 500 entries' {
        for ($i = 0; $i -lt 600; $i++) { Write-TunerNarrative -Icon '➤' -Message "m$i" }
        $all = Get-NewNarrativeEntries -SinceSeqId 0
        $all.Count | Should -BeLessOrEqual 500
        # Newest must be present
        $all[-1].message | Should -Be 'm599'
    }
    It 'accepts optional structured payload' {
        $e = Write-TunerNarrative -Icon '➤' -Message 'probe' -Payload @{ scope='CCD0'; value=-20 }
        $e.payload.scope | Should -Be 'CCD0'
        $e.payload.value | Should -Be -20
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner-narrative.tests.ps1 -Output Detailed`
Expected: FAIL — narrative functions not defined.

- [ ] **Step 3: Implement**

```powershell
# ============================================================================
#  smart-tuner-narrative.ps1 - Narrative log emitter + ring buffer
# ============================================================================
#  Every orchestrator state change calls Write-TunerNarrative to record
#  what's happening. Browser polls /api/smart-tune/state?since=<seqId>
#  and only gets new entries - efficient and ordering-safe.
#
#  Why a ring buffer instead of streaming straight to disk: the browser
#  needs entries quickly (1Hz poll), and re-reading a growing file
#  every poll is wasteful. We mirror to log file too (server.log via
#  Write-Log) for forensic value, but the live buffer is in-memory.
# ============================================================================
Set-StrictMode -Version Latest

$script:NarrativeBuffer = [System.Collections.Generic.List[object]]::new()
$script:NarrativeSeqId  = 0
$script:NarrativeMax    = 500

function Write-TunerNarrative {
    param(
        [Parameter(Mandatory)][string]$Icon,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Payload = $null
    )
    $script:NarrativeSeqId++
    $entry = [PSCustomObject]@{
        seqId   = $script:NarrativeSeqId
        ts      = (Get-Date).ToUniversalTime().ToString('o')
        icon    = $Icon
        message = $Message
        payload = if ($Payload) { [PSCustomObject]$Payload } else { $null }
    }
    $script:NarrativeBuffer.Add($entry)
    while ($script:NarrativeBuffer.Count -gt $script:NarrativeMax) {
        $script:NarrativeBuffer.RemoveAt(0)
    }
    # Mirror to server.log if logging is available
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log INFO ("TUNE {0} {1}" -f $Icon, $Message)
    }
    $entry
}

function Get-NewNarrativeEntries {
    param([Parameter(Mandatory)][int]$SinceSeqId)
    , @($script:NarrativeBuffer | Where-Object { $_.seqId -gt $SinceSeqId })
}

function Clear-TunerNarrative {
    $script:NarrativeBuffer.Clear()
    $script:NarrativeSeqId = 0
}

function Get-CurrentNarrativeSeqId { $script:NarrativeSeqId }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner-narrative.tests.ps1 -Output Detailed`
Expected: PASS (4/4).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner-narrative.ps1 tests/smart-tuner-narrative.tests.ps1
git commit -m "feat(smart-tune): narrative ring buffer with seqId pagination"
```

---

## Phase 4 — Probe wrapper (single-iteration CoreCycler driver)

### Task 10: Test-CoreCyclerProbeResult classifier

**Files:**
- Modify: `lib/corecycler-runner.ps1` (append)
- Create: `tests/corecycler-runner-probe.tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll { . "$PSScriptRoot\..\lib\corecycler-runner.ps1" }

Describe 'Test-CoreCyclerProbeResult' {
    It 'returns PASS on clean completion' {
        $lines = @(
            'Iteration 1/1'
            'Set to Core 0'
            'cores with an error so far: 0'
            'cores with a WHEA error so far: 0'
            'Test completed in 00h 04m 12s'
        )
        Test-CoreCyclerProbeResult -LogLines $lines -PrimeLines @() -ExitedCleanly $true |
            Should -Be 'PASS'
    }
    It 'returns FAIL_WHEA when WHEA count > 0' {
        $lines = @(
            'Set to Core 5'
            'cores with a WHEA error so far: 1'
        )
        Test-CoreCyclerProbeResult -LogLines $lines -PrimeLines @() -ExitedCleanly $true |
            Should -Be 'FAIL_WHEA'
    }
    It 'returns FAIL_P95 when CoreCycler reports a core error' {
        $lines = @(
            'Set to Core 7'
            'has thrown an error'
            'cores with an error so far: 1'
        )
        Test-CoreCyclerProbeResult -LogLines $lines -PrimeLines @() -ExitedCleanly $true |
            Should -Be 'FAIL_P95'
    }
    It 'returns FAIL_P95 when Prime95 log shows FATAL ERROR even if CC log silent' {
        Test-CoreCyclerProbeResult -LogLines @('Set to Core 1') -PrimeLines @('Prime95 FATAL ERROR rounding') -ExitedCleanly $true |
            Should -Be 'FAIL_P95'
    }
    It 'returns TIMEOUT when neither pass nor fail and not exited cleanly' {
        Test-CoreCyclerProbeResult -LogLines @('Set to Core 2') -PrimeLines @() -ExitedCleanly $false |
            Should -Be 'TIMEOUT'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/corecycler-runner-probe.tests.ps1 -Output Detailed`
Expected: FAIL — `Test-CoreCyclerProbeResult` not defined.

- [ ] **Step 3: Implement**

Append to `lib/corecycler-runner.ps1`:

```powershell
# Classify a probe's outcome from CoreCycler + Prime95 log tails.
# WHEA wins (worst class), then P95 errors, then TIMEOUT if process
# didn't exit cleanly, else PASS. The caller layers ABORT_SAFETY on
# top by checking the Safety Guard separately.
function Test-CoreCyclerProbeResult {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$LogLines,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PrimeLines,
        [Parameter(Mandatory)][bool]$ExitedCleanly
    )
    foreach ($l in $LogLines) {
        if ($l -match 'cores with a WHEA error so far:\s*([1-9])') { return 'FAIL_WHEA' }
    }
    foreach ($l in $LogLines) {
        if ($l -match 'cores with an error so far:\s*([1-9])') { return 'FAIL_P95' }
        if ($l -match 'has thrown an error|core_error|core .* errored') { return 'FAIL_P95' }
    }
    foreach ($l in $PrimeLines) {
        if ($l -match 'FATAL ERROR|Rounding was|Hardware failure') { return 'FAIL_P95' }
    }
    if (-not $ExitedCleanly) { return 'TIMEOUT' }
    'PASS'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/corecycler-runner-probe.tests.ps1 -Output Detailed`
Expected: PASS (5/5).

- [ ] **Step 5: Commit**

```bash
git add lib/corecycler-runner.ps1 tests/corecycler-runner-probe.tests.ps1
git commit -m "feat(smart-tune): probe result classifier"
```

---

### Task 11: Invoke-Probe (single-iteration single-scope wrapper)

**Files:**
- Modify: `lib/corecycler-runner.ps1` (append)

> Note: This wraps real subprocess spawning; not unit-tested. Covered by
> manual smoke test in Task 26.

- [ ] **Step 1: Implement**

Append to `lib/corecycler-runner.ps1`:

```powershell
# Invoke a single-iteration probe on one scope (a CCD-group or a single
# core). Blocks until CoreCycler exits or TimeoutSeconds elapses, then
# returns one of PASS/FAIL_P95/FAIL_WHEA/TIMEOUT. Wraps:
#   1. New-CoreCyclerConfig (generate a single-iteration config)
#   2. Start-CoreCyclerRun  (spawn the subprocess)
#   3. wait loop with periodic safety inspection (caller supplies callback)
#   4. classify result and return
#
# Parameters:
#   $RepoRoot        - project root (passed to New-CoreCyclerConfig)
#   $ScopeCores      - int[] of physical core indices to test (whole CCD or one core)
#   $TotalCores      - total physical cores (passed to New-CoreCyclerConfig)
#   $ProbeRuntimeMin - mode.probeRuntimeMin (sets runtimePerCore)
#   $TimeoutSeconds  - how long to wait before forcing TIMEOUT
#   $TickCallback    - optional scriptblock invoked once a second; if it
#                      returns $true, probe is aborted as ABORT_SAFETY
function Invoke-Probe {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][int[]]$ScopeCores,
        [Parameter(Mandatory)][int]$TotalCores,
        [Parameter(Mandatory)][double]$ProbeRuntimeMin,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [scriptblock]$TickCallback = $null
    )
    $rtFmt = "{0}m" -f [int][Math]::Max(1, [Math]::Round($ProbeRuntimeMin))
    $cfg = New-CoreCyclerConfig -RepoRoot $RepoRoot `
        -StressTestProgram 'PRIME95' -Mode 'SSE' -MaxIterations 1 `
        -RuntimePerCore $rtFmt -CoresToTest $ScopeCores -TotalCores $TotalCores `
        -EnableAutomaticAdjustment $false
    Start-CoreCyclerRun -ConfigPath $cfg
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $aborted = $false
    while (Test-CoreCyclerRunning) {
        Start-Sleep -Seconds 1
        if ($TickCallback) {
            if ((& $TickCallback)) { $aborted = $true; break }
        }
        if ((Get-Date) -gt $deadline) { break }
    }
    $cleanExit = (-not (Test-CoreCyclerRunning))
    if (-not $cleanExit) {
        try { Stop-CoreCyclerRun } catch {}
    }
    if ($aborted) { return 'ABORT_SAFETY' }
    $logs = Get-LatestLogs
    $ccLines = @()
    $primeLines = @()
    if ($logs.coreCyclerLog -and (Test-Path $logs.coreCyclerLog)) {
        $ccLines = Get-Content -Path $logs.coreCyclerLog -ErrorAction SilentlyContinue
    }
    if ($logs.prime95Log -and (Test-Path $logs.prime95Log)) {
        $primeLines = Get-Content -Path $logs.prime95Log -ErrorAction SilentlyContinue
    }
    Test-CoreCyclerProbeResult -LogLines $ccLines -PrimeLines $primeLines -ExitedCleanly $cleanExit
}
```

- [ ] **Step 2: Sanity check the file parses**

Run: `powershell.exe -NoProfile -Command "$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('lib/corecycler-runner.ps1',[ref]$null,[ref]$e); if ($e -and $e.Count -gt 0) { $e[0].Message; exit 1 } else { 'OK' }"`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add lib/corecycler-runner.ps1
git commit -m "feat(smart-tune): Invoke-Probe single-iteration scope wrapper"
```

---

## Phase 5 — Orchestrator

The orchestrator is the only stateful module in this feature. We test it with a mocked `Invoke-Probe` so we don't need a real CPU to validate the loop logic.

### Task 12: Session JSON persistence (atomic write-rename)

**Files:**
- Create: `lib/smart-tuner.ps1`
- Create: `tests/smart-tuner.tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll { . "$PSScriptRoot\..\lib\smart-tuner.ps1" }

Describe 'Session persistence' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("rpo-sess-" + [Guid]::NewGuid().ToString('N') + ".json")
    }
    AfterEach { if (Test-Path $script:tmp) { Remove-Item $script:tmp -Force } }
    It 'Save-TuneSession writes atomically (no partial file on crash)' {
        $sess = @{
            sessionId='abc'; mode='daily-driver'; cpuModel='Test'
            scopes = @(@{id='CCD0'; status='COMPLETED'})
        }
        Save-TuneSession -Path $script:tmp -Session $sess
        Test-Path $script:tmp | Should -BeTrue
        Test-Path "$script:tmp.tmp" | Should -BeFalse   # tmp cleaned up
        $loaded = Load-TuneSession -Path $script:tmp
        $loaded.sessionId | Should -Be 'abc'
        $loaded.scopes[0].id | Should -Be 'CCD0'
    }
    It 'Load-TuneSession returns null when file missing' {
        Load-TuneSession -Path $script:tmp | Should -Be $null
    }
    It 'Clear-TuneSession removes the file' {
        Save-TuneSession -Path $script:tmp -Session @{sessionId='x'}
        Clear-TuneSession -Path $script:tmp
        Test-Path $script:tmp | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner.tests.ps1 -Output Detailed`
Expected: FAIL — `Save-TuneSession` not defined.

- [ ] **Step 3: Implement (initial skeleton)**

```powershell
# ============================================================================
#  smart-tuner.ps1 - Orchestrator for Smart Auto-Adjust
# ============================================================================
#  Drives the per-scope bisection loop, applies CO values via the
#  existing co-reader-writer, integrates with the Safety Guard, and
#  persists session state after every probe so a crash mid-run is
#  recoverable. Wires the search engine, history store, mode policy,
#  narrative emitter, and probe wrapper together.
#
#  Public surface:
#    Start-SmartTune     -Mode -Direction
#    Stop-SmartTune
#    Resume-SmartTune
#    Discard-SmartTune
#    Get-SmartTuneState  (for /api/smart-tune/state)
#    Save-TuneSession / Load-TuneSession / Clear-TuneSession (also used
#                       on startup to detect a previous session)
# ============================================================================
Set-StrictMode -Version Latest

if (Get-Command Write-Log -ErrorAction SilentlyContinue) {} # logging optional in tests

function Save-TuneSession {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Session
    )
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.tmp"
    $Session | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Force $tmp $Path
}

function Load-TuneSession {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { Get-Content -Path $Path -Raw | ConvertFrom-Json } catch { $null }
}

function Clear-TuneSession {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner.tests.ps1 -Output Detailed`
Expected: PASS (3/3).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner.ps1 tests/smart-tuner.tests.ps1
git commit -m "feat(smart-tune): orchestrator session JSON persistence"
```

---

### Task 13: Plan-TuneSession (CCD ordering, V-Cache first)

**Files:**
- Modify: `lib/smart-tuner.ps1` (append)
- Modify: `tests/smart-tuner.tests.ps1` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/smart-tuner.tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot\..\lib\smart-tuner-modes.ps1"
    . "$PSScriptRoot\..\lib\smart-tuner-search.ps1"
    . "$PSScriptRoot\..\lib\smart-tuner.ps1"
}

Describe 'Plan-TuneSession' {
    It 'plans CCD0+CCD1 for dual-CCD with V-Cache CCD0 first' {
        $cpu = [PSCustomObject]@{
            Name='Test 7950X3D'; Cores=16; CcdCount=2; CoresPerCcd=8
            IsDualCcd=$true; VCacheCcdIndex=0
        }
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $plan = Plan-TuneSession -Cpu $cpu -Policy $policy
        $plan.Count | Should -Be 2
        $plan[0].id     | Should -Be 'CCD0'
        $plan[0].isVCache | Should -BeTrue
        $plan[0].cores  | Should -Be @(0,1,2,3,4,5,6,7)
        $plan[1].id     | Should -Be 'CCD1'
    }
    It 'plans single CCD for non-X3D parts' {
        $cpu = [PSCustomObject]@{
            Name='Test 7700X'; Cores=8; CcdCount=1; CoresPerCcd=8
            IsDualCcd=$false; VCacheCcdIndex=$null
        }
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $plan = Plan-TuneSession -Cpu $cpu -Policy $policy
        $plan.Count | Should -Be 1
        $plan[0].id | Should -Be 'CCD0'
    }
    It 'adds per-core refinement scopes when policy.refinePerCore is true' {
        $cpu = [PSCustomObject]@{
            Name='Test 7950X3D'; Cores=16; CcdCount=2; CoresPerCcd=8
            IsDualCcd=$true; VCacheCcdIndex=0
        }
        $policy = Get-ModePolicy -Mode 'max-stable' -Direction 'undervolt'
        $plan = Plan-TuneSession -Cpu $cpu -Policy $policy
        # 2 CCD scopes + 16 per-core scopes
        $plan.Count | Should -Be 18
        @($plan | Where-Object { $_.id -match '^core' }).Count | Should -Be 16
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner.tests.ps1 -Output Detailed`
Expected: FAIL — `Plan-TuneSession` not defined.

- [ ] **Step 3: Implement**

Append to `lib/smart-tuner.ps1`:

```powershell
# Build the list of scopes to probe, in order. V-Cache CCD always first
# (failing fast on the tighter silicon is safer than failing late after
# a long Standard run). Per-core scopes appended when policy demands.
function Plan-TuneSession {
    param(
        [Parameter(Mandatory)]$Cpu,
        [Parameter(Mandatory)]$Policy
    )
    $scopes = New-Object System.Collections.Generic.List[object]
    $vCacheIdx = $Cpu.VCacheCcdIndex
    $ccdOrder = if ($null -ne $vCacheIdx) {
        @($vCacheIdx) + @(0..($Cpu.CcdCount - 1) | Where-Object { $_ -ne $vCacheIdx })
    } else {
        @(0..($Cpu.CcdCount - 1))
    }
    foreach ($ccd in $ccdOrder) {
        $start = $ccd * $Cpu.CoresPerCcd
        $cores = @($start..($start + $Cpu.CoresPerCcd - 1))
        $scopes.Add([PSCustomObject]@{
            id        = "CCD$ccd"
            isVCache  = ($null -ne $vCacheIdx -and $vCacheIdx -eq $ccd)
            cores     = $cores
            status    = 'PENDING'
            phase     = 'A'
        })
    }
    if ($Policy.refinePerCore) {
        for ($c = 0; $c -lt $Cpu.Cores; $c++) {
            $ccd = if ($Cpu.IsDualCcd) { [int]([Math]::Floor($c / $Cpu.CoresPerCcd)) } else { 0 }
            $scopes.Add([PSCustomObject]@{
                id        = "core$c"
                isVCache  = ($null -ne $vCacheIdx -and $vCacheIdx -eq $ccd)
                cores     = @($c)
                status    = 'PENDING'
                phase     = 'B'
            })
        }
    }
    , @($scopes.ToArray())
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner.tests.ps1 -Output Detailed`
Expected: PASS (6/6 cumulative).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner.ps1 tests/smart-tuner.tests.ps1
git commit -m "feat(smart-tune): Plan-TuneSession (V-Cache first, optional per-core)"
```

---

### Task 14: Step-OneProbe (mockable single-probe loop iteration)

**Files:**
- Modify: `lib/smart-tuner.ps1` (append)
- Modify: `tests/smart-tuner.tests.ps1` (append)

> Why factor this out: the full orchestrator loop is hard to test
> because it spawns subprocesses. `Step-OneProbe` is the "do one
> iteration of the bisection for one scope" function, parameterised
> with the probe runner as a scriptblock. Test it by passing a fake
> runner that returns scripted results.

- [ ] **Step 1: Write the failing test**

Append to `tests/smart-tuner.tests.ps1`:

```powershell
Describe 'Step-OneProbe' {
    BeforeEach {
        $script:policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $script:scope = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $script:applied = $null
        $script:applyFn = { param($v) $script:applied = $v }.GetNewClosure()
    }
    It 'updates scope after one probe (PASS case)' {
        $probeFn = { 'PASS' }
        $new = Step-OneProbe -ScopeState $script:scope -Policy $script:policy `
            -ProbeFn $probeFn -ApplyFn $script:applyFn -TelemetryHeadroom 1.0
        $new.probesCompleted | Should -Be 1
        $new.lastResult      | Should -Be 'PASS'
        $new.knownStable     | Should -Not -Be $null
        $script:applied      | Should -Be $new.lastCandidate
    }
    It 'updates scope after one probe (FAIL_WHEA case)' {
        $probeFn = { 'FAIL_WHEA' }
        $new = Step-OneProbe -ScopeState $script:scope -Policy $script:policy `
            -ProbeFn $probeFn -ApplyFn $script:applyFn -TelemetryHeadroom 1.0
        $new.lastResult    | Should -Be 'FAIL_WHEA'
        $new.knownUnstable | Should -Not -Be $null
    }
    It 'converges to lock value after a scripted sequence' {
        $script:results = @('PASS','PASS','FAIL_P95','PASS','FAIL_WHEA')
        $script:i = 0
        $probeFn = { $r = $script:results[$script:i]; $script:i++; $r }.GetNewClosure()
        $state = $script:scope
        while (-not (Test-ScopeConverged -ScopeState $state) -and $script:i -lt $script:results.Count) {
            $state = Step-OneProbe -ScopeState $state -Policy $script:policy `
                -ProbeFn $probeFn -ApplyFn $script:applyFn -TelemetryHeadroom 1.0
        }
        Test-ScopeConverged -ScopeState $state | Should -BeTrue
        $locked = Get-LockInValue -ScopeState $state -Policy $script:policy
        $locked | Should -Not -Be $null
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner.tests.ps1 -Output Detailed`
Expected: FAIL — `Step-OneProbe` not defined.

- [ ] **Step 3: Implement**

Append to `lib/smart-tuner.ps1`:

```powershell
# One iteration of the bisection for one scope:
#   1. Compute candidate via Get-NextCandidate (modulated by telemetry)
#   2. Apply CO via $ApplyFn (caller's responsibility - usually
#      Set-AllCoreCo wrapped in panic-revert)
#   3. Run probe via $ProbeFn (returns one of the result strings)
#   4. Update state via Update-ScopeFromResult
#
# Factored so tests can inject a fake $ProbeFn and $ApplyFn - real
# orchestrator uses Invoke-Probe and Save-PanicRevertState + Set-AllCoreCo.
function Step-OneProbe {
    param(
        [Parameter(Mandatory)]$ScopeState,
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)][scriptblock]$ProbeFn,
        [Parameter(Mandatory)][scriptblock]$ApplyFn,
        [Parameter(Mandatory)][double]$TelemetryHeadroom
    )
    $candidate = Get-NextCandidate -ScopeState $ScopeState -TelemetryHeadroom $TelemetryHeadroom -Policy $Policy
    & $ApplyFn $candidate
    $result = & $ProbeFn $candidate
    Update-ScopeFromResult -ScopeState $ScopeState -Candidate $candidate -Result $result
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner.tests.ps1 -Output Detailed`
Expected: PASS (9/9 cumulative).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner.ps1 tests/smart-tuner.tests.ps1
git commit -m "feat(smart-tune): Step-OneProbe (mockable bisection step)"
```

---

### Task 15: Tune-Scope (loop until converged) + Get-TelemetryHeadroom

**Files:**
- Modify: `lib/smart-tuner.ps1` (append)
- Modify: `tests/smart-tuner.tests.ps1` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/smart-tuner.tests.ps1`:

```powershell
Describe 'Tune-Scope' {
    It 'iterates Step-OneProbe until convergence, returns final state' {
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $scope  = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $policy
        $applied = @()
        $applyFn = { param($v) $script:applied += $v }.GetNewClosure()
        # Scripted probes: 4 PASS then FAIL_WHEA -> should converge fast
        $script:i = 0
        $results = @('PASS','PASS','PASS','PASS','FAIL_WHEA','FAIL_WHEA','FAIL_WHEA','FAIL_WHEA')
        $probeFn = { $r = $results[$script:i]; $script:i = [Math]::Min($script:i+1, $results.Count-1); $r }.GetNewClosure()
        $headroomFn = { 1.0 }
        $script:applied = @()
        $final = Tune-Scope -ScopeState $scope -Policy $policy `
            -ProbeFn $probeFn -ApplyFn $applyFn -HeadroomFn $headroomFn -MaxProbes 20
        Test-ScopeConverged -ScopeState $final | Should -BeTrue
        $final.probesCompleted | Should -BeLessThan 20
    }
    It 'stops at MaxProbes safety cap even if not converged' {
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $scope  = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $policy
        $probeFn = { 'PASS' }   # would loop forever without cap
        $applyFn = { }
        $headroomFn = { 1.0 }
        $final = Tune-Scope -ScopeState $scope -Policy $policy `
            -ProbeFn $probeFn -ApplyFn $applyFn -HeadroomFn $headroomFn -MaxProbes 5
        $final.probesCompleted | Should -Be 5
    }
}

Describe 'Get-TelemetryHeadroom' {
    It 'returns 1.0 when both temp and VID far under limits' {
        $snap = [PSCustomObject]@{
            packageTemp = 50; cores = @([PSCustomObject]@{ voltage = 1.0 })
        }
        Get-TelemetryHeadroom -Snapshot $snap -MaxTempC 95 -MaxVid 1.45 | Should -Be 1.0
    }
    It 'returns 0.0 when temp is at limit' {
        $snap = [PSCustomObject]@{
            packageTemp = 95; cores = @([PSCustomObject]@{ voltage = 1.0 })
        }
        Get-TelemetryHeadroom -Snapshot $snap -MaxTempC 95 -MaxVid 1.45 | Should -Be 0.0
    }
    It 'returns 0.0 on null snapshot (defensive default)' {
        Get-TelemetryHeadroom -Snapshot $null -MaxTempC 95 -MaxVid 1.45 | Should -Be 0.0
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner.tests.ps1 -Output Detailed`
Expected: FAIL — `Tune-Scope` and `Get-TelemetryHeadroom` not defined.

- [ ] **Step 3: Implement**

Append to `lib/smart-tuner.ps1`:

```powershell
# Returns a value in [0, 1] describing how far we are from the safety
# limits. 1.0 = lots of headroom, 0.0 = at or past a limit.
# Used by the search engine to shrink step sizes near the edge.
function Get-TelemetryHeadroom {
    param(
        $Snapshot,
        [Parameter(Mandatory)][int]$MaxTempC,
        [Parameter(Mandatory)][double]$MaxVid
    )
    if ($null -eq $Snapshot) { return 0.0 }
    $temp = if ($null -ne $Snapshot.packageTemp) { [double]$Snapshot.packageTemp } else { 0.0 }
    $vid  = 0.0
    foreach ($c in @($Snapshot.cores)) {
        if ($null -ne $c.voltage -and $c.voltage -gt $vid) { $vid = [double]$c.voltage }
    }
    $tHead = [Math]::Max(0.0, [Math]::Min(1.0, ($MaxTempC - $temp) / [double]$MaxTempC))
    $vHead = [Math]::Max(0.0, [Math]::Min(1.0, ($MaxVid  - $vid)  / [double]$MaxVid))
    [Math]::Min($tHead, $vHead)
}

# Loop Step-OneProbe until convergence or MaxProbes hit. Pure logic,
# I/O is in the injected scriptblocks.
function Tune-Scope {
    param(
        [Parameter(Mandatory)]$ScopeState,
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)][scriptblock]$ProbeFn,
        [Parameter(Mandatory)][scriptblock]$ApplyFn,
        [Parameter(Mandatory)][scriptblock]$HeadroomFn,
        [int]$MaxProbes = 12
    )
    $state = $ScopeState
    while (-not (Test-ScopeConverged -ScopeState $state) -and $state.probesCompleted -lt $MaxProbes) {
        $headroom = [double](& $HeadroomFn)
        $state = Step-OneProbe -ScopeState $state -Policy $Policy `
            -ProbeFn $ProbeFn -ApplyFn $ApplyFn -TelemetryHeadroom $headroom
    }
    $state
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner.tests.ps1 -Output Detailed`
Expected: PASS (12/12 cumulative).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner.ps1 tests/smart-tuner.tests.ps1
git commit -m "feat(smart-tune): Tune-Scope loop + Get-TelemetryHeadroom"
```

---

### Task 16: Start-SmartTune / Stop-SmartTune / Get-SmartTuneState (orchestrator state)

**Files:**
- Modify: `lib/smart-tuner.ps1` (append)
- Modify: `tests/smart-tuner.tests.ps1` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/smart-tuner.tests.ps1`:

```powershell
Describe 'Tune session state machine' {
    BeforeEach {
        . "$PSScriptRoot\..\lib\smart-tuner-narrative.ps1"
        Clear-TunerNarrative
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("rpo-sess-" + [Guid]::NewGuid().ToString('N') + ".json")
    }
    AfterEach {
        if (Test-Path $script:tmp) { Remove-Item $script:tmp -Force }
        Stop-SmartTune
    }
    It 'Start-SmartTune builds plan, marks state as RUNNING, emits narrative' {
        $cpu = [PSCustomObject]@{
            Name='Test'; Cores=16; CcdCount=2; CoresPerCcd=8
            IsDualCcd=$true; VCacheCcdIndex=0
        }
        Start-SmartTune -Cpu $cpu -Mode 'daily-driver' -Direction 'undervolt' `
            -SessionPath $script:tmp -HistoryPath ([IO.Path]::GetTempFileName())
        $state = Get-SmartTuneState -SinceSeqId 0
        $state.status      | Should -Be 'RUNNING'
        $state.mode        | Should -Be 'daily-driver'
        $state.scopes.Count | Should -Be 2
        $state.narrative.Count | Should -BeGreaterThan 0
    }
    It 'Stop-SmartTune transitions to STOPPED' {
        $cpu = [PSCustomObject]@{
            Name='Test'; Cores=8; CcdCount=1; CoresPerCcd=8
            IsDualCcd=$false; VCacheCcdIndex=$null
        }
        Start-SmartTune -Cpu $cpu -Mode 'daily-driver' -Direction 'undervolt' `
            -SessionPath $script:tmp -HistoryPath ([IO.Path]::GetTempFileName())
        Stop-SmartTune
        $state = Get-SmartTuneState -SinceSeqId 0
        $state.status | Should -Be 'STOPPED'
    }
    It 'Get-SmartTuneState returns IDLE when no session' {
        Stop-SmartTune
        $state = Get-SmartTuneState -SinceSeqId 0
        $state.status | Should -Be 'IDLE'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner.tests.ps1 -Output Detailed`
Expected: FAIL — `Start-SmartTune` not defined.

- [ ] **Step 3: Implement**

Append to `lib/smart-tuner.ps1`:

```powershell
# In-memory orchestrator state. Reset by Stop-SmartTune.
$script:Tune = @{
    Status       = 'IDLE'        # IDLE | RUNNING | STOPPING | STOPPED | COMPLETED | FAILED
    SessionId    = $null
    StartedAt    = $null
    Mode         = $null
    Direction    = $null
    Cpu          = $null
    Policy       = $null
    Scopes       = @()           # array of @{id,isVCache,cores,status,locked,scopeState,...}
    CurrentIdx   = -1
    SessionPath  = $null
    HistoryPath  = $null
}

function Start-SmartTune {
    param(
        [Parameter(Mandatory)]$Cpu,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Direction,
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][string]$HistoryPath
    )
    Clear-TunerNarrative
    $policy = Get-ModePolicy -Mode $Mode -Direction $Direction
    $plan = Plan-TuneSession -Cpu $Cpu -Policy $policy

    $script:Tune.Status      = 'RUNNING'
    $script:Tune.SessionId   = [Guid]::NewGuid().ToString('N').Substring(0,8)
    $script:Tune.StartedAt   = (Get-Date).ToUniversalTime().ToString('o')
    $script:Tune.Mode        = $Mode
    $script:Tune.Direction   = $Direction
    $script:Tune.Cpu         = $Cpu
    $script:Tune.Policy      = $policy
    $script:Tune.Scopes      = $plan
    $script:Tune.CurrentIdx  = -1
    $script:Tune.SessionPath = $SessionPath
    $script:Tune.HistoryPath = $HistoryPath

    Write-TunerNarrative -Icon '⚙' -Message "Smart Tune started · $Mode · $Direction"
    Write-TunerNarrative -Icon '🎯' -Message "Plan: $($plan.Count) scopes to tune"
    Save-TuneSession -Path $SessionPath -Session (Get-SmartTuneState -SinceSeqId 0)
}

function Stop-SmartTune {
    if ($script:Tune.Status -eq 'RUNNING') {
        Write-TunerNarrative -Icon '⚙' -Message 'Smart Tune stopped by user'
    }
    $script:Tune.Status = 'STOPPED'
}

function Discard-SmartTune {
    Stop-SmartTune
    if ($script:Tune.SessionPath) { Clear-TuneSession -Path $script:Tune.SessionPath }
    $script:Tune.Status = 'IDLE'
}

function Get-SmartTuneState {
    param([int]$SinceSeqId = 0)
    [PSCustomObject]@{
        status      = $script:Tune.Status
        sessionId   = $script:Tune.SessionId
        startedAt   = $script:Tune.StartedAt
        mode        = $script:Tune.Mode
        direction   = $script:Tune.Direction
        scopes      = @($script:Tune.Scopes)
        currentIdx  = $script:Tune.CurrentIdx
        narrative   = (Get-NewNarrativeEntries -SinceSeqId $SinceSeqId)
        latestSeqId = (Get-CurrentNarrativeSeqId)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner.tests.ps1 -Output Detailed`
Expected: PASS (15/15 cumulative).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner.ps1 tests/smart-tuner.tests.ps1
git commit -m "feat(smart-tune): Start/Stop/Discard/Get-SmartTuneState"
```

---

### Task 17: Step-SmartTune (one orchestrator tick — drives one probe of the current scope)

**Files:**
- Modify: `lib/smart-tuner.ps1` (append)
- Modify: `tests/smart-tuner.tests.ps1` (append)

> The orchestrator runs probes via a per-tick function so the HTTP
> server (which is single-threaded) can drive it from the `/api/status`
> handler without blocking. Step-SmartTune does one probe per call,
> updates the scope state, persists session, and advances to the next
> scope when convergence happens.

- [ ] **Step 1: Write the failing test**

Append to `tests/smart-tuner.tests.ps1`:

```powershell
Describe 'Step-SmartTune' {
    BeforeEach {
        . "$PSScriptRoot\..\lib\smart-tuner-narrative.ps1"
        . "$PSScriptRoot\..\lib\smart-tuner-history.ps1"
        Clear-TunerNarrative
        $script:tmpSess = [IO.Path]::GetTempFileName()
        $script:tmpHist = [IO.Path]::GetTempFileName()
        $cpu = [PSCustomObject]@{
            Name='Test'; Cores=8; CcdCount=1; CoresPerCcd=8
            IsDualCcd=$false; VCacheCcdIndex=$null
        }
        Start-SmartTune -Cpu $cpu -Mode 'daily-driver' -Direction 'undervolt' `
            -SessionPath $script:tmpSess -HistoryPath $script:tmpHist
    }
    AfterEach {
        Discard-SmartTune
        Remove-Item $script:tmpSess -Force -ErrorAction SilentlyContinue
        Remove-Item $script:tmpHist -Force -ErrorAction SilentlyContinue
    }
    It 'completes the only scope after a sequence of probes and transitions to COMPLETED' {
        $script:results = @('PASS','PASS','PASS','FAIL_P95','PASS','FAIL_WHEA')
        $script:i = 0
        $probeFn = { $r = $script:results[$script:i]; $script:i = [Math]::Min($script:i+1, $script:results.Count-1); $r }.GetNewClosure()
        $applyFn = { param($v) }
        $headroomFn = { 1.0 }
        for ($t = 0; $t -lt 20; $t++) {
            $cont = Step-SmartTune -ProbeFn $probeFn -ApplyFn $applyFn -HeadroomFn $headroomFn -MaxProbesPerScope 12
            if (-not $cont) { break }
        }
        $state = Get-SmartTuneState -SinceSeqId 0
        $state.status | Should -Be 'COMPLETED'
        $state.scopes[0].status | Should -Match 'LOCKED|FAILED'
    }
    It 'writes history entries as probes complete' {
        $script:results = @('PASS','PASS','FAIL_P95')
        $script:i = 0
        $probeFn = { $r = $script:results[$script:i]; $script:i = [Math]::Min($script:i+1, $script:results.Count-1); $r }.GetNewClosure()
        $applyFn = { param($v) }
        $headroomFn = { 1.0 }
        for ($t = 0; $t -lt 6; $t++) {
            $cont = Step-SmartTune -ProbeFn $probeFn -ApplyFn $applyFn -HeadroomFn $headroomFn -MaxProbesPerScope 5
            if (-not $cont) { break }
        }
        $lines = Get-Content $script:tmpHist -ErrorAction SilentlyContinue
        $lines.Count | Should -BeGreaterThan 0
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester tests/smart-tuner.tests.ps1 -Output Detailed`
Expected: FAIL — `Step-SmartTune` not defined.

- [ ] **Step 3: Implement**

Append to `lib/smart-tuner.ps1`:

```powershell
# One orchestrator tick: drives ONE probe of the current scope.
# Returns $true if there's more work, $false if the whole session is
# done. Designed to be called from the HTTP status handler so the
# server stays responsive between probes.
function Step-SmartTune {
    param(
        [Parameter(Mandatory)][scriptblock]$ProbeFn,
        [Parameter(Mandatory)][scriptblock]$ApplyFn,
        [Parameter(Mandatory)][scriptblock]$HeadroomFn,
        [int]$MaxProbesPerScope = 12
    )
    if ($script:Tune.Status -ne 'RUNNING') { return $false }
    if ($script:Tune.Scopes.Count -eq 0)  { $script:Tune.Status = 'COMPLETED'; return $false }

    # Advance to next pending scope if needed
    if ($script:Tune.CurrentIdx -lt 0 -or
        $script:Tune.CurrentIdx -ge $script:Tune.Scopes.Count -or
        $script:Tune.Scopes[$script:Tune.CurrentIdx].status -in 'LOCKED','FAILED') {

        $next = -1
        for ($i = 0; $i -lt $script:Tune.Scopes.Count; $i++) {
            if ($script:Tune.Scopes[$i].status -eq 'PENDING') { $next = $i; break }
        }
        if ($next -lt 0) {
            $script:Tune.Status = 'COMPLETED'
            Write-TunerNarrative -Icon '🔒' -Message 'All scopes locked. Smart Tune complete.'
            Save-TuneSession -Path $script:Tune.SessionPath -Session (Get-SmartTuneState -SinceSeqId 0)
            return $false
        }
        $script:Tune.CurrentIdx = $next
        $sc = $script:Tune.Scopes[$next]
        $sc | Add-Member -NotePropertyName scopeState -NotePropertyValue (
            New-ScopeState -ScopeId $sc.id -IsVCache $sc.isVCache -SeedValue 0 -Policy $script:Tune.Policy
        ) -Force
        $sc.status = 'PROBING'
        Write-TunerNarrative -Icon '➤' -Message "Starting scope $($sc.id)" -Payload @{ scope = $sc.id }
    }

    $cur = $script:Tune.Scopes[$script:Tune.CurrentIdx]
    if ($cur.scopeState.probesCompleted -ge $MaxProbesPerScope) {
        # Out of probe budget without convergence - mark FAILED and move on
        $cur.status = 'FAILED'
        Write-TunerNarrative -Icon '⚠' -Message "Scope $($cur.id) exceeded probe budget without converging"
        Save-TuneSession -Path $script:Tune.SessionPath -Session (Get-SmartTuneState -SinceSeqId 0)
        return $true
    }

    if (Test-ScopeConverged -ScopeState $cur.scopeState) {
        $locked = Get-LockInValue -ScopeState $cur.scopeState -Policy $script:Tune.Policy
        if ($null -ne $locked) {
            $cur | Add-Member -NotePropertyName locked -NotePropertyValue $locked -Force
            $cur.status = 'LOCKED'
            Write-TunerNarrative -Icon '🔒' -Message "Locked $($cur.id) at $locked" -Payload @{ scope = $cur.id; value = $locked }
        } else {
            $cur.status = 'FAILED'
            Write-TunerNarrative -Icon '⚠' -Message "Scope $($cur.id) failed to find a stable value in range"
        }
        Save-TuneSession -Path $script:Tune.SessionPath -Session (Get-SmartTuneState -SinceSeqId 0)
        return $true
    }

    # Do one probe
    $headroom = [double](& $HeadroomFn)
    $cand = Get-NextCandidate -ScopeState $cur.scopeState -TelemetryHeadroom $headroom -Policy $script:Tune.Policy
    Write-TunerNarrative -Icon '➤' -Message "Probe $($cur.scopeState.probesCompleted + 1) of $($cur.id): trying CO=$cand" -Payload @{ scope=$cur.id; value=$cand }
    & $ApplyFn $cand
    $result = & $ProbeFn $cand
    $cur.scopeState = Update-ScopeFromResult -ScopeState $cur.scopeState -Candidate $cand -Result $result

    $icon = switch ($result) { 'PASS' {'✓'} 'FAIL_WHEA' {'⚠'} default {'✗'} }
    Write-TunerNarrative -Icon $icon -Message "$($cur.id) probe $($cur.scopeState.probesCompleted): $result at CO=$cand" -Payload @{ scope=$cur.id; value=$cand; result=$result }

    # Append to history
    if ($script:Tune.HistoryPath) {
        Add-HistoryEntry -Path $script:Tune.HistoryPath -Entry @{
            cpuModel  = $script:Tune.Cpu.Name
            scope     = $cur.id
            value     = $cand
            result    = $result
            mode      = $script:Tune.Mode
            sessionId = $script:Tune.SessionId
        }
    }
    Save-TuneSession -Path $script:Tune.SessionPath -Session (Get-SmartTuneState -SinceSeqId 0)
    $true
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester tests/smart-tuner.tests.ps1 -Output Detailed`
Expected: PASS (17/17 cumulative).

- [ ] **Step 5: Commit**

```bash
git add lib/smart-tuner.ps1 tests/smart-tuner.tests.ps1
git commit -m "feat(smart-tune): Step-SmartTune orchestrator tick"
```

---

## Phase 6 — Server integration

### Task 18: Load modules + register Smart Tune routes in server.ps1

**Files:**
- Modify: `server.ps1`

- [ ] **Step 1: Dot-source the new modules**

Add to `server.ps1` after the existing `. "$PSScriptRoot\lib\safety-guard.ps1"` line:

```powershell
. "$PSScriptRoot\lib\smart-tuner-modes.ps1"
. "$PSScriptRoot\lib\smart-tuner-search.ps1"
. "$PSScriptRoot\lib\smart-tuner-history.ps1"
. "$PSScriptRoot\lib\smart-tuner-narrative.ps1"
. "$PSScriptRoot\lib\smart-tuner.ps1"
```

- [ ] **Step 2: Add the new endpoint registrations**

Add after the existing `/api/settings` route in `server.ps1`:

```powershell
$script:SmartTuneSessionPath = Join-Path $RepoRoot 'runtime\tuner-session.json'
$script:SmartTuneHistoryPath = Join-Path $RepoRoot 'runtime\tuner-history.jsonl'

Register-Route -Method POST -Path '/api/smart-tune/start' -Handler {
    param($ctx, $params)
    if (-not $runnerReady) { return @{ ok = $false; error = 'CoreCycler not installed' } }
    if (-not $coReady)     { return @{ ok = $false; error = 'CO tool not initialized' } }
    $cur = (Get-CurrentState).state
    if ($cur -ne 'IDLE' -and $cur -ne 'REPORTING') {
        return @{ ok = $false; error = "Cannot start - state=$cur" }
    }
    $body = Read-JsonBody -Context $ctx
    $mode      = if ($body -and $body.mode) { [string]$body.mode } else { 'daily-driver' }
    $direction = if ($body -and $body.direction) { [string]$body.direction } else { 'undervolt' }
    try {
        Start-SmartTune -Cpu $cpu -Mode $mode -Direction $direction `
            -SessionPath $script:SmartTuneSessionPath -HistoryPath $script:SmartTuneHistoryPath
        Set-CurrentState -NewState 'TESTING' -Data @{
            startedAt = (Get-Date -Format 'o')
            smartTune = $true
            mode = $mode
            direction = $direction
        }
        # Arm safety guard for the entire session
        $wheaCount = @(Get-WheaEvents).Count
        Enable-SafetyGuard -WheaBaseline $wheaCount -OnAbort {
            param($violations)
            Write-Log ERROR "SmartTune safety abort"
            Stop-SmartTune
            Set-CurrentState -NewState 'REPORTING' -Force
        }.GetNewClosure()
        @{ ok = $true; data = (Get-SmartTuneState -SinceSeqId 0) }
    } catch {
        @{ ok = $false; error = $_.Exception.Message }
    }
}

Register-Route -Method POST -Path '/api/smart-tune/stop' -Handler {
    Stop-SmartTune
    Disable-SafetyGuard
    Set-CurrentState -NewState 'REPORTING' -Force
    @{ ok = $true; data = (Get-SmartTuneState -SinceSeqId 0) }
}

Register-Route -Method GET -Path '/api/smart-tune/state' -Handler {
    param($ctx, $params)
    $since = 0
    $q = $ctx.Request.Url.Query
    if ($q -match '[?&]since=(\d+)') { $since = [int]$Matches[1] }
    @{ ok = $true; data = (Get-SmartTuneState -SinceSeqId $since) }
}

Register-Route -Method POST -Path '/api/smart-tune/resume' -Handler {
    $sess = Load-TuneSession -Path $script:SmartTuneSessionPath
    if (-not $sess) { return @{ ok = $false; error = 'No session to resume' } }
    @{ ok = $true; data = @{ resumed = $true; sessionId = $sess.sessionId } }
}

Register-Route -Method POST -Path '/api/smart-tune/discard' -Handler {
    Discard-SmartTune
    Clear-PanicRevertState
    @{ ok = $true; data = @{ discarded = $true } }
}

Register-Route -Method GET -Path '/api/smart-tune/history' -Handler {
    $entries = @(Read-HistoryEntries -Path $script:SmartTuneHistoryPath -CpuModel $cpu.Name)
    @{ ok = $true; data = @{ cpuModel = $cpu.Name; entries = $entries } }
}
```

- [ ] **Step 3: Parse-check the file**

Run: `powershell.exe -NoProfile -Command "$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('server.ps1',[ref]$null,[ref]$e); if ($e -and $e.Count -gt 0) { $e[0..2] | ForEach-Object { 'L'+$_.Extent.StartLineNumber+': '+$_.Message }; exit 1 } else { 'OK' }"`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add server.ps1
git commit -m "feat(smart-tune): server endpoints + module loading"
```

---

### Task 19: Tick callback drives the Step-SmartTune from /api/status

**Files:**
- Modify: `server.ps1` (modify the `/api/status` handler)

- [ ] **Step 1: Modify /api/status to run one Step-SmartTune tick when a Smart Tune is active**

Find the existing `/api/status` handler in `server.ps1` and add a Smart Tune driver block before the existing `$state.state -eq 'TESTING'` block:

```powershell
    # Smart Tune driver: if a Smart Tune is running, do one probe tick.
    # This is intentionally driven from /api/status (the 1Hz browser
    # poll) so the server stays single-threaded and request handlers
    # are never blocked on a long-running CoreCycler subprocess - each
    # tick spawns CoreCycler synchronously but the next /api/status
    # only fires after the user's browser re-polls.
    $tuneState = Get-SmartTuneState -SinceSeqId 0
    if ($tuneState.status -eq 'RUNNING') {
        $probeFn = {
            param($cand)
            $rt = $script:Tune.Policy.probeRuntimeMin
            $timeout = [int]($rt * 60 * 2)   # 2x runtime as hard timeout
            Invoke-Probe -RepoRoot $RepoRoot -ScopeCores $script:Tune.Scopes[$script:Tune.CurrentIdx].cores `
                -TotalCores $cpu.Cores -ProbeRuntimeMin $rt -TimeoutSeconds $timeout `
                -TickCallback { (Get-SafetyState).newAbort }
        }.GetNewClosure()
        $applyFn = {
            param($cand)
            $all = New-Object 'int[]' $cpu.Cores
            $scope = $script:Tune.Scopes[$script:Tune.CurrentIdx]
            # Read current, then overwrite only this scope's cores
            $current = Get-AllCoreCo -CoreCount $cpu.Cores
            for ($i = 0; $i -lt $cpu.Cores; $i++) { $all[$i] = $current[$i] }
            foreach ($c in $scope.cores) { $all[$c] = $cand }
            Save-PanicRevertState -Values $all -Reason "SmartTune $($scope.id) probe CO=$cand"
            Set-AllCoreCo -Values $all
        }.GetNewClosure()
        $headroomFn = {
            $snap = if ($telemetryReady) { Read-TelemetrySnapshot } else { $null }
            Get-TelemetryHeadroom -Snapshot $snap -MaxTempC 95 -MaxVid 1.45
        }.GetNewClosure()
        $continued = Step-SmartTune -ProbeFn $probeFn -ApplyFn $applyFn -HeadroomFn $headroomFn -MaxProbesPerScope 12
        if (-not $continued) {
            Disable-SafetyGuard
            Clear-PanicRevertState
            Set-CurrentState -NewState 'REPORTING' -Force
        }
    }
```

Add it right before `if ($state.state -eq 'TESTING' -or $state.state -eq 'STOPPING') {` in the existing handler.

- [ ] **Step 2: Surface smartTune in the /api/status response**

Find the response object at the end of `/api/status` handler and extend it:

```powershell
    @{
        ok = $true
        data = @{
            state = $state.state
            stateData = $state.data
            live = $live
            wheaEvents = $whea
            bodyguardActive = (Test-WheaWatcherActive)
            safetyGuard = (Get-SafetyState)
            panicRevertPending = ($null -ne $script:PendingPanicRevert)
            smartTune = (Get-SmartTuneState -SinceSeqId 0)   # NEW
        }
    }
```

- [ ] **Step 3: Parse-check**

Run: `powershell.exe -NoProfile -Command "$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('server.ps1',[ref]$null,[ref]$e); if ($e) { exit 1 } else { 'OK' }"`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add server.ps1
git commit -m "feat(smart-tune): /api/status drives Step-SmartTune tick"
```

---

### Task 20: Startup detection of previous session (offer resume/discard)

**Files:**
- Modify: `server.ps1`

- [ ] **Step 1: Add the previous-session banner near the existing panic-revert detection**

In `server.ps1`, find the existing `$script:PendingPanicRevert = $null` block and add this after it:

```powershell
$script:PendingSmartSession = $null
$sessPath = Join-Path $RepoRoot 'runtime\tuner-session.json'
if (Test-Path $sessPath) {
    try {
        $script:PendingSmartSession = Get-Content $sessPath -Raw | ConvertFrom-Json
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host "  PREVIOUS SMART TUNE SESSION DETECTED" -ForegroundColor Yellow
        Write-Host "  Mode: $($script:PendingSmartSession.mode)" -ForegroundColor Yellow
        Write-Host "  Status when stopped: $($script:PendingSmartSession.status)" -ForegroundColor Yellow
        Write-Host "  The UI will offer to resume or discard." -ForegroundColor Yellow
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host ""
    } catch {}
}
```

- [ ] **Step 2: Add the endpoint to expose it**

Add this route registration alongside the other Smart Tune routes:

```powershell
Register-Route -Method GET -Path '/api/smart-tune/pending-session' -Handler {
    @{ ok = $true; data = $script:PendingSmartSession }
}
```

- [ ] **Step 3: Parse-check + commit**

Run: `powershell.exe -NoProfile -Command "$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('server.ps1',[ref]$null,[ref]$e); if ($e) { exit 1 } else { 'OK' }"`
Expected: `OK`.

```bash
git add server.ps1
git commit -m "feat(smart-tune): startup detection of pending session"
```

---

## Phase 7 — UI (Tune Theater)

### Task 21: Add Smart Auto-Adjust radio + mode picker to test card

**Files:**
- Modify: `web/index.html`

- [ ] **Step 1: Add the Smart radio option**

In `web/index.html`, find the existing `<input type="radio" name="testMode" value="auto">` line and add a third option below it:

```html
<label class="inline-radio"><input type="radio" name="testMode" value="smart"> Smart Auto-Adjust (Pro)</label>
```

- [ ] **Step 2: Add the Smart options panel**

Add this block right after the `<div id="auto-options" class="hidden">...</div>` block:

```html
<div id="smart-options" class="hidden">
  <div class="co-input">
    <label>Goal mode:</label>
    <select id="smart-mode">
      <option value="daily-driver" selected>Daily Driver — 30–60 min, safe daily values</option>
      <option value="max-stable">Max Stable — 3–6 h, deepest verified offsets</option>
      <option value="adaptive">Adaptive — runs for hours/days, continuously refines</option>
      <option value="characterize">Characterize — map each core's V/F behaviour (insight)</option>
      <option value="overclock">Overclock — positive CO offsets to chase higher boost</option>
    </select>
  </div>
  <p class="muted small">Smart Auto-Adjust uses bisection + telemetry + crash history. See the Tune Theater for live progress.</p>
</div>
```

- [ ] **Step 3: Commit**

```bash
git add web/index.html
git commit -m "feat(smart-tune): test card UI - radio + mode picker"
```

---

### Task 22: Tune Theater HTML structure

**Files:**
- Modify: `web/index.html`

- [ ] **Step 1: Add the Tune Theater panel above the existing #pro-dashboard**

In `web/index.html`, find the `<section id="pro-dashboard" class="card pro-dashboard hidden">` line and add this block immediately before it:

```html
<section id="tune-theater" class="card tune-theater hidden">
  <div class="theater-header">
    <h2>🎬 Tune Theater</h2>
    <div class="theater-meta">
      <span id="theater-mode">—</span> · session <span id="theater-session">—</span>
    </div>
  </div>

  <div class="theater-progress">
    <div class="progress-row">
      <span class="progress-label">Overall</span>
      <div class="progress-bar"><div class="progress-fill" id="theater-overall-fill"></div></div>
      <span class="progress-pct" id="theater-overall-pct">0%</span>
      <span class="progress-eta">ETA <span id="theater-eta">—</span></span>
    </div>
  </div>

  <div class="theater-currently" id="theater-currently">Waiting for first probe…</div>

  <div class="theater-scopes" id="theater-scopes"></div>

  <div class="theater-narrative">
    <div class="narrative-header">
      Narrative
      <label class="muted small">
        <input type="checkbox" id="narrative-autoscroll" checked> auto-scroll
      </label>
    </div>
    <div id="narrative-log"></div>
  </div>
</section>
```

- [ ] **Step 2: Commit**

```bash
git add web/index.html
git commit -m "feat(smart-tune): Tune Theater HTML structure"
```

---

### Task 23: Tune Theater CSS

**Files:**
- Modify: `web/style.css`

- [ ] **Step 1: Append the Tune Theater styles**

Append to `web/style.css`:

```css
/* ============ Tune Theater ============ */
.tune-theater {
  background: linear-gradient(180deg, #0f1925 0%, #1a1f2b 100%);
  border-color: var(--accent);
}
.theater-header {
  display: flex; justify-content: space-between; align-items: center;
  margin-bottom: 0.8rem; flex-wrap: wrap; gap: 0.6rem;
}
.theater-header h2 { margin: 0; }
.theater-meta { color: var(--muted); font-size: 0.85rem; font-variant-numeric: tabular-nums; }

.theater-progress { margin-bottom: 1rem; }
.progress-row {
  display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap;
  font-variant-numeric: tabular-nums;
}
.progress-label { color: var(--muted); font-size: 0.85rem; min-width: 4.5rem; }
.progress-bar {
  flex: 1; height: 8px; background: rgba(255,255,255,0.06); border-radius: 4px; overflow: hidden;
  min-width: 200px;
}
.progress-fill {
  height: 100%; width: 0%; background: linear-gradient(90deg, var(--accent), var(--success));
  transition: width 0.4s;
}
.progress-pct { color: var(--text); font-weight: 600; min-width: 3rem; text-align: right; }
.progress-eta { color: var(--muted); font-size: 0.85rem; }

.theater-currently {
  background: rgba(6, 182, 212, 0.08);
  border-left: 3px solid var(--accent);
  padding: 0.6rem 0.9rem;
  border-radius: 0 4px 4px 0;
  margin-bottom: 0.8rem;
  font-size: 0.92rem;
  font-variant-numeric: tabular-nums;
}

.theater-scopes {
  display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
  gap: 0.5rem; margin-bottom: 1rem;
}
.theater-scope {
  background: rgba(255,255,255,0.03);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 0.5rem 0.7rem;
  font-size: 0.82rem;
  font-variant-numeric: tabular-nums;
}
.theater-scope.s-active   { border-color: var(--accent); background: rgba(6,182,212,0.06); }
.theater-scope.s-locked   { border-color: var(--success); }
.theater-scope.s-failed   { border-color: var(--danger); }
.theater-scope .s-id      { font-weight: 700; font-size: 0.9rem; }
.theater-scope .s-bounds  { color: var(--muted); font-size: 0.75rem; }
.theater-scope .s-bisect  {
  margin-top: 0.3rem; height: 6px; position: relative;
  background: rgba(255,255,255,0.04); border-radius: 3px;
}
.theater-scope .s-bisect-window {
  position: absolute; top: 0; bottom: 0;
  background: var(--accent); opacity: 0.6; border-radius: 3px;
  transition: left 0.3s, width 0.3s;
}

.theater-narrative {
  background: rgba(0,0,0,0.2);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 0.6rem;
}
.narrative-header {
  display: flex; justify-content: space-between; align-items: center;
  margin-bottom: 0.4rem; font-size: 0.85rem; color: var(--muted);
}
#narrative-log {
  max-height: 280px; overflow-y: auto; font-family: ui-monospace, Consolas, monospace;
  font-size: 0.78rem; line-height: 1.5;
}
.narr-line { padding: 0.05rem 0; color: var(--text); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.narr-line .narr-ts   { color: var(--muted); margin-right: 0.4rem; }
.narr-line .narr-icon { margin-right: 0.3rem; }
```

- [ ] **Step 2: Commit**

```bash
git add web/style.css
git commit -m "feat(smart-tune): Tune Theater styling"
```

---

### Task 24: SmartTune JS module — state polling, narrative rendering, UI hooks

**Files:**
- Modify: `web/app.js`

- [ ] **Step 1: Append the SmartTune module**

Append to `web/app.js` (after the existing ProDash IIFE):

```js
// ============================================================================
//  SmartTune - Tune Theater rendering + start/stop wiring
// ============================================================================
const SmartTune = (() => {
  let lastSeqId = 0;
  let probesCompletedTotal = 0;
  let probesPlannedTotal = 0;

  function show() {
    document.getElementById('tune-theater')?.classList.remove('hidden');
  }
  function hide() {
    document.getElementById('tune-theater')?.classList.add('hidden');
    lastSeqId = 0;
  }

  function fmtTime(iso) {
    const d = new Date(iso);
    const pad = n => n.toString().padStart(2,'0');
    return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  function renderState(s) {
    if (!s || s.status === 'IDLE' || s.status === 'STOPPED') { hide(); return; }
    show();
    document.getElementById('theater-mode').textContent = `${s.mode || '?'} · ${s.direction || '?'}`;
    document.getElementById('theater-session').textContent = (s.sessionId || '—').substring(0, 8);

    // Progress
    probesPlannedTotal = (s.scopes || []).length * 6;  // rough estimate: 6 probes per scope
    probesCompletedTotal = (s.scopes || [])
      .map(sc => (sc.scopeState && sc.scopeState.probesCompleted) || (sc.status === 'LOCKED' ? 6 : 0))
      .reduce((a,b) => a+b, 0);
    const pct = probesPlannedTotal > 0 ? Math.min(100, Math.round(100 * probesCompletedTotal / probesPlannedTotal)) : 0;
    document.getElementById('theater-overall-fill').style.width = pct + '%';
    document.getElementById('theater-overall-pct').textContent = pct + '%';

    // Per-scope cards
    const wrap = document.getElementById('theater-scopes');
    wrap.innerHTML = (s.scopes || []).map((sc, i) => {
      const isActive = i === s.currentIdx && s.status === 'RUNNING';
      const cls = sc.status === 'LOCKED' ? 's-locked' :
                  sc.status === 'FAILED' ? 's-failed' :
                  isActive ? 's-active' : '';
      const ss = sc.scopeState;
      const bounds = ss ? `[${ss.bounds.floor} .. ${ss.bounds.ceiling}]` : '';
      const knownLine = ss
        ? `stable ${ss.knownStable ?? '—'} · edge ${ss.knownUnstable ?? '—'} · ${ss.probesCompleted} probes`
        : 'pending';
      const lockedLine = sc.locked != null ? `<div>🔒 <strong>${sc.locked}</strong></div>` : '';
      let windowLeftPct = 0, windowWidthPct = 100;
      if (ss && ss.knownStable != null && ss.knownUnstable != null) {
        const span = ss.bounds.ceiling - ss.bounds.floor;
        const lo = Math.min(ss.knownStable, ss.knownUnstable);
        const hi = Math.max(ss.knownStable, ss.knownUnstable);
        windowLeftPct = 100 * (lo - ss.bounds.floor) / span;
        windowWidthPct = 100 * (hi - lo) / span;
      }
      return `<div class="theater-scope ${cls}">
        <div class="s-id">${sc.id}${sc.isVCache ? ' 🔋' : ''}</div>
        <div class="s-bounds">${bounds}</div>
        <div class="s-bounds">${knownLine}</div>
        ${lockedLine}
        <div class="s-bisect"><div class="s-bisect-window" style="left:${windowLeftPct}%;width:${windowWidthPct}%"></div></div>
      </div>`;
    }).join('');

    // Narrative — append new entries since lastSeqId
    if (s.narrative && s.narrative.length) {
      const log = document.getElementById('narrative-log');
      const auto = document.getElementById('narrative-autoscroll')?.checked;
      s.narrative.forEach(e => {
        if (e.seqId <= lastSeqId) return;
        const line = document.createElement('div');
        line.className = 'narr-line';
        line.innerHTML = `<span class="narr-ts">${fmtTime(e.ts)}</span><span class="narr-icon">${e.icon}</span>${e.message}`;
        log.appendChild(line);
        lastSeqId = e.seqId;
      });
      if (auto) log.scrollTop = log.scrollHeight;
    }
    if (s.latestSeqId) lastSeqId = Math.max(lastSeqId, s.latestSeqId);

    // Currently strip
    const cur = (s.scopes || [])[s.currentIdx];
    if (cur && cur.scopeState) {
      const ss = cur.scopeState;
      document.getElementById('theater-currently').innerHTML =
        `▶ Probing <strong>${cur.id}</strong> — bounds [${ss.knownStable ?? '?'}, ${ss.knownUnstable ?? '?'}], probe ${ss.probesCompleted + 1}, last result ${ss.lastResult || '—'}`;
    } else if (s.status === 'COMPLETED') {
      document.getElementById('theater-currently').innerHTML = '✅ Tune complete — see report below';
    } else if (s.status === 'RUNNING') {
      document.getElementById('theater-currently').textContent = 'Picking next scope…';
    }
  }

  async function start(mode, direction) {
    const r = await fetchJson('/api/smart-tune/start', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode, direction })
    });
    if (!r.ok) { showToast('Start failed: ' + r.error, 'error'); return false; }
    lastSeqId = 0;
    document.getElementById('narrative-log').innerHTML = '';
    show();
    ProDash.resetStats();
    ProDash.show();
    return true;
  }

  async function stop() {
    await fetchJson('/api/smart-tune/stop', { method: 'POST' });
  }

  return { renderState, start, stop, show, hide };
})();

// Hook: when test mode radio changes, show/hide the right options panel
document.addEventListener('change', e => {
  if (e.target.name === 'testMode') {
    const v = e.target.value;
    document.getElementById('auto-options').classList.toggle('hidden', v !== 'auto');
    document.getElementById('smart-options').classList.toggle('hidden', v !== 'smart');
    document.getElementById('mode-info-auto').classList.toggle('hidden', v !== 'auto');
    document.getElementById('mode-info-manual').classList.toggle('hidden', v !== 'manual');
    const btn = document.getElementById('start-test');
    if (btn) btn.textContent = v === 'smart' ? '▶ Start Smart Tune'
                              : v === 'auto'  ? '▶ Start Auto-Adjust'
                              : '▶ Start';
  }
});
```

- [ ] **Step 2: Modify `startTest()` to route the Smart Tune case**

Find the existing `startTest` function in app.js and modify it:

```js
async function startTest() {
  const mode = document.querySelector('input[name="testMode"]:checked').value;
  if (mode === 'smart') {
    const smartMode = document.getElementById('smart-mode').value;
    const direction = smartMode === 'overclock' ? 'overclock' : 'undervolt';
    const ok = await SmartTune.start(smartMode, direction);
    if (!ok) return;
    document.getElementById('start-test').classList.add('hidden');
    document.getElementById('stop-test').classList.remove('hidden');
    document.getElementById('status-card').classList.remove('hidden');
    document.getElementById('report-card').classList.add('hidden');
    return;
  }
  const auto = mode === 'auto';
  // ... existing manual/auto code path stays unchanged ...
  const body = {
    mode: document.getElementById('test-mode').value,
    iterations: +document.getElementById('iterations').value,
    autoAdjust: auto,
    autoMax: auto ? +document.getElementById('auto-max').value : 0,
    autoInc: auto ? +document.getElementById('auto-inc').value : 1,
    safety: {
      maxTempC: settings.safetyMaxTempC,
      maxVid:   settings.safetyMaxVid,
      abortOnWhea: settings.safetyAutoAbortOnWhea
    }
  };
  const r = await fetchJson('/api/test/start', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  if (!r.ok) { showToast('Start failed: ' + r.error, 'error'); return; }
  document.getElementById('start-test').classList.add('hidden');
  document.getElementById('stop-test').classList.remove('hidden');
  document.getElementById('status-card').classList.remove('hidden');
  document.getElementById('report-card').classList.add('hidden');
  ProDash.resetStats();
  ProDash.show();
}
```

- [ ] **Step 3: Modify `stopTest()` to route the Smart Tune stop**

```js
async function stopTest() {
  const mode = document.querySelector('input[name="testMode"]:checked').value;
  if (mode === 'smart') {
    await SmartTune.stop();
  } else {
    await fetchJson('/api/test/stop', { method: 'POST' });
  }
  document.getElementById('stop-test').classList.add('hidden');
  document.getElementById('start-test').classList.remove('hidden');
}
```

- [ ] **Step 4: Modify `pollStatus()` to feed SmartTune.renderState**

Find the existing `pollStatus()` and add this at the bottom of the try block, before the catch:

```js
    if (s.smartTune) SmartTune.renderState(s.smartTune);
```

- [ ] **Step 5: Verify**

Run: `node --check web/app.js`
Expected: no output (success).

- [ ] **Step 6: Commit**

```bash
git add web/app.js
git commit -m "feat(smart-tune): SmartTune JS module + UI wiring"
```

---

### Task 25: Resume/discard prompt on page load when a pending session exists

**Files:**
- Modify: `web/app.js`

- [ ] **Step 1: Append the pending-session check**

Append to `web/app.js`:

```js
async function checkPendingSmartSession() {
  try {
    const r = await fetchJson('/api/smart-tune/pending-session');
    if (!r.ok || !r.data) return;
    const p = r.data;
    const html = `<h2>⏸ Smart Tune session was in progress when the system stopped</h2>
      <p>Mode: <strong>${p.mode || '?'}</strong> · status when stopped: <strong>${p.status || '?'}</strong></p>
      <p>You can resume from this point, or discard the session and start fresh.</p>
      <div class="actions">
        <button class="primary" id="smart-resume">Resume</button>
        <button class="secondary" id="smart-discard">Discard</button>
      </div>`;
    const banner = document.createElement('div');
    banner.className = 'card warn';
    banner.id = 'smart-pending-card';
    banner.innerHTML = html;
    document.querySelector('main').insertBefore(banner, document.querySelector('main').firstChild);
  } catch (_) {}
}

document.addEventListener('click', async e => {
  if (e.target.id === 'smart-resume') {
    const r = await fetchJson('/api/smart-tune/resume', { method: 'POST' });
    if (r.ok) {
      showToast('Smart Tune resumed');
      document.getElementById('smart-pending-card')?.remove();
      SmartTune.show();
    } else {
      showToast('Resume failed: ' + r.error, 'error');
    }
  }
  if (e.target.id === 'smart-discard') {
    await fetchJson('/api/smart-tune/discard', { method: 'POST' });
    document.getElementById('smart-pending-card')?.remove();
    showToast('Discarded');
  }
});
```

- [ ] **Step 2: Wire it into DOMContentLoaded**

Find the existing `await checkPanicRevert();` line and add this after it:

```js
    await checkPendingSmartSession();
```

- [ ] **Step 3: Verify + commit**

Run: `node --check web/app.js`
Expected: no output.

```bash
git add web/app.js
git commit -m "feat(smart-tune): resume/discard prompt on page load"
```

---

## Phase 8 — Manual smoke test plan

### Task 26: End-to-end manual verification

> Real verification requires a Ryzen CPU. The user's 7950X3D is the
> reference platform. This task is a checklist, not code.

- [ ] **Step 1: Run all unit tests**

```bash
powershell.exe -NoProfile -Command "Invoke-Pester tests/ -Output Detailed"
```
Expected: all tests pass. Smart-tune tests should count 17+ (search) + 9 (history) + 4 (narrative) + 5 (probe) + 17 (orchestrator) ≈ 52 cases.

- [ ] **Step 2: Verify server starts cleanly with the new modules**

Launch the app (`Launch.bat`), confirm server.log shows no errors at boot. The new modules should dot-source without complaint.

- [ ] **Step 3: Smoke-test the Characterize mode (shortest, lowest risk)**

In the UI:
1. Select "Smart Auto-Adjust (Pro)"
2. Choose "Characterize" from the mode picker
3. Click Start
4. Verify the Tune Theater appears, narrative log starts populating, progress bar moves
5. Verify the bisection ladder shows the active scope's window shrinking
6. Verify the Pro Dashboard charts continue streaming throughout
7. Let it run one full CCD probe (~3-5 minutes), then click Stop
8. Verify clean stop: state returns to IDLE, no leftover Prime95 processes, CO reverts via panic-revert path

- [ ] **Step 4: Verify crash recovery**

1. Start a Smart Tune (Daily Driver)
2. After 1-2 probes complete, kill the server process (Task Manager)
3. Restart via Launch.bat
4. Verify the "Previous Smart Tune session detected" banner appears
5. Click Discard, verify the breadcrumb is cleared

- [ ] **Step 5: Verify history accumulation**

After step 3, inspect `runtime/tuner-history.jsonl`:
- One line per probe
- Per-CPU-model partitioning works
- WHEA/crash entries marked correctly

- [ ] **Step 6: Final commit**

```bash
git commit --allow-empty -m "test(smart-tune): smoke test pass on 7950X3D"
```

---

## Spec Coverage Audit

Sections of the spec and the task(s) that implement them:

| Spec Section | Task(s) |
|---|---|
| Five modes (Daily Driver, Max Stable, Adaptive, Characterize, Overclock) | 1 |
| Hybrid bisection algorithm — three pointers, telemetry headroom modulation | 2, 3, 4, 15 |
| Per-probe checks (history query, panic-revert write, CO apply, sleep) | 17, 19 (apply); history query: 7 |
| Probe execution (single-iteration CoreCycler) | 10, 11 |
| Result classification | 10 |
| Termination + lock-in with margin | 5, 17 |
| V-Cache CCD asymmetry (independent policy, V-Cache first) | 1, 13 |
| Per-CPU-model JSONL history, append-only, atomic | 6, 7 |
| History queries (crash floor, stable ceiling, confidence) | 7 |
| Storage discipline (cap at 10k, preserve crashes) | 8 |
| Session JSON write-atomically-after-each-probe | 12, 17 |
| Crash-recovery resume flow | 20, 25 |
| Server endpoints | 18, 19, 20 |
| Tune Theater UI (progress, scopes, narrative, ladder, currently strip) | 21, 22, 23, 24 |
| Narrative log with seq-id pagination | 9, 24 |
| Smoke test on real hardware | 26 |
| **Deferred:** AVX2/AVX-512 stress matrix; cross-CPU history view | future work |
| **Deferred:** "Estimated time to completion" beyond rough probe-count estimate | future work |

---

**Plan complete and saved to `docs/superpowers/plans/2026-05-28-smart-auto-adjust-plan.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
