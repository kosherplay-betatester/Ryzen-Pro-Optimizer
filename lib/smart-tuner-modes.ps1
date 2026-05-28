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
