# ============================================================================
#  telemetry-poller.ps1 - LibreHardwareMonitor sensor reader
# ============================================================================
#  Used by  : server.ps1 (/api/telemetry, /api/status during tests),
#             safety-guard.ps1 (consumes snapshots)
#  Wraps    : vendor/LibreHardwareMonitorLib.dll (the net472 build -
#             see installer.ps1 for why version pinning matters)
#
#  Polling model: on-demand. We don't run a background timer; instead
#  the HTTP handler for /api/telemetry calls Read-TelemetrySnapshot and
#  the browser polls at 1 Hz. That keeps us at zero CPU when no one is
#  watching, and avoids any threading concerns inside PowerShell 5.1.
#
#  Important sensor-name notes (verified against LHM 0.9.6):
#    Temperature : "Core (Tctl/Tdie)", "CCD1", "CCD2"
#    Voltage     : "Core #1 VID" (per physical core)
#    Clock       : "Core #1" (current MHz) - we skip "(Effective)"
#    Power       : "Package" (PPT), "Core #N (SMU)" (per-core W)
#    Load        : "CPU Core #N" - enumerated per LOGICAL thread, so
#                  a 16c/32t Ryzen gives indices 0..31. We collapse
#                  SMT siblings to physical cores by keeping only
#                  entries that also have a voltage/clock reading.
#
#  Peak tracking: Start-PeakTracking / Stop-PeakTracking are toggled
#  around a test run by server.ps1, so the report can show max temp /
#  power / per-core voltage / per-core clock observed during the test.
# ============================================================================
Set-StrictMode -Version Latest
. "$PSScriptRoot\logging.ps1"

$script:Computer = $null
$script:History = New-Object System.Collections.Generic.List[object]
$script:HistoryMax = 60
$script:Peaks = @{}
$script:PeakTracking = $false
$script:TelemetryAvailable = $false

function Initialize-Telemetry {
    param([string]$RepoRoot)
    $dll = Join-Path $RepoRoot 'vendor\LibreHardwareMonitorLib.dll'
    if (-not (Test-Path $dll)) {
        Write-Log WARN "LibreHardwareMonitorLib.dll not found at $dll - telemetry disabled"
        return $false
    }
    # Load any companion DLLs first so LibreHardwareMonitorLib can resolve them
    $vendorDir = Join-Path $RepoRoot 'vendor'
    Get-ChildItem -Path $vendorDir -Filter '*.dll' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'LibreHardwareMonitorLib.dll' } | ForEach-Object {
        try { Add-Type -Path $_.FullName -ErrorAction SilentlyContinue } catch {}
    }
    try {
        Add-Type -Path $dll -ErrorAction Stop
        $script:Computer = New-Object LibreHardwareMonitor.Hardware.Computer
        $script:Computer.IsCpuEnabled = $true
        $script:Computer.IsMemoryEnabled = $true
        $script:Computer.IsMotherboardEnabled = $true
        $script:Computer.Open()
        $script:TelemetryAvailable = $true
        Write-Log INFO "Telemetry initialized; hardware count: $($script:Computer.Hardware.Count)"
        return $true
    } catch [System.Reflection.ReflectionTypeLoadException] {
        # Surface the LoaderExceptions so we can diagnose what's actually missing
        Write-Log ERROR "Failed to init telemetry (type load error): $($_.Exception.Message)"
        foreach ($le in $_.Exception.LoaderExceptions) {
            Write-Log ERROR "  Loader: $($le.Message)"
        }
        $script:Computer = $null
        $script:TelemetryAvailable = $false
        return $false
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) {
            $msg += " :: " + $_.Exception.InnerException.Message
        }
        Write-Log ERROR "Failed to init telemetry: $msg"
        # If it looks like a PawnIO issue, mention it
        if ($msg -match 'PawnIO|driver|service|access denied') {
            Write-Log ERROR "This often means the PawnIO driver isn't installed. Re-run Install.bat as admin."
        }
        $script:Computer = $null
        $script:TelemetryAvailable = $false
        return $false
    }
}

function Test-TelemetryAvailable { $script:TelemetryAvailable }

function Read-TelemetrySnapshot {
    if ($null -eq $script:Computer) { return $null }
    $snap = [ordered]@{
        time = (Get-Date -Format 'o')
        packageTemp = $null
        ccdTemps = @()
        packagePower = $null
        cores = @()
        memoryClock = $null
        fclk = $null
        fans = @()
    }
    $coreMap = @{}
    $ensureCore = {
        param($idx)
        if (-not $coreMap.ContainsKey($idx)) {
            $coreMap[$idx] = [ordered]@{ core=$idx; voltage=$null; clockMHz=$null; loadPct=$null; temperature=$null; powerW=$null; multiplier=$null }
        }
    }

    # LibreHardwareMonitor's AMD Ryzen sensor naming (verified against 0.9.6 net472):
    #   Temperature : "Core (Tctl/Tdie)", "CCD1", "CCD2"
    #   Voltage     : "Core #1 VID", "Core #2 VID", ...
    #   Clock       : "Core #1", "Core #1 (Effective)", "Cores (Average)", "Memory", "Fabric"
    #   Power       : "Package", "Cores", "Core #1 (SMU)", ...
    #   Load        : "CPU Core #1", ...
    # The older "CPU Core #N" pattern (from older LHM/OHM versions) is kept as a fallback.
    foreach ($hw in $script:Computer.Hardware) {
        try { $hw.Update() } catch { continue }
        foreach ($sub in $hw.SubHardware) {
            try { $sub.Update() } catch {}
        }
        foreach ($s in $hw.Sensors) {
            $name = $s.Name
            $type = $s.SensorType.ToString()
            $value = $s.Value
            if ($null -eq $value) { continue }

            switch ($type) {
                'Temperature' {
                    if ($name -match 'Core \(Tctl/Tdie\)' -or $name -eq 'CPU Package' -or $name -eq 'Package' -or $name -eq 'Core Max') {
                        if ($null -eq $snap.packageTemp -or [double]$value -gt $snap.packageTemp) { $snap.packageTemp = [double]$value }
                    }
                    elseif ($name -match '^CCD\s*(\d+)') {
                        $snap.ccdTemps += [PSCustomObject]@{ ccd = [int]$Matches[1] - 1; tempC = [double]$value }
                    }
                }
                'Power' {
                    if ($name -eq 'Package' -or $name -match 'PPT') { $snap.packagePower = [double]$value }
                    elseif ($name -match '^Core #?(\d+)') {
                        $core = ([int]$Matches[1]) - 1
                        & $ensureCore $core
                        $coreMap[$core].powerW = [double]$value
                    }
                }
                'Voltage' {
                    # "Core #1 VID" (current), "CPU Core #1" (older naming)
                    if ($name -match '^Core #?(\d+)(\s+VID)?$' -or $name -match '^CPU Core #?(\d+)') {
                        $core = ([int]$Matches[1]) - 1
                        & $ensureCore $core
                        $coreMap[$core].voltage = [double]$value
                    }
                }
                'Clock' {
                    # "Core #1" (current) or "CPU Core #1" (older). Skip "(Effective)" variants
                    # so per-core MHz reflects boost target, not weighted-by-load value.
                    if (($name -match '^Core #?(\d+)$' -or $name -match '^CPU Core #?(\d+)$')) {
                        $core = ([int]$Matches[1]) - 1
                        & $ensureCore $core
                        $coreMap[$core].clockMHz = [double]$value
                    }
                    elseif ($name -match 'Memory') { $snap.memoryClock = [double]$value }
                    elseif ($name -match 'Fabric|FCLK|Infinity') { $snap.fclk = [double]$value }
                }
                'Load' {
                    if ($name -match '^CPU Core #?(\d+)' -or $name -match '^Core #?(\d+)$') {
                        $core = ([int]$Matches[1]) - 1
                        & $ensureCore $core
                        $coreMap[$core].loadPct = [double]$value
                    }
                }
                'Factor' {
                    # Per-core CPU multiplier - useful for boost behavior view
                    if ($name -match '^Core #?(\d+)$') {
                        $core = ([int]$Matches[1]) - 1
                        & $ensureCore $core
                        $coreMap[$core].multiplier = [double]$value
                    }
                }
                'Fan' { $snap.fans += [PSCustomObject]@{ name=$name; rpm=[double]$value } }
            }
        }
    }
    # Filter out SMT-only entries: LHM exposes "CPU Core #N" Load sensors for
    # every logical thread, so a 16-core/32-thread Ryzen yields core indices
    # 0..31. The physical cores are the ones that also report a voltage VID;
    # SMT siblings only have Load. Strip the siblings here to keep the UI
    # per-physical-core (which is how Curve Optimizer works anyway).
    $hasVoltageOrClock = @($coreMap.Keys | Where-Object {
        $null -ne $coreMap[$_].voltage -or $null -ne $coreMap[$_].clockMHz
    })
    $emitKeys = if ($hasVoltageOrClock.Count -gt 0) { $hasVoltageOrClock } else { @($coreMap.Keys) }
    $snap.cores = @($emitKeys | Sort-Object | ForEach-Object { [PSCustomObject]$coreMap[$_] })

    $result = [PSCustomObject]$snap

    # Maintain history buffer
    $script:History.Add($result)
    while ($script:History.Count -gt $script:HistoryMax) { $script:History.RemoveAt(0) }

    # Track peaks if active
    if ($script:PeakTracking) { Update-Peaks -Snapshot $result }

    $result
}

function Update-Peaks {
    param($Snapshot)
    if ($null -eq $Snapshot) { return }
    if ($null -ne $Snapshot.packageTemp -and (-not $script:Peaks.ContainsKey('packageTemp') -or $Snapshot.packageTemp -gt $script:Peaks['packageTemp'])) {
        $script:Peaks['packageTemp'] = $Snapshot.packageTemp
    }
    if ($null -ne $Snapshot.packagePower -and (-not $script:Peaks.ContainsKey('packagePower') -or $Snapshot.packagePower -gt $script:Peaks['packagePower'])) {
        $script:Peaks['packagePower'] = $Snapshot.packagePower
    }
    foreach ($c in $Snapshot.cores) {
        if ($null -ne $c.voltage) {
            $key = "core$($c.core).voltage"
            if (-not $script:Peaks.ContainsKey($key) -or $c.voltage -gt $script:Peaks[$key]) { $script:Peaks[$key] = $c.voltage }
        }
        if ($null -ne $c.clockMHz) {
            $key = "core$($c.core).clockMHz"
            if (-not $script:Peaks.ContainsKey($key) -or $c.clockMHz -gt $script:Peaks[$key]) { $script:Peaks[$key] = $c.clockMHz }
        }
    }
}

function Start-PeakTracking {
    $script:Peaks = @{}
    $script:PeakTracking = $true
    Write-Log INFO "Peak tracking started"
}

function Stop-PeakTracking {
    $script:PeakTracking = $false
    Write-Log INFO "Peak tracking stopped"
}

function Get-Peaks { $script:Peaks }
function Get-TelemetryHistory { , @($script:History.ToArray()) }

function Close-Telemetry {
    if ($script:Computer) {
        try { $script:Computer.Close() } catch {}
        $script:Computer = $null
    }
    $script:TelemetryAvailable = $false
}
