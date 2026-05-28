Set-StrictMode -Version Latest
. "$PSScriptRoot\logging.ps1"

# ============================================================================
# Safety Guard - watchdog that monitors telemetry + WHEA during Auto-Adjust
# runs and aborts the test the moment a configured limit is exceeded. The
# motivation: a remote-desktop tuning session that BSODs leaves the operator
# with no way to react, and a single bad CO step can ride the rails into a
# kernel panic before CoreCycler notices a soft error. This is the seatbelt.
#
# Design:
#   - Configured from /api/settings (maxTempC, maxVid, abortOnWhea)
#   - Sampled by the HTTP server's /api/status handler at 1Hz from telemetry
#   - Persists "panic-revert.json" before each CO step so a post-crash boot
#     can detect "we were mid-tune when something killed us"
#   - Counts violations - one transient blip can trigger a warning; a
#     sustained breach triggers an abort
# ============================================================================

# Defaults are conservative. AMD spec: Zen 4/5 daily VID <= 1.45V; thermal
# throttle on 7950X3D at ~89C, hard limit 95C.
$script:Safety = @{
    Active           = $false       # turned on by Enable-SafetyGuard, off by Disable-SafetyGuard
    MaxTempC         = 95
    MaxVid           = 1.45
    AbortOnWhea      = $true
    ConsecutiveBreach = @{}         # metric -> consecutive sample count over limit
    BreachThreshold  = 3            # samples in a row before we abort (avoids 1-frame spikes)
    Violations       = @()          # currently active violations (this snapshot)
    LastWarning      = $null
    LastAbort        = $null
    LastEvent        = $null
    AbortCount       = 0
    StepBackCount    = 0
    NewAbort         = $false       # set true once when an abort fires, cleared after first /api/status read
    OnAbort          = $null        # scriptblock invoked on abort - registered by server
    PanicFile        = $null
    StartedAt        = $null
    WheaBaseline     = 0
}

function Initialize-SafetyGuard {
    param([string]$RepoRoot)
    $script:Safety.PanicFile = Join-Path $RepoRoot 'runtime\panic-revert.json'
    # If a panic file exists from a previous run, surface it (server can show on startup)
    if (Test-Path $script:Safety.PanicFile) {
        try {
            $panic = Get-Content $script:Safety.PanicFile -Raw | ConvertFrom-Json
            Write-Log WARN "Panic-revert file found from previous run (capturedAt=$($panic.capturedAt)). Previous session may have crashed mid-tune."
        } catch {}
    }
}

function Set-SafetyLimits {
    param(
        [Nullable[int]]$MaxTempC = $null,
        [Nullable[double]]$MaxVid = $null,
        [Nullable[bool]]$AbortOnWhea = $null
    )
    if ($null -ne $MaxTempC)     { $script:Safety.MaxTempC = [int]$MaxTempC }
    if ($null -ne $MaxVid)       { $script:Safety.MaxVid = [double]$MaxVid }
    if ($null -ne $AbortOnWhea)  { $script:Safety.AbortOnWhea = [bool]$AbortOnWhea }
    Write-Log INFO "Safety limits: maxTemp=$($script:Safety.MaxTempC)C, maxVid=$($script:Safety.MaxVid)V, wheaAbort=$($script:Safety.AbortOnWhea)"
}

function Enable-SafetyGuard {
    param(
        [scriptblock]$OnAbort,
        [int]$WheaBaseline = 0
    )
    $script:Safety.Active = $true
    $script:Safety.OnAbort = $OnAbort
    $script:Safety.WheaBaseline = $WheaBaseline
    $script:Safety.ConsecutiveBreach = @{}
    $script:Safety.Violations = @()
    $script:Safety.LastWarning = $null
    $script:Safety.LastAbort = $null
    $script:Safety.LastEvent = "Guard armed at $(Get-Date -Format 'HH:mm:ss')"
    $script:Safety.AbortCount = 0
    $script:Safety.StepBackCount = 0
    $script:Safety.NewAbort = $false
    $script:Safety.StartedAt = (Get-Date)
    Write-Log INFO "Safety Guard ENABLED (maxTemp=$($script:Safety.MaxTempC)C, maxVid=$($script:Safety.MaxVid)V)"
}

function Disable-SafetyGuard {
    $script:Safety.Active = $false
    $script:Safety.OnAbort = $null
    $script:Safety.Violations = @()
    Write-Log INFO "Safety Guard DISABLED"
}

# Save current CO state to the panic file before a CO write. If the system
# BSODs mid-write, the next boot can read this file to see what we were doing.
function Save-PanicRevertState {
    param([int[]]$Values, [string]$Reason)
    if (-not $script:Safety.PanicFile) { return }
    try {
        @{
            capturedAt = (Get-Date -Format 'o')
            values = $Values
            reason = $Reason
            pid = $PID
        } | ConvertTo-Json -Depth 4 | Set-Content -Path $script:Safety.PanicFile
    } catch {
        Write-Log WARN "Panic file save failed: $($_.Exception.Message)"
    }
}

function Clear-PanicRevertState {
    if ($script:Safety.PanicFile -and (Test-Path $script:Safety.PanicFile)) {
        Remove-Item $script:Safety.PanicFile -Force -ErrorAction SilentlyContinue
    }
}

# Inspect a telemetry snapshot (and current WHEA count) for safety violations.
# Returns a list of violation objects. Stateful: tracks consecutive breaches
# so a sustained breach can escalate to abort.
function Inspect-SafetySnapshot {
    param($Snapshot, [int]$WheaCount)
    if (-not $script:Safety.Active -or $null -eq $Snapshot) {
        return @()
    }

    $violations = New-Object System.Collections.Generic.List[object]
    $maxTemp = $script:Safety.MaxTempC
    $maxVid  = $script:Safety.MaxVid

    # Package / CCD temp checks
    if ($null -ne $Snapshot.packageTemp -and $Snapshot.packageTemp -ge $maxTemp) {
        $violations.Add(@{ metric='Pkg Temp'; value=[double]$Snapshot.packageTemp; limit=$maxTemp; severity='abort' })
    }
    foreach ($c in @($Snapshot.ccdTemps)) {
        if ($c.tempC -ge $maxTemp) {
            $violations.Add(@{ metric="CCD$($c.ccd) Temp"; value=[double]$c.tempC; limit=$maxTemp; severity='abort' })
        }
    }
    # Per-core VID checks
    foreach ($core in @($Snapshot.cores)) {
        if ($null -ne $core.voltage -and $core.voltage -ge $maxVid) {
            $violations.Add(@{ metric="Core $($core.core) VID"; value=[double]$core.voltage; limit=$maxVid; severity='warning' })
        }
    }
    # WHEA delta during guarded run
    $wheaDelta = [Math]::Max(0, $WheaCount - $script:Safety.WheaBaseline)
    if ($script:Safety.AbortOnWhea -and $wheaDelta -gt 0) {
        $violations.Add(@{ metric='WHEA delta'; value=$wheaDelta; limit=0; severity='abort' })
    }

    $script:Safety.Violations = @($violations)

    # Track consecutive breaches per metric
    $abortNow = $false
    $now = Get-Date
    foreach ($v in $violations) {
        $key = $v.metric
        if ($v.severity -eq 'abort') {
            $cur = if ($script:Safety.ConsecutiveBreach.ContainsKey($key)) { $script:Safety.ConsecutiveBreach[$key] } else { 0 }
            $cur++
            $script:Safety.ConsecutiveBreach[$key] = $cur
            if ($cur -ge $script:Safety.BreachThreshold -or $v.metric -eq 'WHEA delta') {
                $abortNow = $true
                $script:Safety.LastEvent = "ABORT at $($now.ToString('HH:mm:ss')) - $($v.metric)=$([math]::Round($v.value,2)) limit=$($v.limit)"
                Write-Log ERROR "SAFETY ABORT: $($script:Safety.LastEvent)"
            } else {
                $script:Safety.LastWarning = $script:Safety.LastEvent = "WARN $cur/$($script:Safety.BreachThreshold) at $($now.ToString('HH:mm:ss')) - $($v.metric)=$([math]::Round($v.value,2)) limit=$($v.limit)"
                Write-Log WARN "Safety breach (consecutive=$cur): $($v.metric)=$($v.value) limit=$($v.limit)"
            }
        } elseif ($v.severity -eq 'warning') {
            $script:Safety.LastWarning = "WARN at $($now.ToString('HH:mm:ss')) - $($v.metric)=$([math]::Round($v.value,2)) over $($v.limit)"
            $script:Safety.LastEvent = $script:Safety.LastWarning
        }
    }

    # Decay counters for metrics no longer in violation
    $activeMetrics = $violations | Where-Object { $_.severity -eq 'abort' } | ForEach-Object { $_.metric }
    foreach ($k in @($script:Safety.ConsecutiveBreach.Keys)) {
        if ($activeMetrics -notcontains $k) { $script:Safety.ConsecutiveBreach.Remove($k) }
    }

    if ($abortNow) {
        $script:Safety.AbortCount++
        $script:Safety.LastAbort = $now.ToString('o')
        $script:Safety.NewAbort = $true
        if ($script:Safety.OnAbort) {
            try { & $script:Safety.OnAbort $violations } catch { Write-Log ERROR "Abort callback failed: $($_.Exception.Message)" }
        }
    }

    return $violations
}

function Get-SafetyState {
    $cur = $script:Safety
    $newAbort = $cur.NewAbort
    $cur.NewAbort = $false  # consume the edge-triggered flag
    @{
        active        = [bool]$cur.Active
        maxTempC      = $cur.MaxTempC
        maxVid        = $cur.MaxVid
        abortOnWhea   = $cur.AbortOnWhea
        violations    = @($cur.Violations)
        lastWarning   = $cur.LastWarning
        lastAbort     = $cur.LastAbort
        lastEvent     = $cur.LastEvent
        abortCount    = $cur.AbortCount
        stepBackCount = $cur.StepBackCount
        newAbort      = $newAbort
    }
}

function Increment-StepBack { $script:Safety.StepBackCount++ }
