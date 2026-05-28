Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\logging.ps1"

$RepoRoot = $PSScriptRoot
$CoreCyclerDir = Join-Path $RepoRoot 'corecycler'
$CacheDir = Join-Path $RepoRoot 'installer-cache'
$VendorDir = Join-Path $RepoRoot 'vendor'
$ReleasesApi = 'https://api.github.com/repos/sp00n/corecycler/releases/latest'

function Get-LatestCoreCyclerRelease {
    Write-Log INFO "Querying CoreCycler latest release"
    $headers = @{ 'User-Agent' = 'Ryzen-Pro-Optimizer-Installer' }
    Invoke-RestMethod -Uri $ReleasesApi -Headers $headers
}

# Fast HTTP download: bypasses Invoke-WebRequest's slow progress-bar rendering
# (a known PowerShell perf bug that throttles downloads by 10-50x).
# Uses System.Net.Http.HttpClient with streaming + buffered file copy.
function Invoke-FastDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(15)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('Ryzen-Pro-Optimizer-Installer')

    try {
        $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "HTTP $([int]$response.StatusCode) from $Uri"
        }
        $total = $response.Content.Headers.ContentLength
        $totalMb = if ($total) { [math]::Round($total / 1MB, 1) } else { $null }

        $netStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fileStream = [IO.File]::OpenWrite($OutFile)
        try {
            $buffer = New-Object byte[] 81920
            $totalRead = 0L
            $lastReportMb = -1.0
            while (($n = $netStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $n)
                $totalRead += $n
                $readMb = [math]::Round($totalRead / 1MB, 1)
                if ($totalMb -and ($readMb - $lastReportMb) -ge 5) {
                    $pct = [math]::Round(100 * $totalRead / $total, 0)
                    Write-Host ("  {0,5} MB / {1} MB  ({2}%)" -f $readMb, $totalMb, $pct)
                    $lastReportMb = $readMb
                } elseif (-not $totalMb -and ($readMb - $lastReportMb) -ge 5) {
                    Write-Host ("  {0,5} MB downloaded" -f $readMb)
                    $lastReportMb = $readMb
                }
            }
        } finally {
            $fileStream.Dispose()
            $netStream.Dispose()
        }
        Write-Host "  Download complete: $(Split-Path -Leaf $OutFile)" -ForegroundColor Green
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-CoreCyclerZipUrl {
    param($Release)
    $asset = $Release.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
    if (-not $asset) {
        # Fallback: source code zip
        return $Release.zipball_url
    }
    $asset.browser_download_url
}

function Install-CoreCycler {
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir | Out-Null }

    $release = Get-LatestCoreCyclerRelease
    Write-Log INFO "Latest CoreCycler: $($release.tag_name)"
    Write-Host "Found CoreCycler $($release.tag_name)"

    $url = Get-CoreCyclerZipUrl -Release $release
    $zipPath = Join-Path $CacheDir "corecycler-$($release.tag_name).zip"

    if (-not (Test-Path $zipPath)) {
        Write-Host "Downloading from $url"
        Invoke-FastDownload -Uri $url -OutFile $zipPath
    }

    $extractDir = Join-Path $CacheDir "extract-$($release.tag_name)"
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    Write-Host "Extracting..."
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    # CoreCycler release zips may have the files directly OR an inner folder
    $inner = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
    $sourceDir = if ($inner -and -not (Test-Path (Join-Path $extractDir 'script-corecycler.ps1'))) {
        $inner.FullName
    } else {
        $extractDir
    }

    if (Test-Path $CoreCyclerDir) {
        Write-Host "Removing previous corecycler/"
        Remove-Item -Recurse -Force $CoreCyclerDir
    }
    Write-Host "Installing to $CoreCyclerDir"
    Move-Item -Path $sourceDir -Destination $CoreCyclerDir

    $required = @(
        'script-corecycler.ps1',
        'tools\ryzen-smu-cli\ryzen-smu-cli.exe'
    )
    foreach ($f in $required) {
        $full = Join-Path $CoreCyclerDir $f
        if (-not (Test-Path $full)) {
            throw "Required file missing after install: $f at $full"
        }
    }

    Write-Log INFO "CoreCycler installed to $CoreCyclerDir"
    Write-Host "CoreCycler $($release.tag_name) installed successfully." -ForegroundColor Green
}

function Test-LhmCompatible {
    # Returns $true if the installed DLL targets a runtime we can actually load
    # under PowerShell 5.1 (i.e. .NET Framework 4.x, NOT .NET 10+).
    $target = Join-Path $VendorDir 'LibreHardwareMonitorLib.dll'
    if (-not (Test-Path $target)) { return $false }
    try {
        $bytes = [IO.File]::ReadAllBytes($target)
        # Search the assembly for the framework target marker bytes
        $text = [Text.Encoding]::ASCII.GetString($bytes)
        if ($text -match '\.NETCoreApp,Version=v10\.0|\.NETCoreApp,Version=v9\.|\.NETCoreApp,Version=v8\.|\.NET 10\.0') {
            return $false  # too new for PS 5.1 .NET Framework host
        }
        return $true
    } catch {
        return $false
    }
}

function Install-LibreHardwareMonitor {
    if (-not (Test-Path $VendorDir)) { New-Item -ItemType Directory -Path $VendorDir | Out-Null }
    $target = Join-Path $VendorDir 'LibreHardwareMonitorLib.dll'
    if ((Test-Path $target) -and (Test-LhmCompatible)) {
        Write-Host "LibreHardwareMonitor already installed (compatible build)."
        return
    }
    if (Test-Path $target) {
        Write-Host "Existing LibreHardwareMonitor build is incompatible with this PowerShell - replacing..."
        Get-ChildItem -Path $VendorDir -Filter '*.dll' | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir | Out-Null }

    Write-Host "Locating latest LibreHardwareMonitor release..."
    $lhmApi = 'https://api.github.com/repos/LibreHardwareMonitor/LibreHardwareMonitor/releases/latest'
    $lhmRelease = Invoke-RestMethod -Uri $lhmApi -Headers @{ 'User-Agent' = 'Ryzen-Pro-Optimizer-Installer' }
    # LHM ships two zips: 'LibreHardwareMonitor.NET.10.zip' (requires .NET 10 runtime)
    # and 'LibreHardwareMonitor.zip' (.NET Framework 4.7.2 - works with PowerShell 5.1).
    # Prefer the .NET Framework build; .NET 10 build fails to load in PS 5.1.
    $asset = $lhmRelease.assets | Where-Object { $_.name -match '^LibreHardwareMonitor\.zip$' } | Select-Object -First 1
    if (-not $asset) {
        $asset = $lhmRelease.assets | Where-Object { $_.name -match '\.zip$' -and $_.name -notmatch 'NET\.?\d|net\d' } | Select-Object -First 1
    }
    if (-not $asset) {
        $asset = $lhmRelease.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
    }
    if (-not $asset) { throw "No zip asset in LibreHardwareMonitor release" }

    $zipPath = Join-Path $CacheDir "lhm-$($lhmRelease.tag_name).zip"
    if (-not (Test-Path $zipPath)) {
        Write-Host "Downloading LibreHardwareMonitor $($lhmRelease.tag_name)..."
        Invoke-FastDownload -Uri $asset.browser_download_url -OutFile $zipPath
    }

    $extract = Join-Path $CacheDir 'lhm-extract'
    if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
    Expand-Archive -Path $zipPath -DestinationPath $extract -Force

    $dll = Get-ChildItem -Path $extract -Recurse -Filter 'LibreHardwareMonitorLib.dll' | Select-Object -First 1
    if (-not $dll) { throw "LibreHardwareMonitorLib.dll not found in download" }
    Copy-Item -Path $dll.FullName -Destination $target
    Write-Host "LibreHardwareMonitorLib installed." -ForegroundColor Green

    # Copy companion DLLs that the lib needs (HidSharp, etc.)
    foreach ($name in @('HidSharp.dll','LibreHardwareMonitor.PawnIo.dll')) {
        $companion = Get-ChildItem -Path $extract -Recurse -Filter $name | Select-Object -First 1
        if ($companion) { Copy-Item -Path $companion.FullName -Destination (Join-Path $VendorDir $name) }
    }
}

function Test-CoreCyclerInstalled {
    Test-Path (Join-Path $CoreCyclerDir 'script-corecycler.ps1')
}

function Test-LhmInstalled {
    Test-Path (Join-Path $VendorDir 'LibreHardwareMonitorLib.dll')
}

function Test-PawnIoInstalled {
    # PawnIO registers a Windows service named "PawnIO"
    $svc = Get-Service -Name 'PawnIO' -ErrorAction SilentlyContinue
    if ($svc) { return $true }
    # Also check the default install path
    $defaultPath = "$env:ProgramFiles\PawnIO"
    if (Test-Path $defaultPath) { return $true }
    $false
}

function Install-PawnIo {
    if (Test-PawnIoInstalled) {
        Write-Host "PawnIO is already installed."
        return
    }
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir | Out-Null }

    Write-Host "Locating latest PawnIO release..."
    # Official PawnIO releases live in namazso/PawnIO.Setup (not namazso/PawnIO)
    $pawnApi = 'https://api.github.com/repos/namazso/PawnIO.Setup/releases/latest'
    try {
        $pawnRelease = Invoke-RestMethod -Uri $pawnApi -Headers @{ 'User-Agent' = 'Ryzen-Pro-Optimizer-Installer' }
    } catch {
        throw "Failed to query PawnIO.Setup releases: $($_.Exception.Message)"
    }

    $asset = $pawnRelease.assets | Where-Object { $_.name -match '_setup\.exe$|Setup\.exe$|\.msi$' } | Select-Object -First 1
    if (-not $asset) {
        $asset = $pawnRelease.assets | Where-Object { $_.name -match '\.exe$' } | Select-Object -First 1
    }
    if (-not $asset) {
        throw "No installer asset in PawnIO.Setup release $($pawnRelease.tag_name)"
    }
    $isMsi = $asset.name -match '\.msi$'

    $ext = if ($isMsi) { 'msi' } else { 'exe' }
    $installerPath = Join-Path $CacheDir "pawnio-$($pawnRelease.tag_name).$ext"
    if (-not (Test-Path $installerPath)) {
        Write-Host "Downloading PawnIO $($pawnRelease.tag_name) ($($asset.name))..."
        Invoke-FastDownload -Uri $asset.browser_download_url -OutFile $installerPath
    }

    Write-Host "Installing PawnIO driver (this registers a Windows service)..." -ForegroundColor Cyan
    if ($isMsi) {
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$installerPath`"", '/quiet', '/norestart') -Wait -PassThru
    } else {
        # PawnIO setup is NSIS-based; /S is the standard silent flag
        $proc = Start-Process -FilePath $installerPath -ArgumentList @('/S') -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Write-Host "Silent install returned $($proc.ExitCode); retrying with /SILENT..."
            $proc = Start-Process -FilePath $installerPath -ArgumentList @('/SILENT') -Wait -PassThru
        }
    }
    if ($proc.ExitCode -ne 0) {
        throw "PawnIO installer exited with code $($proc.ExitCode). Try running '$installerPath' manually."
    }

    Start-Sleep -Seconds 3
    if (-not (Test-PawnIoInstalled)) {
        throw "PawnIO installer reported success but the PawnIO service is not detected. Try running '$installerPath' interactively."
    }
    Write-Host "PawnIO installed successfully." -ForegroundColor Green
}

# Entry point - only run when invoked directly, not dot-sourced
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (-not (Test-CoreCyclerInstalled)) {
            Install-CoreCycler
        } else {
            Write-Host "CoreCycler is already installed at $CoreCyclerDir"
        }

        # PawnIO is required by modern ryzen-smu-cli (ZenStates-Core) and modern
        # LibreHardwareMonitor. WinRing0 was removed because Microsoft flagged it
        # as a vulnerable driver. PawnIO is the replacement.
        try {
            Install-PawnIo
        } catch {
            Write-Host ""
            Write-Host "WARNING: PawnIO install failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "CO writes and sensor readings will not work without it." -ForegroundColor Yellow
            Write-Host "Install manually from https://github.com/namazso/PawnIO/releases" -ForegroundColor Yellow
        }

        if (-not (Test-LhmInstalled)) {
            Install-LibreHardwareMonitor
        } else {
            Write-Host "LibreHardwareMonitor is already installed."
        }

        Write-Host ""
        Write-Host "Installation complete." -ForegroundColor Green
        exit 0
    } catch {
        Write-Host ""
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "If automatic install fails, you can:"
        Write-Host " 1. Manually download CoreCycler from https://github.com/sp00n/corecycler/releases"
        Write-Host "    and extract its contents into:  $CoreCyclerDir"
        Write-Host " 2. Manually install PawnIO driver from"
        Write-Host "    https://github.com/namazso/PawnIO/releases  (run the MSI/exe as admin)"
        Write-Host " 3. Manually download LibreHardwareMonitor from"
        Write-Host "    https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases"
        Write-Host "    and copy LibreHardwareMonitorLib.dll into:  $VendorDir"
        exit 1
    }
}
