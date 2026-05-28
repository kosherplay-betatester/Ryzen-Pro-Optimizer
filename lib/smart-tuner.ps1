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
    $result = & $ProbeFn
    Update-ScopeFromResult -ScopeState $ScopeState -Candidate $candidate -Result $result
}
