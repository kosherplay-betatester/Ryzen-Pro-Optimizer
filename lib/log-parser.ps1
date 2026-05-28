# ============================================================================
#  log-parser.ps1 - Distil CoreCycler + Prime95 logs into a verdict
# ============================================================================
#  Used by  : server.ps1 (Build-Report) after a test completes
#  Reads    : corecycler/logs/CoreCycler_*.log  + corecycler/logs/Prime95_*.log
#
#  What we extract from CoreCycler's log:
#    - "Set to Core N"         - which core was being tested when
#    - "Iteration N/M"          - max iteration reached vs requested
#    - "Test completed in ..."  - total runtime
#    - "core_error|has thrown an error|core .* errored" - per-core failures
#    - "cores with an error so far: N" - running totals
#    - "cores with a WHEA error so far: N"
#
#  What we extract from Prime95's log:
#    - "FATAL ERROR | Rounding was | Hardware failure"  - belt and braces;
#      sometimes Prime95 errors don't make it into the CoreCycler log
#      cleanly, so we cross-check.
#
#  Verdict resolution: FAILED beats PASSED beats INCOMPLETE. If we can't
#  prove either pass or fail (test was stopped early, log truncated), we
#  call it INCOMPLETE - the UI shows that as the amber "stopped before
#  completion" verdict and avoids false claims of stability.
# ============================================================================
Set-StrictMode -Version Latest
. "$PSScriptRoot\logging.ps1"

function Read-CoreCyclerLog {
    param(
        [string]$CoreCyclerLogPath,
        [string]$Prime95LogPath,
        $CpuInfo,
        [int[]]$CurrentCoValues,
        [int]$IterationsRequested = 1
    )

    $report = [ordered]@{
        timestamp = (Get-Date -Format 'o')
        duration = $null
        iterationsCompleted = 0
        iterationsRequested = $IterationsRequested
        testType = 'PRIME95_SSE'
        coresTested = @()
        coresPassed = @()
        coresFailed = @()
        wheaEvents = @()
        verdict = 'UNKNOWN'
        coreCyclerLogPath = $CoreCyclerLogPath
        prime95LogPath = $Prime95LogPath
    }

    if (-not $CoreCyclerLogPath -or -not (Test-Path $CoreCyclerLogPath)) {
        $report.verdict = 'INCOMPLETE'
        return [PSCustomObject]$report
    }

    $lines = Get-Content -Path $CoreCyclerLogPath -ErrorAction SilentlyContinue
    if (-not $lines) {
        $report.verdict = 'INCOMPLETE'
        return [PSCustomObject]$report
    }

    $coreErrorLineIndexes = @()
    $currentCoreContextStack = @()  # Track the most recent "Set to Core N" seen for each error
    $maxIterSeen = 0
    $lastErrorCount = 0
    $lastWheaCount = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]

        if ($l -match 'stressTestProgram\s*=\s*(\w+)') { $report.testType = "$($Matches[1])_$($report.testType -replace '^[^_]*_','')" }
        if ($l -match 'Prime95.*mode\s*=\s*(\w+)') { $report.testType = "PRIME95_$($Matches[1])" }
        if ($l -match 'Iteration (\d+)/(\d+)') {
            $maxIterSeen = [Math]::Max($maxIterSeen, [int]$Matches[1])
            $report.iterationsRequested = [int]$Matches[2]
        }
        if ($l -match 'Test completed in (\d{2}h\s*\d{2}m\s*\d{2}s)') { $report.duration = $Matches[1] -replace '\s+',' ' }
        if ($l -match 'Set to Core (\d+)') {
            $core = [int]$Matches[1]
            if ($report.coresTested -notcontains $core) { $report.coresTested = $report.coresTested + $core }
            $currentCoreContextStack += @{ index = $i; core = $core }
        }
        if ($l -match 'cores with an error so far:\s*(\d+)') { $lastErrorCount = [int]$Matches[1] }
        if ($l -match 'cores with a WHEA error so far:\s*(\d+)') { $lastWheaCount = [int]$Matches[1] }

        # Detect per-core error event from the Event Log entries CoreCycler writes
        if ($l -match 'core_error|has thrown an error|core .* errored') {
            $coreErrorLineIndexes += $i
        }
    }
    $report.iterationsCompleted = $maxIterSeen

    # Walk back from each error line to find the most recent "Set to Core N"
    $errCores = New-Object System.Collections.Generic.List[int]
    foreach ($errIdx in $coreErrorLineIndexes) {
        for ($j = $errIdx; $j -ge 0; $j--) {
            if ($lines[$j] -match 'Set to Core (\d+)') {
                if (-not $errCores.Contains([int]$Matches[1])) { $errCores.Add([int]$Matches[1]) }
                break
            }
        }
    }
    $errCores = @($errCores | Sort-Object -Unique)

    # Check Prime95 log for FATAL ERROR / Rounding - count as error indicator
    $primeHasErrors = $false
    if ($Prime95LogPath -and (Test-Path $Prime95LogPath)) {
        $primeLines = Get-Content -Path $Prime95LogPath -ErrorAction SilentlyContinue
        if ($primeLines | Where-Object { $_ -match 'FATAL ERROR|Rounding was|Hardware failure' }) {
            $primeHasErrors = $true
        }
    }

    # Verdict logic
    $testedCount = @($report.coresTested).Count
    $errCount = @($errCores).Count
    $reqIter = [Math]::Max(1, [int]$report.iterationsRequested)
    if ($errCount -gt 0 -or $lastErrorCount -gt 0 -or $primeHasErrors -or $lastWheaCount -gt 0) {
        $report.verdict = 'FAILED'
    } elseif ($maxIterSeen -ge $reqIter -and $testedCount -gt 0) {
        $report.verdict = 'PASSED'
    } else {
        $report.verdict = 'INCOMPLETE'
    }

    # Per-core failure attribution
    $coVals = @($CurrentCoValues)
    foreach ($c in $errCores) {
        $ccd = if ($CpuInfo -and $CpuInfo.IsDualCcd) {
            [int]([Math]::Floor($c / $CpuInfo.CoresPerCcd))
        } else { 0 }
        $isVCache = $CpuInfo -and ($null -ne $CpuInfo.VCacheCcdIndex) -and ($CpuInfo.VCacheCcdIndex -eq $ccd)
        $ccdLabel = if (-not $CpuInfo -or -not $CpuInfo.IsDualCcd) { 'CCD0' }
                    elseif ($isVCache) { "CCD$ccd (V-Cache)" }
                    else { "CCD$ccd (Standard)" }
        $report.coresFailed += [PSCustomObject]@{
            core = $c
            ccd = $ccd
            ccdLabel = $ccdLabel
            coAtFailure = if ($coVals.Count -gt 0 -and $c -lt $coVals.Count) { $coVals[$c] } else { $null }
            errorType = 'Stress test error'
        }
    }
    $report.coresPassed = @(@($report.coresTested) | Where-Object { $errCores -notcontains $_ })

    [PSCustomObject]$report
}
