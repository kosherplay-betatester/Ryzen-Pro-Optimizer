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
        direction        = [string]$Policy.direction   # 'undervolt' or 'overclock' - drives bisection sign
        bounds           = [PSCustomObject]@{ floor = [int]$floor; ceiling = [int]$ceiling }
        seedValue        = $SeedValue
        knownStable      = if ($null -ne $KnownStableHint) { [int]$KnownStableHint } else { $null }
        knownUnstable    = if ($null -ne $KnownCrashFloor) { [int]$KnownCrashFloor } else { $null }
        probesCompleted  = 0
        lastCandidate    = $null
        lastResult       = $null
        status           = 'pending'
    }
}

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

# Pure update: apply a probe result to a scope state. Returns a new
# PSCustomObject (immutable-style) so callers can keep the prior state.
function Update-ScopeFromResult {
    param(
        [Parameter(Mandatory)]$ScopeState,
        [Parameter(Mandatory)][int]$Candidate,
        [Parameter(Mandatory)][ValidateSet('PASS','FAIL_P95','FAIL_WHEA','ABORT_SAFETY','TIMEOUT','ABORT_CRASH')][string]$Result
    )
    # Direction encodes sign of "deeper" and "shallower":
    #   undervolt: deeper = more negative (smaller int); shallower = closer to zero
    #   overclock: deeper = more positive (larger int);  shallower = closer to zero
    $dir = if ($ScopeState.PSObject.Properties['direction']) { [string]$ScopeState.direction } else { 'undervolt' }
    $isUndervolt = $dir -ne 'overclock'

    $new = [PSCustomObject]@{
        scopeId         = $ScopeState.scopeId
        isVCache        = $ScopeState.isVCache
        direction       = $dir
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
            # "Deepest PASS" - undervolt: smallest int. overclock: largest int.
            $isDeeper = if ($isUndervolt) { $Candidate -lt $new.knownStable } else { $Candidate -gt $new.knownStable }
            if ($null -eq $new.knownStable -or $isDeeper) {
                $new.knownStable = $Candidate
            }
        }
        { $_ -in 'FAIL_P95','FAIL_WHEA','TIMEOUT','ABORT_CRASH' } {
            # "Shallowest FAIL" - undervolt: largest int (closest to zero from below).
            # overclock: smallest int (closest to zero from above).
            $isShallower = if ($isUndervolt) { $Candidate -gt $new.knownUnstable } else { $Candidate -lt $new.knownUnstable }
            if ($null -eq $new.knownUnstable -or $isShallower) {
                $new.knownUnstable = $Candidate
            }
        }
        'ABORT_SAFETY' {
            # No stability signal - mark one step toward zero (safer) as unstable.
            $shifted = if ($isUndervolt) { $Candidate + 1 } else { $Candidate - 1 }
            $isShallower = if ($isUndervolt) { $shifted -gt $new.knownUnstable } else { $shifted -lt $new.knownUnstable }
            if ($null -eq $new.knownUnstable -or $isShallower) {
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
