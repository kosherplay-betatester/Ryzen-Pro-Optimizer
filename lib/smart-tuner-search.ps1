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
