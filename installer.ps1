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
        # Use BITS for resumable download if available
        try {
            Start-BitsTransfer -Source $url -Destination $zipPath -ErrorAction Stop
        } catch {
            Invoke-WebRequest -Uri $url -OutFile $zipPath -Headers @{ 'User-Agent' = 'Ryzen-Pro-Optimizer-Installer' }
        }
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

function Install-LibreHardwareMonitor {
    if (-not (Test-Path $VendorDir)) { New-Item -ItemType Directory -Path $VendorDir | Out-Null }
    $target = Join-Path $VendorDir 'LibreHardwareMonitorLib.dll'
    if (Test-Path $target) {
        Write-Host "LibreHardwareMonitor already installed."
        return
    }

    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir | Out-Null }

    Write-Host "Locating latest LibreHardwareMonitor release..."
    $lhmApi = 'https://api.github.com/repos/LibreHardwareMonitor/LibreHardwareMonitor/releases/latest'
    $lhmRelease = Invoke-RestMethod -Uri $lhmApi -Headers @{ 'User-Agent' = 'Ryzen-Pro-Optimizer-Installer' }
    $asset = $lhmRelease.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw "No zip asset in LibreHardwareMonitor release" }

    $zipPath = Join-Path $CacheDir "lhm-$($lhmRelease.tag_name).zip"
    if (-not (Test-Path $zipPath)) {
        Write-Host "Downloading LibreHardwareMonitor $($lhmRelease.tag_name)..."
        try {
            Start-BitsTransfer -Source $asset.browser_download_url -Destination $zipPath -ErrorAction Stop
        } catch {
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers @{ 'User-Agent' = 'Ryzen-Pro-Optimizer-Installer' }
        }
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

# Entry point — only run when invoked directly, not dot-sourced
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (-not (Test-CoreCyclerInstalled)) {
            Install-CoreCycler
        } else {
            Write-Host "CoreCycler is already installed at $CoreCyclerDir"
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
        Write-Host " 2. Manually download LibreHardwareMonitor from"
        Write-Host "    https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases"
        Write-Host "    and copy LibreHardwareMonitorLib.dll into:  $VendorDir"
        exit 1
    }
}
