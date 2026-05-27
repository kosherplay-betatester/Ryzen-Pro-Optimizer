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

# Admin check (CO writes require it)
$isAdmin = (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ''
    Write-Host 'ERROR: Ryzen Pro Optimizer must run as administrator.' -ForegroundColor Red
    Write-Host 'Right-click Launch.bat and Run as Administrator (or just use Launch.bat — it self-elevates).'
    Write-Host ''
    Read-Host 'Press Enter to exit'
    exit 1
}

# Detect CPU
$cpu = Get-CpuInfo
Write-Log INFO "Detected CPU: $($cpu.Name) ($($cpu.Cores) cores, $(if ($cpu.IsDualCcd) {'dual'} else {'single'}) CCD)"

# Initialize profile store
Initialize-ProfileStore -RepoRoot $RepoRoot

# Initialize CO tool (best effort — server can still run if missing, just shows error)
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
    if (-not $coReady) { return @{ ok = $false; error = 'CO tool not initialized — run Install.bat' } }
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

# ----- Boot -----

$listener = Start-HttpServer
$url = "http://127.0.0.1:$(Get-ListenerPort)/"
try { Start-Process $url } catch { Write-Host "Open this URL manually: $url" }

try {
    Invoke-ServerLoop -Listener $listener -WebRoot (Join-Path $PSScriptRoot 'web')
} finally {
    try { $listener.Stop() } catch {}
    try { $listener.Close() } catch {}
    Write-Log INFO "Server stopped"
}
