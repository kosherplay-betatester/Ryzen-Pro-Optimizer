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
