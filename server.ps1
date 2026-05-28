Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

# Heartbeat tracking: when browser stops pinging, server reverts CO and exits.
# Disabled when user unchecks "tab close shuts down server" in UI settings.
$script:LastHeartbeat = [DateTime]::Now
$script:ShutdownRequested = $false
$script:HeartbeatTimeoutSeconds = 20
$script:HeartbeatEnabled = $true

# Initialize WHEA Bodyguard (best effort; needs admin)
Initialize-WheaWatcher -RepoRoot $RepoRoot
$wheaActive = Start-WheaWatcher

# Graceful shutdown: revert CO, stop test, close listener
function Invoke-GracefulShutdown {
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

    $script:ShutdownRequested = $true
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
        Set-AllCoreCo -Values $values
        @{ ok = $true; data = @{ applied = $values } }
    } catch {
        @{ ok = $false; error = $_.Exception.Message }
    }
}

Register-Route -Method POST -Path '/api/reset-co' -Handler {
    if (-not $coReady) { return @{ ok = $false; error = 'CO tool not initialized' } }
    try {
        Reset-AllCoreCo -CoreCount $cpu.Cores
        @{ ok = $true; data = @{ reset = $true } }
    } catch {
        @{ ok = $false; error = $_.Exception.Message }
    }
}

Register-Route -Method POST -Path '/api/co/revert' -Handler {
    if (-not $coReady) { return @{ ok = $false; error = 'CO tool not initialized' } }
    if ($null -eq $launchSnapshot) { return @{ ok = $false; error = 'No launch snapshot' } }
    try {
        Set-AllCoreCo -Values $launchSnapshot
        @{ ok = $true; data = @{ reverted = $launchSnapshot } }
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
    if (-not (Test-TelemetryAvailable)) { return @{ ok = $false; error = 'Telemetry unavailable' } }
    @{ ok = $true; data = (Read-TelemetrySnapshot) }
}

Register-Route -Method GET -Path '/api/telemetry/history' -Handler {
    @{ ok = $true; data = (Get-TelemetryHistory) }
}

Register-Route -Method GET -Path '/api/telemetry/peaks' -Handler {
    @{ ok = $true; data = (Get-Peaks) }
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
        if ($coReady) { $autoStart = Get-AllCoreCo -CoreCount $cpu.Cores }
    }

    $coresToTest = $null
    if ($body.PSObject.Properties['coresToTest'] -and $body.coresToTest) {
        $coresToTest = @($body.coresToTest | ForEach-Object { [int]$_ })
    }

    try {
        $cfg = New-CoreCyclerConfig -RepoRoot $RepoRoot `
            -StressTestProgram 'PRIME95' -Mode $mode -MaxIterations $iterations `
            -CoresToTest $coresToTest -TotalCores $cpu.Cores `
            -EnableAutomaticAdjustment $auto -AutoStartValues $autoStart `
            -AutoMaxValue $autoMax -AutoIncrementBy $autoInc

        Start-CoreCyclerRun -ConfigPath $cfg
        Start-PeakTracking
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

Register-Route -Method POST -Path '/api/settings' -Handler {
    param($ctx, $params)
    $body = Read-JsonBody -Context $ctx
    if ($body -and $null -ne $body.PSObject.Properties['heartbeatEnabled']) {
        $script:HeartbeatEnabled = [bool]$body.heartbeatEnabled
        $script:LastHeartbeat = [DateTime]::Now  # reset clock when toggling
        Write-Log INFO "Heartbeat watchdog: $(if ($script:HeartbeatEnabled) {'ENABLED'} else {'DISABLED'})"
    }
    @{ ok = $true; data = @{ heartbeatEnabled = $script:HeartbeatEnabled } }
}

Register-Route -Method GET -Path '/api/status' -Handler {
    $script:LastHeartbeat = [DateTime]::Now   # any status call counts as a heartbeat too
    $state = Get-CurrentState
    $live = $null
    $whea = Get-WheaEvents

    # Auto-transition from TESTING to REPORTING if CoreCycler has exited
    if ($state.state -eq 'TESTING' -and -not (Test-CoreCyclerRunning)) {
        Stop-PeakTracking
        try { Build-Report } catch { Write-Log WARN "Build-Report on auto-transition failed: $($_.Exception.Message)" }
        Set-CurrentState -NewState 'REPORTING' -Data $state.data
        $state = Get-CurrentState
    }

    if ($state.state -eq 'TESTING' -or $state.state -eq 'STOPPING') {
        $live = Get-LiveStatus
        # Also update peaks via snapshot read while testing
        if ($telemetryReady) { $null = Read-TelemetrySnapshot }
    }

    @{
        ok = $true
        data = @{
            state = $state.state
            stateData = $state.data
            live = $live
            wheaEvents = $whea
            bodyguardActive = (Test-WheaWatcherActive)
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

    # Add Smart Suggestions
    $reportMode = if ($mode) { 'all-cores' } else { 'all-cores' }
    if ($stateData -and $stateData.PSObject.Properties['mode']) {
        # 'mode' here is the stress-test type, not CO mode; we don't currently track CO mode in state
        # Use a heuristic: if all CO values are equal -> all-cores; if half-half -> per-ccd; else per-core
    }
    if ($currentVals -and $currentVals.Count -gt 0) {
        $allSame = ($currentVals | Select-Object -Unique).Count -eq 1
        if ($allSame) { $reportMode = 'all-cores' }
        elseif ($cpu.IsDualCcd) {
            $ccd0Same = ($currentVals[0..($cpu.CoresPerCcd-1)] | Select-Object -Unique).Count -eq 1
            $ccd1Same = ($currentVals[$cpu.CoresPerCcd..($cpu.Cores-1)] | Select-Object -Unique).Count -eq 1
            if ($ccd0Same -and $ccd1Same) { $reportMode = 'per-ccd' } else { $reportMode = 'per-core' }
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
