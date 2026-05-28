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
