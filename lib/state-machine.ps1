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
