# ============================================================================
#  state-machine.ps1 - The 6-state run-state machine
# ============================================================================
#  Used by  : server.ps1 (every test-related endpoint reads/writes state)
#
#                IDLE  ─────► APPLYING_CO  ─────► IDLE
#                  │
#                  └────────► TESTING ─┬─► STOPPING ─► REPORTING ─► IDLE
#                                      └─► REPORTING ─► IDLE
#                  (any) ───► ERROR ───► IDLE
#
#  Why a state machine and not ad-hoc flags: a stress test, CO apply,
#  and the report viewer can't safely overlap. Codifying the legal
#  transitions makes invalid combinations throw instead of silently
#  corrupting the run (e.g. starting a test while another is stopping).
#
#  -Force on Set-CurrentState bypasses validation - used by panic paths
#  (Esc reset, safety guard abort) where we always want IDLE/REPORTING
#  reachable regardless of current state. Don't sprinkle -Force around.
# ============================================================================
Set-StrictMode -Version Latest
. "$PSScriptRoot\logging.ps1"

# Allowed states: IDLE, APPLYING_CO, TESTING, STOPPING, REPORTING, ERROR
$script:State = 'IDLE'
$script:StateData = @{}

$script:ValidTransitions = @{
    'IDLE'        = @('APPLYING_CO','TESTING','ERROR')
    'APPLYING_CO' = @('IDLE','TESTING','ERROR')
    'TESTING'     = @('STOPPING','REPORTING','ERROR')
    'STOPPING'    = @('REPORTING','IDLE','ERROR')
    'REPORTING'   = @('IDLE','ERROR')
    'ERROR'       = @('IDLE')
}

function Get-CurrentState {
    @{ state = $script:State; data = $script:StateData }
}

function Set-CurrentState {
    param(
        [Parameter(Mandatory)][string]$NewState,
        $Data = @{},
        [switch]$Force
    )
    # IDLE is always reachable (panic/reset). Force allows any transition.
    if (-not $Force -and $NewState -ne 'IDLE' -and $NewState -ne $script:State) {
        $allowed = $script:ValidTransitions[$script:State]
        if (-not $allowed -or ($allowed -notcontains $NewState)) {
            throw "Invalid state transition: $($script:State) -> $NewState"
        }
    }
    Write-Log INFO "State: $($script:State) -> $NewState"
    $script:State = $NewState
    if ($Data) { $script:StateData = $Data }
}

function Reset-StateMachine {
    $script:State = 'IDLE'
    $script:StateData = @{}
}
