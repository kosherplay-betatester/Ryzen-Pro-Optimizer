Set-StrictMode -Version Latest
. "$PSScriptRoot\logging.ps1"

# On-demand sensor polling. The HTTP server thread calls Read-TelemetrySnapshot
# each time /api/telemetry is hit (browser polls at 1Hz). Peak tracking happens
# inline when state machine is TESTING - also called from the HTTP handler.

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
    try {
        Add-Type -Path $dll -ErrorAction Stop
        foreach ($companion in @('HidSharp.dll','LibreHardwareMonitor.PawnIo.dll')) {
            $p = Join-Path $RepoRoot "vendor\$companion"
            if (Test-Path $p) {
                try { Add-Type -Path $p -ErrorAction SilentlyContinue } catch {}
            }
        }
        $script:Computer = New-Object LibreHardwareMonitor.Hardware.Computer
        $script:Computer.IsCpuEnabled = $true
        $script:Computer.IsMemoryEnabled = $true
        $script:Computer.IsMotherboardEnabled = $true
        $script:Computer.Open()
        $script:TelemetryAvailable = $true
        Write-Log INFO "Telemetry initialized; hardware count: $($script:Computer.Hardware.Count)"
        return $true
    } catch {
        Write-Log ERROR "Failed to init telemetry: $($_.Exception.Message)"
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
                    if ($name -match 'Core \(Tctl/Tdie\)' -or $name -eq 'CPU Package' -or $name -eq 'Package') { $snap.packageTemp = [double]$value }
                    elseif ($name -match '^CCD\s*(\d+)') { $snap.ccdTemps += [PSCustomObject]@{ ccd = [int]$Matches[1]; tempC = [double]$value } }
                }
                'Power' {
                    if ($name -match 'Package' -or $name -match 'PPT') { $snap.packagePower = [double]$value }
                }
                'Voltage' {
                    if ($name -match '^CPU Core #?(\d+)') {
                        $core = ([int]$Matches[1]) - 1
                        if (-not $coreMap.ContainsKey($core)) { $coreMap[$core] = [ordered]@{ core=$core; voltage=$null; clockMHz=$null; loadPct=$null; temperature=$null } }
                        $coreMap[$core].voltage = [double]$value
                    }
                }
                'Clock' {
                    if ($name -match '^CPU Core #?(\d+)') {
                        $core = ([int]$Matches[1]) - 1
                        if (-not $coreMap.ContainsKey($core)) { $coreMap[$core] = [ordered]@{ core=$core; voltage=$null; clockMHz=$null; loadPct=$null; temperature=$null } }
                        $coreMap[$core].clockMHz = [double]$value
                    }
                    elseif ($name -match 'Memory') { $snap.memoryClock = [double]$value }
                    elseif ($name -match 'Fabric|FCLK') { $snap.fclk = [double]$value }
                }
                'Load' {
                    if ($name -match '^CPU Core #?(\d+)') {
                        $core = ([int]$Matches[1]) - 1
                        if (-not $coreMap.ContainsKey($core)) { $coreMap[$core] = [ordered]@{ core=$core; voltage=$null; clockMHz=$null; loadPct=$null; temperature=$null } }
                        $coreMap[$core].loadPct = [double]$value
                    }
                }
                'Fan' { $snap.fans += [PSCustomObject]@{ name=$name; rpm=[double]$value } }
            }
        }
    }
    $snap.cores = $coreMap.Keys | Sort-Object | ForEach-Object { [PSCustomObject]$coreMap[$_] }

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
