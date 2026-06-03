# ============================================================================
#  server.ps1 - Ryzen Pro Optimizer entry point and HTTP server
# ============================================================================
#  Spawned by: Launch.bat (after admin elevation + installer check)
#  Runs until: Ctrl+C in the console, the console window closes, the
#              browser sends POST /api/shutdown, or (opt-in only) the
#              heartbeat watchdog detects a closed tab.
#
#  Responsibilities:
#    1. Boot-time checks: admin, CPU detected, LHM DLL is the .NET-
#       Framework-compatible build (self-heals if not), CoreCycler
#       installed, PawnIO driver registered.
#    2. Read launch CO snapshot so we always know what to revert to.
#    3. Surface any pending panic-revert breadcrumb left by a previous
#       crashed session.
#    4. Register all /api/* routes (this file is the API contract).
#    5. Drive the HTTP listener loop with a per-second tick callback
#       that handles the (opt-in) heartbeat watchdog and shutdown
#       requests.
#    6. On exit: revert CO to the launch snapshot, stop the WHEA
#       watcher, close telemetry, log "Server stopped".
#
#  Module load order matters: logging must come first (everything else
#  uses Write-Log); router before http-server (the server consumes the
#  route table); state-machine before corecycler-runner (the runner
#  drives state transitions).
# ============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# App version. Bumped manually per release; surfaced via /api/version
# and shown in the UI footer. Keep in sync with CHANGELOG.md.
$script:AppVersion = '0.8.2'

# Project root
$RepoRoot = $PSScriptRoot

# Load libraries
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\router.ps1"
. "$PSScriptRoot\lib\http-server.ps1"
. "$PSScriptRoot\lib\cpu-detect.ps1"
. "$PSScriptRoot\lib\co-reader-writer.ps1"
. "$PSScriptRoot\lib\profile-store.ps1"
. "$PSScriptRoot\lib\telemetry-poller.ps1"
. "$PSScriptRoot\lib\state-machine.ps1"
. "$PSScriptRoot\lib\corecycler-runner.ps1"
. "$PSScriptRoot\lib\log-parser.ps1"
. "$PSScriptRoot\lib\smart-suggestions.ps1"
. "$PSScriptRoot\lib\whea-watcher.ps1"
. "$PSScriptRoot\lib\safety-guard.ps1"
. "$PSScriptRoot\lib\smart-tuner-modes.ps1"
. "$PSScriptRoot\lib\smart-tuner-search.ps1"
. "$PSScriptRoot\lib\smart-tuner-history.ps1"
. "$PSScriptRoot\lib\smart-tuner-narrative.ps1"
. "$PSScriptRoot\lib\smart-tuner.ps1"

# Admin check (CO writes require it)
$isAdmin = (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ''
    Write-Host 'ERROR: Ryzen Pro Optimizer must run as administrator.' -ForegroundColor Red
    Write-Host 'Right-click Launch.bat and Run as Administrator (or just use Launch.bat - it self-elevates).'
    Write-Host ''
    Read-Host 'Press Enter to exit'
    exit 1
}

# Detect CPU
$cpu = Get-CpuInfo
Write-Log INFO "Detected CPU: $($cpu.Name) ($($cpu.Cores) cores, $(if ($cpu.IsDualCcd) {'dual'} else {'single'}) CCD)"

# Initialize profile store
Initialize-ProfileStore -RepoRoot $RepoRoot

# Self-heal incompatible LibreHardwareMonitor DLL before initialising telemetry.
# Recent LHM releases ship a .NET 10 build that Windows PowerShell 5.1 (.NET
# Framework 4.x) cannot load - we detect that and trigger the installer to
# replace it with the net472 build from NuGet.
function Test-VendorLhmCompatible {
    $dll = Join-Path $RepoRoot 'vendor\LibreHardwareMonitorLib.dll'
    if (-not (Test-Path $dll)) { return $false }
    try {
        $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($dll))
        if ($text -match '\.NETCoreApp,Version=v\d') { return $false }
        return $true
    } catch { return $false }
}
if (-not (Test-VendorLhmCompatible)) {
    Write-Log WARN "Vendor LibreHardwareMonitorLib.dll targets .NET Core (incompatible with PS 5.1) - reinstalling..."
    Write-Host ""
    Write-Host "Replacing incompatible LibreHardwareMonitor build..." -ForegroundColor Yellow
    try {
        & "$PSScriptRoot\installer.ps1"
    } catch {
        Write-Log ERROR "Self-heal installer run failed: $($_.Exception.Message)"
    }
}

# Initialize telemetry (best effort)
$telemetryReady = Initialize-Telemetry -RepoRoot $RepoRoot

# Initialize CoreCycler runner (best effort)
$runnerReady = $false
try {
    Initialize-CoreCyclerRunner -RepoRoot $RepoRoot
    $runnerReady = $true
} catch {
    Write-Log WARN "CoreCycler runner not ready: $($_.Exception.Message)"
}

# Last report cache
$script:LastReport = $null

# Tracks whether the most recent CO write actually took effect at the SMU.
# $null = unknown (no write attempted yet this session)
# $true = last write verified by read-back
# $false = SMU silently ignored - the strongest signal we have that PBO +
#         Curve Optimizer aren't enabled in BIOS. The UI surfaces a
#         setup-help card in that case.
$script:LastWriteStuck = $null
$script:LastWriteMismatches = @()

# Heartbeat tracking: when browser stops pinging, server reverts CO and exits.
# DISABLED BY DEFAULT - Chrome's memory saver / tab discard / RDP disconnects
# would otherwise kill the service mid-test. User must opt in via UI checkbox.
# When opted-in, the timeout is generous (3 minutes) so brief network blips are tolerated.
$script:LastHeartbeat = [DateTime]::Now
$script:ShutdownRequested = $false
$script:HeartbeatTimeoutSeconds = 180
$script:HeartbeatEnabled = $false

# Initialize WHEA Bodyguard (best effort; needs admin)
Initialize-WheaWatcher -RepoRoot $RepoRoot
$wheaActive = Start-WheaWatcher

# Initialize Safety Guard (configured via /api/settings; armed when auto-tune starts)
Initialize-SafetyGuard -RepoRoot $RepoRoot

# Surface a panic-revert prompt if the previous run left one behind.
# This file is created before every CO write during a guarded test; its
# presence on startup means the system likely crashed mid-tune.
$script:PendingPanicRevert = $null
$panicPath = Join-Path $RepoRoot 'runtime\panic-revert.json'
if (Test-Path $panicPath) {
    try {
        $script:PendingPanicRevert = Get-Content $panicPath -Raw | ConvertFrom-Json
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host "  PREVIOUS SESSION CRASH DETECTED (panic-revert.json found)" -ForegroundColor Yellow
        Write-Host "  Reason: $($script:PendingPanicRevert.reason)" -ForegroundColor Yellow
        Write-Host "  CO at crash: $($script:PendingPanicRevert.values -join ',')" -ForegroundColor Yellow
        Write-Host "  The UI will offer to revert to safer values." -ForegroundColor Yellow
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host ""
    } catch {
        # Don't swallow silently - a corrupted panic-revert file is the
        # exact case this code is meant to handle, and silent failure
        # means the user never sees the recovery prompt.
        Write-Log WARN "Panic-revert breadcrumb is unreadable: $($_.Exception.Message). Discarding so the next test can start cleanly."
        try { Remove-Item $panicPath -Force -ErrorAction SilentlyContinue } catch {}
    }
}

$script:PendingSmartSession = $null
$sessPath = Join-Path $RepoRoot 'runtime\tuner-session.json'
if (Test-Path $sessPath) {
    try {
        $script:PendingSmartSession = Get-Content $sessPath -Raw | ConvertFrom-Json
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host "  PREVIOUS SMART TUNE SESSION DETECTED" -ForegroundColor Yellow
        Write-Host "  Mode: $($script:PendingSmartSession.mode)" -ForegroundColor Yellow
        Write-Host "  Status when stopped: $($script:PendingSmartSession.status)" -ForegroundColor Yellow
        Write-Host "  The UI will offer to resume or discard." -ForegroundColor Yellow
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host ""
    } catch {
        # See panic-revert catch above. Same reasoning: a truncated
        # tuner-session.json (mid-write crash) is the recovery case
        # itself - log it and discard so resume options stay clean.
        Write-Log WARN "Pending Smart Tune session JSON is unreadable: $($_.Exception.Message). Discarding."
        try { Remove-Item $sessPath -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# Graceful shutdown: revert CO, stop test, close listener
function Invoke-GracefulShutdown {
    # Idempotent: the tick callback fires from two places (inside the
    # async WaitOne poll loop AND after each request dispatch). Without
    # this early-return, a rapid request burst that happens to coincide
    # with a heartbeat timeout could invoke this twice, doing the CO
    # revert and Stop-CoreCyclerRun work redundantly.
    if ($script:ShutdownRequested) { return }
    $script:ShutdownRequested = $true
    Write-Log INFO "Graceful shutdown initiated"
    Write-Host ""
    Write-Host "Shutting down - reverting CO and cleaning up..." -ForegroundColor Yellow

    # If a test is running, stop it
    if ($runnerReady -and (Test-CoreCyclerRunning)) {
        try { Stop-CoreCyclerRun } catch { Write-Log WARN "Stop runner failed: $($_.Exception.Message)" }
    }

    # Revert CO to launch values (or zero if no snapshot)
    if ($coReady) {
        try {
            if ($null -ne $launchSnapshot) {
                Set-AllCoreCo -Values $launchSnapshot
                Write-Host "CO reverted to launch values: $($launchSnapshot -join ',')" -ForegroundColor Green
            } else {
                Reset-AllCoreCo -CoreCount $cpu.Cores
                Write-Host "CO reset to 0 (no launch snapshot was available)" -ForegroundColor Yellow
            }
        } catch {
            Write-Log ERROR "CO revert failed: $($_.Exception.Message)"
            Write-Host "WARNING: Failed to revert CO. Reboot to restore BIOS values." -ForegroundColor Red
        }
    }

}

# Initialize CO tool (best effort - server can still run if missing, just shows error)
$coReady = $false
$launchSnapshot = $null
if ($cpu.SupportsCurveOptimizer) {
    try {
        Initialize-CoTool -RepoRoot $RepoRoot
        $launchSnapshot = Get-AllCoreCo -CoreCount $cpu.Cores
        $coReady = $true
        $snapPath = Join-Path $RepoRoot 'runtime\launch-snapshot.json'
        @{ values = $launchSnapshot; capturedAt = (Get-Date -Format 'o'); cpuModel = $cpu.Name } |
            ConvertTo-Json -Depth 4 | Set-Content -Path $snapPath
        Write-Log INFO "Launch snapshot captured: $($launchSnapshot -join ',')"
    } catch {
        Write-Log WARN "CO tool init failed: $($_.Exception.Message). UI will show an error."
    }
}

# ----- Routes -----

Register-Route -Method GET -Path '/api/ping' -Handler {
    @{ ok = $true; data = @{ message = 'pong'; time = (Get-Date -Format 'o') } }
}

Register-Route -Method GET -Path '/api/cpu' -Handler {
    @{ ok = $true; data = $cpu }
}

Register-Route -Method GET -Path '/api/co/current' -Handler {
    if (-not $coReady) { return @{ ok = $false; error = 'CO tool not initialized - run Install.bat' } }
    @{ ok = $true; data = (Get-AllCoreCo -CoreCount $cpu.Cores) }
}

Register-Route -Method GET -Path '/api/co/launch' -Handler {
    @{ ok = $true; data = $launchSnapshot }
}

Register-Route -Method POST -Path '/api/co' -Handler {
    param($ctx, $params)
    if (-not $coReady) { return @{ ok = $false; error = 'CO tool not initialized' } }
    $body = Read-JsonBody -Context $ctx
    if (-not $body -or -not $body.mode) { return @{ ok = $false; error = 'mode required' } }

    $values = New-Object 'int[]' $cpu.Cores
    switch ($body.mode) {
        'all-cores' {
            $v = [int]$body.values.all
            for ($i = 0; $i -lt $cpu.Cores; $i++) { $values[$i] = $v }
        }
        'per-ccd' {
            for ($c = 0; $c -lt $cpu.CcdCount; $c++) {
                $ccdVal = [int]$body.values."ccd$c"
                for ($i = 0; $i -lt $cpu.CoresPerCcd; $i++) {
                    $values[($c * $cpu.CoresPerCcd) + $i] = $ccdVal
                }
            }
        }
        'per-core' {
            for ($i = 0; $i -lt $cpu.Cores; $i++) {
                $values[$i] = [int]$body.values."$i"
            }
        }
        default { return @{ ok = $false; error = "Unknown mode: $($body.mode)" } }
    }

    try {
        # Breadcrumb so a BSOD mid-apply is recoverable on next boot
        Save-PanicRevertState -Values $values -Reason "Manual /api/co apply ($($body.mode))"
        Set-AllCoreCo -Values $values
        Clear-PanicRevertState
        # Read-back verification: if the SMU silently ignored the write
        # (PBO/CO not enabled in BIOS), surface that immediately.
        $verify = Test-CoWritesStuck -Wanted $values -CoreCount $cpu.Cores
        $script:LastWriteStuck      = $verify.stuck
        $script:LastWriteMismatches = $verify.mismatches
        if ($verify.stuck -eq $false) {
            Write-Log WARN "CO write did NOT stick - $($verify.mismatches.Count) cores still at BIOS values. PBO/CO likely disabled in BIOS."
        }
        @{ ok = $true; data = @{
            applied      = $values
            writesStuck  = $verify.stuck
            mismatches   = $verify.mismatches
        } }
    } catch {
        @{ ok = $false; error = $_.Exception.Message }
    }
}

Register-Route -Method POST -Path '/api/reset-co' -Handler {
    if (-not $coReady) { return @{ ok = $false; error = 'CO tool not initialized' } }
    try {
        Reset-AllCoreCo -CoreCount $cpu.Cores
        $zeros = New-Object 'int[]' $cpu.Cores
        $verify = Test-CoWritesStuck -Wanted $zeros -CoreCount $cpu.Cores
        $script:LastWriteStuck      = $verify.stuck
        $script:LastWriteMismatches = $verify.mismatches
        @{ ok = $true; data = @{ reset = $true; writesStuck = $verify.stuck } }
    } catch {
        @{ ok = $false; error = $_.Exception.Message }
    }
}

Register-Route -Method POST -Path '/api/co/revert' -Handler {
    if (-not $coReady) { return @{ ok = $false; error = 'CO tool not initialized' } }
    if ($null -eq $launchSnapshot) { return @{ ok = $false; error = 'No launch snapshot' } }
    try {
        Set-AllCoreCo -Values $launchSnapshot
        $verify = Test-CoWritesStuck -Wanted $launchSnapshot -CoreCount $cpu.Cores
        $script:LastWriteStuck      = $verify.stuck
        $script:LastWriteMismatches = $verify.mismatches
        @{ ok = $true; data = @{ reverted = $launchSnapshot; writesStuck = $verify.stuck } }
    } catch {
        @{ ok = $false; error = $_.Exception.Message }
    }
}

Register-Route -Method GET -Path '/api/profiles' -Handler {
    @{ ok = $true; data = (Get-ProfileList) }
}

Register-Route -Method POST -Path '/api/profiles' -Handler {
    param($ctx, $params)
    $body = Read-JsonBody -Context $ctx
    if (-not $body -or -not $body.name -or -not $body.mode) { return @{ ok = $false; error = 'name and mode required' } }
    try {
        $p = Save-CoProfile -Name $body.name -Mode $body.mode -Values $body.values `
            -CpuModel $cpu.Name -CoreCount $cpu.Cores -CcdCount $cpu.CcdCount `
            -Notes ($(if ($null -ne $body.PSObject.Properties['notes']) { $body.notes } else { '' }))
        @{ ok = $true; data = $p }
    } catch {
        @{ ok = $false; error = $_.Exception.Message }
    }
}

Register-Route -Method DELETE -Path '/api/profiles/{name}' -Handler {
    param($ctx, $params)
    $removed = Remove-CoProfile -Name $params.name
    @{ ok = $true; data = @{ removed = $removed } }
}

Register-Route -Method POST -Path '/api/profiles/{name}/apply' -Handler {
    param($ctx, $params)
    if (-not $coReady) { return @{ ok = $false; error = 'CO tool not initialized' } }
    $p = Get-ProfileByName -Name $params.name
    if (-not $p) { return @{ ok = $false; error = 'Profile not found' } }
    try {
        $vals = ConvertTo-CoreArray -Profile $p -CoreCount $cpu.Cores -CcdCount $cpu.CcdCount
        Set-AllCoreCo -Values $vals
        @{ ok = $true; data = @{ applied = $vals } }
    } catch {
        @{ ok = $false; error = $_.Exception.Message }
    }
}

Register-Route -Method GET -Path '/api/telemetry' -Handler {
    # Wrapped because Read-TelemetrySnapshot drives LHM sensor enumeration,
    # and an LHM sensor stuck in a bad state (driver hiccup, hardware
    # contention with CoreCycler during a tune, etc.) historically left
    # the response hanging - Chrome would RST the TCP connection after
    # a few seconds, the polling loop client-side would log
    # ERR_CONNECTION_RESET on a 1s cadence, and the only fix was a
    # server restart. Catching here turns a hang/crash into a clean
    # JSON error response that the UI can render and recover from.
    if (-not (Test-TelemetryAvailable)) { return @{ ok = $false; error = 'Telemetry unavailable' } }
    try {
        @{ ok = $true; data = (Read-TelemetrySnapshot) }
    } catch {
        Write-Log WARN "/api/telemetry handler failed (LHM hiccup?): [$($_.Exception.GetType().FullName)] $($_.Exception.Message)"
        @{ ok = $false; error = "Telemetry read failed: $($_.Exception.Message)" }
    }
}

Register-Route -Method GET -Path '/api/telemetry/history' -Handler {
    try {
        @{ ok = $true; data = (Get-TelemetryHistory) }
    } catch {
        Write-Log WARN "/api/telemetry/history failed: $($_.Exception.Message)"
        @{ ok = $false; error = "History read failed: $($_.Exception.Message)" }
    }
}

Register-Route -Method GET -Path '/api/telemetry/peaks' -Handler {
    try {
        @{ ok = $true; data = (Get-Peaks) }
    } catch {
        Write-Log WARN "/api/telemetry/peaks failed: $($_.Exception.Message)"
        @{ ok = $false; error = "Peaks read failed: $($_.Exception.Message)" }
    }
}

Register-Route -Method POST -Path '/api/test/start' -Handler {
    param($ctx, $params)
    if (-not $runnerReady) { return @{ ok = $false; error = 'CoreCycler not installed - run Install.bat' } }
    $cur = (Get-CurrentState).state
    if ($cur -ne 'IDLE' -and $cur -ne 'REPORTING') {
        return @{ ok = $false; error = "Cannot start test - current state $cur" }
    }
    $body = Read-JsonBody -Context $ctx
    if (-not $body) { return @{ ok = $false; error = 'Body required' } }

    $iterations = if ($body.PSObject.Properties['iterations']) { [int]$body.iterations } else { 1 }
    $mode = if ($body.PSObject.Properties['mode']) { [string]$body.mode } else { 'SSE' }
    $auto = $false
    if ($body.PSObject.Properties['autoAdjust']) { $auto = [bool]$body.autoAdjust }

    $autoMax = 0; $autoInc = 1; $autoStart = $null
    if ($auto) {
        if ($body.PSObject.Properties['autoMax']) { $autoMax = [int]$body.autoMax }
        if ($body.PSObject.Properties['autoInc']) { $autoInc = [int]$body.autoInc }
        if ($coReady) {
            # Snapshot whatever the user had set BEFORE we reset, so they
            # can roll back to it via the auto-saved profile.
            $preTune = Get-AllCoreCo -CoreCount $cpu.Cores
            try {
                Save-PreTuneSnapshot -Process 'auto-adjust' -CurrentValues $preTune `
                    -CpuModel $cpu.Name -CcdCount $cpu.CcdCount | Out-Null
            } catch { Write-Log WARN "Pre-Auto-Adjust snapshot failed: $($_.Exception.Message)" }
            # Reset SMU to launch (BIOS) values before Auto-Adjust kicks in,
            # so the tune always starts from a known-safe baseline regardless
            # of what the user had manually set during this session. The
            # auto-saved profile above lets them get their tuned-state back
            # later if they want it.
            if ($null -ne $launchSnapshot) {
                try {
                    Set-AllCoreCo -Values $launchSnapshot
                    Write-Log INFO "Auto-Adjust: SMU reset to launch (BIOS) values before starting test"
                } catch {
                    Write-Log WARN "Pre-Auto-Adjust BIOS reset failed (continuing): $($_.Exception.Message)"
                }
            }
            $autoStart = Get-AllCoreCo -CoreCount $cpu.Cores
        }
    }

    # Pull per-run safety overrides (UI passes settings.safety on each start)
    if ($body.PSObject.Properties['safety'] -and $body.safety) {
        $s = $body.safety
        $maxT = if ($s.PSObject.Properties['maxTempC']) { [int]$s.maxTempC } else { $null }
        $maxV = if ($s.PSObject.Properties['maxVid']) { [double]$s.maxVid } else { $null }
        $aw   = if ($s.PSObject.Properties['abortOnWhea']) { [bool]$s.abortOnWhea } else { $null }
        Set-SafetyLimits -MaxTempC $maxT -MaxVid $maxV -AbortOnWhea $aw
    }

    $coresToTest = $null
    if ($body.PSObject.Properties['coresToTest'] -and $body.coresToTest) {
        $coresToTest = @($body.coresToTest | ForEach-Object { [int]$_ })
    }

    try {
        # Persist intended starting values BEFORE we kick off the test, so a
        # crash during config write / spawn leaves the panic-revert breadcrumb.
        if ($coReady -and $auto -and $autoStart) {
            Save-PanicRevertState -Values $autoStart -Reason "Auto-Adjust start (mode=$mode, max=$autoMax, inc=$autoInc)"
        }

        $cfg = New-CoreCyclerConfig -RepoRoot $RepoRoot `
            -StressTestProgram 'PRIME95' -Mode $mode -MaxIterations $iterations `
            -CoresToTest $coresToTest -TotalCores $cpu.Cores `
            -EnableAutomaticAdjustment $auto -AutoStartValues $autoStart `
            -AutoMaxValue $autoMax -AutoIncrementBy $autoInc

        Start-CoreCyclerRun -ConfigPath $cfg
        Start-PeakTracking

        # Arm Safety Guard on Auto-Adjust runs. Abort callback stops the test
        # and steps every core back one increment toward neutral. We use
        # .GetNewClosure() so the scriptblock captures $autoInc, $cpu, $coReady
        # at definition time - the handler scope is gone by the time the
        # callback fires from a future /api/status tick.
        if ($auto) {
            $wheaCount = @(Get-WheaEvents).Count
            $autoIncForCallback = $autoInc
            $cpuForCallback = $cpu
            $coReadyForCallback = $coReady
            $abortCallback = {
                param($violations)
                Write-Log ERROR "Safety abort callback firing - stopping test and stepping cores back"
                try { Stop-CoreCyclerRun } catch {}
                try { Stop-PeakTracking } catch {}
                if ($coReadyForCallback) {
                    try {
                        $cur = Get-AllCoreCo -CoreCount $cpuForCallback.Cores
                        $safer = New-Object 'int[]' $cur.Count
                        for ($i = 0; $i -lt $cur.Count; $i++) {
                            $v = $cur[$i]
                            if ($v -lt 0)     { $safer[$i] = [Math]::Min(0, $v + $autoIncForCallback) }
                            elseif ($v -gt 0) { $safer[$i] = [Math]::Max(0, $v - $autoIncForCallback) }
                            else              { $safer[$i] = 0 }
                        }
                        $reason = if (@($violations).Count -gt 0) { "Safety auto step-back: $($violations[0].metric)" } else { 'Safety auto step-back' }
                        Save-PanicRevertState -Values $safer -Reason $reason
                        Set-AllCoreCo -Values $safer
                        Increment-StepBack
                        Write-Log INFO "Stepped back to: $($safer -join ',')"
                    } catch { Write-Log ERROR "Step-back failed: $($_.Exception.Message)" }
                }
                try { Build-Report } catch {}
                try { Set-CurrentState -NewState 'REPORTING' -Force } catch {}
            }.GetNewClosure()
            Enable-SafetyGuard -WheaBaseline $wheaCount -OnAbort $abortCallback
        }

        Set-CurrentState -NewState 'TESTING' -Data @{
            startedAt = (Get-Date -Format 'o')
            mode = $mode
            iterations = $iterations
            autoAdjust = $auto
            coresToTest = $coresToTest
        }
        $script:LastReport = $null
        @{ ok = $true; data = (Get-CurrentState) }
    } catch {
        Write-Log ERROR "Test start failed: $($_.Exception.Message)"
        @{ ok = $false; error = $_.Exception.Message }
    }
}

Register-Route -Method POST -Path '/api/test/stop' -Handler {
    $cur = (Get-CurrentState).state
    if ($cur -ne 'TESTING') { return @{ ok = $false; error = "Not testing (state=$cur)" } }
    try {
        Set-CurrentState -NewState 'STOPPING'
        Stop-CoreCyclerRun
        Stop-PeakTracking
        Disable-SafetyGuard
        Clear-PanicRevertState
        # Try to build the report from whatever we have
        try { Build-Report } catch { Write-Log WARN "Build-Report failed: $($_.Exception.Message)" }
        Set-CurrentState -NewState 'REPORTING' -Data (Get-CurrentState).data
        @{ ok = $true; data = (Get-CurrentState) }
    } catch {
        @{ ok = $false; error = $_.Exception.Message }
    }
}

Register-Route -Method POST -Path '/api/heartbeat' -Handler {
    $script:LastHeartbeat = [DateTime]::Now
    @{ ok = $true; data = @{ timeout = $script:HeartbeatTimeoutSeconds; enabled = $script:HeartbeatEnabled } }
}

Register-Route -Method POST -Path '/api/shutdown' -Handler {
    Invoke-GracefulShutdown
    @{ ok = $true; data = @{ shuttingDown = $true } }
}

# Surface the app version (and the install path so users debugging
# multiple clones can confirm which one the browser is talking to).
Register-Route -Method GET -Path '/api/version' -Handler {
    @{ ok = $true; data = @{
        version    = $script:AppVersion
        installDir = $PSScriptRoot
    } }
}

Register-Route -Method POST -Path '/api/settings' -Handler {
    param($ctx, $params)
    $body = Read-JsonBody -Context $ctx
    if ($body -and $null -ne $body.PSObject.Properties['heartbeatEnabled']) {
        $script:HeartbeatEnabled = [bool]$body.heartbeatEnabled
        $script:LastHeartbeat = [DateTime]::Now  # reset clock when toggling
        Write-Log INFO "Heartbeat watchdog: $(if ($script:HeartbeatEnabled) {'ENABLED'} else {'DISABLED'})"
    }
    $maxT = $null; $maxV = $null; $abortWhea = $null
    if ($body) {
        if ($null -ne $body.PSObject.Properties['safetyMaxTempC'])        { $maxT = [int]$body.safetyMaxTempC }
        if ($null -ne $body.PSObject.Properties['safetyMaxVid'])          { $maxV = [double]$body.safetyMaxVid }
        if ($null -ne $body.PSObject.Properties['safetyAutoAbortOnWhea']) { $abortWhea = [bool]$body.safetyAutoAbortOnWhea }
    }
    if ($null -ne $maxT -or $null -ne $maxV -or $null -ne $abortWhea) {
        Set-SafetyLimits -MaxTempC $maxT -MaxVid $maxV -AbortOnWhea $abortWhea
    }
    @{ ok = $true; data = @{
        heartbeatEnabled = $script:HeartbeatEnabled
        safetyState = (Get-SafetyState)
    } }
}

$script:SmartTuneSessionPath = Join-Path $RepoRoot 'runtime\tuner-session.json'
$script:SmartTuneHistoryPath = Join-Path $RepoRoot 'runtime\tuner-history.jsonl'

Register-Route -Method POST -Path '/api/smart-tune/start' -Handler {
    param($ctx, $params)
    if (-not $runnerReady) { return @{ ok = $false; error = 'CoreCycler not installed' } }
    if (-not $coReady)     { return @{ ok = $false; error = 'CO tool not initialized' } }
    $cur = (Get-CurrentState).state
    if ($cur -ne 'IDLE' -and $cur -ne 'REPORTING') {
        return @{ ok = $false; error = "Cannot start - state=$cur" }
    }
    $body = Read-JsonBody -Context $ctx
    $mode      = if ($body -and $body.mode) { [string]$body.mode } else { 'daily-driver' }
    $direction = if ($body -and $body.direction) { [string]$body.direction } else { 'undervolt' }
    # applyMode: 'report' (default, safer - reverts SMU to launch values
    # on completion so the user sees a Tune Results table and explicitly
    # commits) or 'live' (legacy - SMU keeps whatever the tune ended at).
    $applyMode = if ($body -and $body.applyMode) { [string]$body.applyMode } else { 'report' }
    if ($applyMode -ne 'report' -and $applyMode -ne 'live') { $applyMode = 'report' }
    try {
        # Snapshot the current CO as a regular profile so the user can roll
        # back if Smart Tune converges somewhere worse than the starting
        # point. Best-effort: never block the tune on a snapshot failure.
        try {
            $currentCo = Get-AllCoreCo -CoreCount $cpu.Cores
            Save-PreTuneSnapshot -Process 'smart-tune' -CurrentValues $currentCo `
                -CpuModel $cpu.Name -CcdCount $cpu.CcdCount | Out-Null
        } catch { Write-Log WARN "Pre-Smart-Tune snapshot failed: $($_.Exception.Message)" }
        # Reset SMU to launch (BIOS) values before the bisection picks up,
        # so probes always start from a known-safe baseline regardless of
        # whatever the user had manually set. The auto-saved profile above
        # carries their pre-tune state if they want to return to it later.
        if ($coReady -and $null -ne $launchSnapshot) {
            try {
                Set-AllCoreCo -Values $launchSnapshot
                Write-Log INFO "Smart Tune: SMU reset to launch (BIOS) values before bisection"
            } catch {
                Write-Log WARN "Pre-Smart-Tune BIOS reset failed (continuing): $($_.Exception.Message)"
            }
        }

        Start-SmartTune -Cpu $cpu -Mode $mode -Direction $direction `
            -SessionPath $script:SmartTuneSessionPath -HistoryPath $script:SmartTuneHistoryPath `
            -ApplyMode $applyMode
        Set-CurrentState -NewState 'TESTING' -Data @{
            startedAt = (Get-Date -Format 'o')
            smartTune = $true
            mode = $mode
            direction = $direction
        }
        # Arm safety guard for the entire session. On abort: stop the tune,
        # write a panic breadcrumb for the launch snapshot, then revert CO
        # to the launch values so the system returns to a known-safe state.
        # "Stability is king" - never leave the user at an unstable CO after
        # a safety trip.
        $wheaCount = @(Get-WheaEvents).Count
        $cpuForCallback = $cpu
        $coReadyForCallback = $coReady
        $launchForCallback = $launchSnapshot
        Enable-SafetyGuard -WheaBaseline $wheaCount -OnAbort {
            param($violations)
            $reason = if (@($violations).Count -gt 0) { "SmartTune safety abort: $($violations[0].metric)" } else { 'SmartTune safety abort' }
            Write-Log ERROR $reason
            try { Stop-SmartTune } catch {}
            if ($coReadyForCallback -and $null -ne $launchForCallback) {
                try {
                    Save-PanicRevertState -Values $launchForCallback -Reason $reason
                    Set-AllCoreCo -Values $launchForCallback
                    Write-Log INFO "SmartTune abort: CO reverted to launch snapshot"
                } catch { Write-Log ERROR "Revert during SmartTune abort failed: $($_.Exception.Message)" }
            }
            try { Set-CurrentState -NewState 'REPORTING' -Force } catch {}
        }.GetNewClosure()
        @{ ok = $true; data = (Get-SmartTuneState -SinceSeqId 0) }
    } catch {
        @{ ok = $false; error = $_.Exception.Message }
    }
}

Register-Route -Method POST -Path '/api/smart-tune/stop' -Handler {
    Stop-SmartTune
    Disable-SafetyGuard
    Set-CurrentState -NewState 'REPORTING' -Force
    @{ ok = $true; data = (Get-SmartTuneState -SinceSeqId 0) }
}

Register-Route -Method GET -Path '/api/smart-tune/state' -Handler {
    param($ctx, $params)
    $since = 0
    $q = $ctx.Request.Url.Query
    if ($q -match '[?&]since=(\d+)') { $since = [int]$Matches[1] }
    @{ ok = $true; data = (Get-SmartTuneState -SinceSeqId $since) }
}

# Commit the per-core CO values that Smart Tune recommended. Used by the
# Tune Results table's [Apply recommended values] button when the tune
# ran in 'report' mode (default). Only valid after a tune COMPLETES;
# rejected while still RUNNING because the locked values aren't final.
Register-Route -Method POST -Path '/api/smart-tune/apply-results' -Handler {
    if (-not $coReady) { return @{ ok = $false; error = 'CO tool not initialized' } }
    $st = Get-SmartTuneState -SinceSeqId 0
    if ($st.status -ne 'COMPLETED') {
        return @{ ok = $false; error = "Cannot apply - tune status=$($st.status), needs COMPLETED" }
    }
    $launch = if ($null -ne $launchSnapshot) { $launchSnapshot } else { @(0) * $cpu.Cores }
    $values = Get-RecommendedCoFromTune -CoreCount $cpu.Cores -LaunchValues $launch
    try {
        # Same panic-revert breadcrumb pattern the safety guard uses -
        # if the SMU write hangs the system, the next boot sees the
        # breadcrumb and offers to revert.
        Save-PanicRevertState -Values $values -Reason 'Smart Tune apply-results'
        Set-AllCoreCo -Values $values
        Clear-PanicRevertState
        Write-Log INFO "Smart Tune results applied to SMU: $($values -join ',')"
        @{ ok = $true; data = @{ applied = $values } }
    } catch {
        @{ ok = $false; error = $_.Exception.Message }
    }
}

Register-Route -Method POST -Path '/api/smart-tune/resume' -Handler {
    param($ctx, $params)
    if (-not $runnerReady) { return @{ ok = $false; error = 'CoreCycler not installed' } }
    if (-not $coReady)     { return @{ ok = $false; error = 'CO tool not initialized' } }
    $cur = (Get-CurrentState).state
    if ($cur -ne 'IDLE' -and $cur -ne 'REPORTING') {
        return @{ ok = $false; error = "Cannot resume - state=$cur" }
    }
    # Optional `values` payload - the recovery card's "Edit & resume"
    # flow lets the user manually override the per-core starting CO
    # before the bisection picks up. Validation: must be an array of
    # ints, length == cpu.Cores, each within [-30, 30] (the SMU's
    # physical CO range). On any validation failure we fall through to
    # plain resume - safer than refusing and leaving the user staring
    # at a stuck recovery card.
    try {
        $body = Read-JsonBody -Context $ctx
        if ($body -and $body.PSObject.Properties['values'] -and $null -ne $body.values) {
            $vals = @($body.values | ForEach-Object { [int]$_ })
            if ($vals.Count -eq $cpu.Cores -and -not ($vals | Where-Object { $_ -lt -30 -or $_ -gt 30 })) {
                Save-PanicRevertState -Values $vals -Reason 'Smart Tune resume - user-edited seed values'
                Set-AllCoreCo -Values $vals
                Clear-PanicRevertState
                Write-Log INFO "Smart Tune resume seeded with user-edited values: $($vals -join ',')"
            } else {
                Write-Log WARN "Smart Tune resume: rejected values payload (count=$($vals.Count) or out-of-range); proceeding with last session values"
            }
        }
    } catch {
        Write-Log WARN "Smart Tune resume: values payload unreadable, ignoring: $($_.Exception.Message)"
    }
    $ok = Resume-SmartTune -SessionPath $script:SmartTuneSessionPath -HistoryPath $script:SmartTuneHistoryPath -Cpu $cpu
    if (-not $ok) { return @{ ok = $false; error = 'No session to resume (or unreadable)' } }
    Set-CurrentState -NewState 'TESTING' -Data @{
        startedAt = (Get-Date -Format 'o')
        smartTune = $true
        resumed   = $true
    }
    $wheaCount = @(Get-WheaEvents).Count
    $cpuForCallback = $cpu
    $coReadyForCallback = $coReady
    $launchForCallback = $launchSnapshot
    Enable-SafetyGuard -WheaBaseline $wheaCount -OnAbort {
        param($violations)
        $reason = if (@($violations).Count -gt 0) { "SmartTune safety abort: $($violations[0].metric)" } else { 'SmartTune safety abort' }
        Write-Log ERROR $reason
        try { Stop-SmartTune } catch {}
        if ($coReadyForCallback -and $null -ne $launchForCallback) {
            try {
                Save-PanicRevertState -Values $launchForCallback -Reason $reason
                Set-AllCoreCo -Values $launchForCallback
            } catch {}
        }
        try { Set-CurrentState -NewState 'REPORTING' -Force } catch {}
    }.GetNewClosure()
    # Clear the pending-session prompt now that we've actively resumed
    $script:PendingSmartSession = $null
    @{ ok = $true; data = (Get-SmartTuneState -SinceSeqId 0) }
}

Register-Route -Method POST -Path '/api/smart-tune/discard' -Handler {
    Discard-SmartTune
    Clear-PanicRevertState
    @{ ok = $true; data = @{ discarded = $true } }
}

Register-Route -Method GET -Path '/api/smart-tune/history' -Handler {
    $entries = @(Read-HistoryEntries -Path $script:SmartTuneHistoryPath -CpuModel $cpu.Name)
    @{ ok = $true; data = @{ cpuModel = $cpu.Name; entries = $entries } }
}

Register-Route -Method GET -Path '/api/smart-tune/pending-session' -Handler {
    @{ ok = $true; data = $script:PendingSmartSession }
}

Register-Route -Method GET -Path '/api/panic-revert' -Handler {
    @{ ok = $true; data = $script:PendingPanicRevert }
}

Register-Route -Method POST -Path '/api/panic-revert/apply' -Handler {
    if (-not $coReady) { return @{ ok = $false; error = 'CO tool not initialized' } }
    if ($null -eq $launchSnapshot) { return @{ ok = $false; error = 'No launch snapshot to revert to' } }
    try {
        Set-AllCoreCo -Values $launchSnapshot
        Clear-PanicRevertState
        $script:PendingPanicRevert = $null
        @{ ok = $true; data = @{ reverted = $launchSnapshot } }
    } catch { @{ ok = $false; error = $_.Exception.Message } }
}

Register-Route -Method POST -Path '/api/panic-revert/dismiss' -Handler {
    Clear-PanicRevertState
    $script:PendingPanicRevert = $null
    @{ ok = $true; data = @{ dismissed = $true } }
}

Register-Route -Method GET -Path '/api/status' -Handler {
    $script:LastHeartbeat = [DateTime]::Now   # any status call counts as a heartbeat too
    $state = Get-CurrentState
    $live = $null
    $whea = Get-WheaEvents

    # Auto-transition from TESTING to REPORTING if CoreCycler has exited.
    # SmartTune doesn't keep CoreCycler running between probes — it spawns
    # one per probe and the server is idle in between — so this check
    # would otherwise trip the moment a SmartTune session starts, before
    # the first probe even runs, and disarm the Safety Guard mid-tune.
    $smartTuneActive = (Get-SmartTuneState -SinceSeqId 0).status -eq 'RUNNING'
    if ($state.state -eq 'TESTING' -and -not $smartTuneActive -and -not (Test-CoreCyclerRunning)) {
        Stop-PeakTracking
        Disable-SafetyGuard
        Clear-PanicRevertState
        try { Build-Report } catch { Write-Log WARN "Build-Report on auto-transition failed: $($_.Exception.Message)" }
        Set-CurrentState -NewState 'REPORTING' -Data $state.data
        $state = Get-CurrentState
    }

    # Smart Tune driver: if a Smart Tune is running, do one probe tick.
    # This is intentionally driven from /api/status (the 1Hz browser
    # poll) so the server stays single-threaded and request handlers
    # are never blocked on a long-running CoreCycler subprocess - each
    # tick spawns CoreCycler synchronously but the next /api/status
    # only fires after the user's browser re-polls.
    $tuneState = Get-SmartTuneState -SinceSeqId 0
    if ($tuneState.status -eq 'RUNNING') {
        # The CO has already been written by $applyFn; the probe just runs
        # stress and returns the classification. Step-OneProbe invokes
        # $ProbeFn with no argument by design.
        #
        # $script:Tune must be captured as a local before .GetNewClosure():
        # closures created inside a dynamically-invoked scriptblock (route
        # handler) don't inherit the script's session state, so $script:*
        # resolves to $null at invocation time. Hashtables are reference
        # types, so mutations to $script:Tune.CurrentIdx etc. remain visible
        # through $tune.
        $tune = $script:Tune
        $probeFn = {
            $rt = $tune.Policy.probeRuntimeMin
            $timeout = [int]($rt * 60 * 2)   # 2x runtime as hard timeout
            Invoke-Probe -RepoRoot $RepoRoot -ScopeCores $tune.Scopes[$tune.CurrentIdx].cores `
                -TotalCores $cpu.Cores -ProbeRuntimeMin $rt -TimeoutSeconds $timeout `
                -TickCallback { (Get-SafetyState).newAbort }
        }.GetNewClosure()
        $applyFn = {
            param($cand)
            $all = New-Object 'int[]' $cpu.Cores
            $scope = $tune.Scopes[$tune.CurrentIdx]
            # Read current, then overwrite only this scope's cores
            $current = Get-AllCoreCo -CoreCount $cpu.Cores
            for ($i = 0; $i -lt $cpu.Cores; $i++) { $all[$i] = $current[$i] }
            foreach ($c in $scope.cores) { $all[$c] = $cand }
            Save-PanicRevertState -Values $all -Reason "SmartTune $($scope.id) probe CO=$cand"
            Set-AllCoreCo -Values $all
        }.GetNewClosure()
        $headroomFn = {
            $snap = if ($telemetryReady) { Read-TelemetrySnapshot } else { $null }
            Get-TelemetryHeadroom -Snapshot $snap -MaxTempC 95 -MaxVid 1.45
        }.GetNewClosure()
        $continued = Step-SmartTune -ProbeFn $probeFn -ApplyFn $applyFn -HeadroomFn $headroomFn -MaxProbesPerScope 12
        if (-not $continued) {
            Disable-SafetyGuard
            Clear-PanicRevertState
            # Report-mode auto-revert: when Smart Tune completes cleanly
            # in 'report' apply-mode, restore the launch CO snapshot so
            # the user is at a known-safe baseline while they review the
            # Tune Results table. They explicitly commit via
            # /api/smart-tune/apply-results when ready. STOPPED/FAILED
            # transitions bypass this - the safety-guard abort path
            # already reverts to launch with a panic breadcrumb.
            try {
                $tstate = Get-SmartTuneState -SinceSeqId 0
                if ($tstate.status -eq 'COMPLETED' -and $tstate.applyMode -eq 'report' `
                        -and $coReady -and $null -ne $launchSnapshot) {
                    Set-AllCoreCo -Values $launchSnapshot
                    Write-Log INFO "Smart Tune completed in report mode - CO reverted to launch snapshot; user to apply via /api/smart-tune/apply-results"
                }
            } catch {
                Write-Log WARN "Smart Tune complete-revert failed: $($_.Exception.Message)"
            }
            Set-CurrentState -NewState 'REPORTING' -Force
        }
    }

    if ($state.state -eq 'TESTING' -or $state.state -eq 'STOPPING') {
        $live = Get-LiveStatus
        # Snapshot for peak tracking + safety inspection while testing.
        if ($telemetryReady) {
            $snap = Read-TelemetrySnapshot
            $null = Inspect-SafetySnapshot -Snapshot $snap -WheaCount @($whea).Count
        }
    }

    @{
        ok = $true
        data = @{
            state = $state.state
            stateData = $state.data
            live = $live
            wheaEvents = $whea
            bodyguardActive = (Test-WheaWatcherActive)
            safetyGuard = (Get-SafetyState)
            panicRevertPending = ($null -ne $script:PendingPanicRevert)
            smartTune = (Get-SmartTuneState -SinceSeqId 0)
            # writesActive: $null = no write attempted yet this session;
            # $true = last write took effect; $false = SMU silently ignored
            # (UI shows the BIOS-setup card in that case).
            coWritesActive = $script:LastWriteStuck
            coWriteMismatches = @($script:LastWriteMismatches)
        }
    }
}

Register-Route -Method GET -Path '/api/whea' -Handler {
    @{ ok = $true; data = (Get-WheaEvents) }
}

Register-Route -Method POST -Path '/api/whea/clear' -Handler {
    Clear-WheaEvents
    @{ ok = $true; data = @{ cleared = $true } }
}

Register-Route -Method GET -Path '/api/report' -Handler {
    if ($null -eq $script:LastReport) { return @{ ok = $false; error = 'No report yet' } }
    @{ ok = $true; data = $script:LastReport }
}

function Build-Report {
    $logs = Get-LatestLogs
    $stateData = (Get-CurrentState).data
    $iterReq = if ($stateData -and $stateData['iterations']) { [int]$stateData['iterations'] } else { 1 }
    $mode = if ($stateData -and $stateData['mode']) { [string]$stateData['mode'] } else { '' }

    # Read current CO values for failure attribution (best effort)
    $currentVals = $null
    if ($coReady) {
        try { $currentVals = Get-AllCoreCo -CoreCount $cpu.Cores } catch { Write-Log WARN "CO read for report failed: $($_.Exception.Message)" }
    }

    $r = Read-CoreCyclerLog `
        -CoreCyclerLogPath $logs.coreCyclerLog `
        -Prime95LogPath $logs.prime95Log `
        -CpuInfo $cpu `
        -CurrentCoValues $currentVals `
        -IterationsRequested $iterReq

    # Add Smart Suggestions - infer CO mode from per-core values
    $reportMode = 'all-cores'
    $valsArr = @($currentVals)
    if ($valsArr.Count -gt 0) {
        $unique = @($valsArr | Select-Object -Unique)
        if ($unique.Count -eq 1) {
            $reportMode = 'all-cores'
        } elseif ($cpu.IsDualCcd -and $valsArr.Count -ge ($cpu.CoresPerCcd * 2)) {
            $ccd0 = @($valsArr[0..($cpu.CoresPerCcd-1)] | Select-Object -Unique)
            $ccd1 = @($valsArr[$cpu.CoresPerCcd..($cpu.Cores-1)] | Select-Object -Unique)
            if ($ccd0.Count -eq 1 -and $ccd1.Count -eq 1) { $reportMode = 'per-ccd' } else { $reportMode = 'per-core' }
        } else {
            $reportMode = 'per-core'
        }
    }

    $suggestions = Get-SmartSuggestions -Report $r -Mode $reportMode -CpuInfo $cpu -CurrentCoValues $currentVals

    $reportObj = $r | Select-Object *
    $reportObj | Add-Member -NotePropertyName smartSuggestions -NotePropertyValue $suggestions -Force
    $reportObj | Add-Member -NotePropertyName peaks -NotePropertyValue (Get-Peaks) -Force
    $reportObj | Add-Member -NotePropertyName coMode -NotePropertyValue $reportMode -Force
    $script:LastReport = $reportObj
    Write-Log INFO "Report built: verdict=$($r.verdict), failed=$($r.coresFailed.Count)"
}

# ----- Boot -----

$listener = Start-HttpServer
$url = "http://127.0.0.1:$(Get-ListenerPort)/"
try { Start-Process $url } catch { Write-Host "Open this URL manually: $url" }

# Heartbeat tick callback: invoked every 1s by the server loop. Returns $true to stop.
$tickCallback = {
    if ($script:ShutdownRequested) {
        Write-Log INFO "Shutdown was requested - exiting server loop"
        return $true
    }
    if (-not $script:HeartbeatEnabled) { return $false }  # user opted out of auto-shutdown
    $silence = ([DateTime]::Now - $script:LastHeartbeat).TotalSeconds
    if ($silence -gt $script:HeartbeatTimeoutSeconds) {
        Write-Host ""
        Write-Host "Browser stopped responding for $([math]::Round($silence,0))s - assuming closed." -ForegroundColor Yellow
        Invoke-GracefulShutdown
        return $true
    }
    return $false
}

try {
    Invoke-ServerLoop -Listener $listener -WebRoot (Join-Path $PSScriptRoot 'web') -TickCallback $tickCallback
} finally {
    if (-not $script:ShutdownRequested) {
        # Reached here without an explicit graceful shutdown (e.g., Ctrl+C). Best-effort cleanup.
        try { Invoke-GracefulShutdown } catch {}
    }
    try { Stop-WheaWatcher } catch {}
    try { Close-Telemetry } catch {}
    try { $listener.Stop() } catch {}
    try { $listener.Close() } catch {}
    Write-Log INFO "Server stopped"
    Write-Host ""
    Write-Host "Goodbye." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
}
