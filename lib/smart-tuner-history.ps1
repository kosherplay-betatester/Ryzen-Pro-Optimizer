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
