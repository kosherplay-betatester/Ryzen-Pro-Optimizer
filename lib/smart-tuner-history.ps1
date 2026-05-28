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
    $all = Read-HistoryEntries -Path $Path -CpuModel $CpuModel
    $entries = @($all | Where-Object {
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
    $all = Read-HistoryEntries -Path $Path -CpuModel $CpuModel
    $entries = @($all | Where-Object {
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
    $all = Read-HistoryEntries -Path $Path -CpuModel $CpuModel
    $entries = @($all | Where-Object {
        $_.scope -eq $Scope -and $_.value -eq $Value
    })
    $passes = @($entries | Where-Object { $_.result -eq 'PASS' }).Count
    $fails  = @($entries | Where-Object { $_.result -in 'FAIL_P95','FAIL_WHEA','ABORT_CRASH','TIMEOUT' }).Count
    $passes - $fails
}
