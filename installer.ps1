# ============================================================================
#  installer.ps1 - Fetch CoreCycler, PawnIO, and the LHM net472 stack
# ============================================================================
#  Invoked by: Launch.bat when corecycler/, the LHM DLL, or PawnIO is
#              missing or (for the DLL) targets the wrong runtime.
#              Can also be run manually as Install.bat.
#
#  What it installs (one-time, on first launch or after a deletion):
#    - CoreCycler  ← latest release zip from sp00n/corecycler on GitHub
#    - PawnIO      ← installer EXE from namazso/PawnIO.Setup (one short
#                    wizard, the user clicks through). Replaces the
#                    deprecated WinRing0 driver.
#    - LibreHardwareMonitorLib + companion DLLs (.NET Framework 4.7.2)
#                    pinned versions from NuGet. See below for the why.
#
#  WHY NUGET INSTEAD OF GITHUB RELEASES (the load-bearing one):
#    LHM's recent GitHub releases ship a .NET 10 build of the lib that
#    Windows PowerShell 5.1 (.NET Framework 4.x host) cannot load -
#    you get "Could not load file or assembly 'System.Runtime,
#    Version=10.0.0.0' or one of its dependencies" wall-of-text errors
#    and zero sensors. The NuGet package at runtimes/win-x64/lib/net472/
#    still contains the .NET-Framework-compatible build. We pull that
#    instead, along with the right matching versions of System.Memory,
#    System.Runtime.CompilerServices.Unsafe, HidSharp, DiskInfoToolkit,
#    and RAMSPDToolkit-NDD. The exact version triplet
#    (LHM 0.9.6 + System.Memory 4.6.3 + Unsafe 6.1.2) is verified-
#    working: their internal assembly versions match LHM's binding pins.
#    Newer NuGet versions can ship different asm versions and break.
# ============================================================================
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
    # under PowerShell 5.1 (.NET Framework 4.x). GitHub-release zips and recent
    # LHM nupkgs have been shipping a .NET 10 build that PS 5.1 cannot load.
    $target = Join-Path $VendorDir 'LibreHardwareMonitorLib.dll'
    if (-not (Test-Path $target)) { return $false }
    try {
        $bytes = [IO.File]::ReadAllBytes($target)
        $text = [Text.Encoding]::ASCII.GetString($bytes)
        if ($text -match '\.NETCoreApp,Version=v10\.0|\.NETCoreApp,Version=v9\.|\.NETCoreApp,Version=v8\.|\.NETCoreApp,Version=v7\.|\.NETCoreApp,Version=v6\.|\.NET 10\.0') {
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

# Download a NuGet .nupkg into the installer cache. NuGet is a much more stable
# source than scraping GitHub release assets - the pkg layout never changes.
function Get-NuGetPackage {
    param([string]$Id, [string]$Version)
    $low = $Id.ToLowerInvariant()
    $url = "https://api.nuget.org/v3-flatcontainer/$low/$Version/$low.$Version.nupkg"
    $nupkg = Join-Path $CacheDir "nuget-$low-$Version.nupkg"
    if (-not (Test-Path $nupkg)) {
        Write-Host "  Fetching $Id $Version from NuGet..."
        Invoke-FastDownload -Uri $url -OutFile $nupkg
    }
    $extractDir = Join-Path $CacheDir "nuget-$low-$Version-extract"
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    Expand-Archive -Path $nupkg -DestinationPath $extractDir -Force
    return $extractDir
}

function Install-LibreHardwareMonitor {
    if (-not (Test-Path $VendorDir)) { New-Item -ItemType Directory -Path $VendorDir | Out-Null }
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir | Out-Null }
    $target = Join-Path $VendorDir 'LibreHardwareMonitorLib.dll'
    if ((Test-Path $target) -and (Test-LhmCompatible)) {
        Write-Host "LibreHardwareMonitor already installed (compatible .NET Framework build)."
        return
    }
    if (Test-Path $target) {
        Write-Host "Existing LibreHardwareMonitor DLL targets .NET Core/10 and cannot load under PowerShell 5.1 - replacing..." -ForegroundColor Yellow
        Get-ChildItem -Path $VendorDir -Filter '*.dll' | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # Pinned NuGet recipe that produces a working sensor stack under Windows
    # PowerShell 5.1 + .NET Framework 4.8. Each entry: (NuGet id, version,
    # relative path inside nupkg that contains the net4x DLL we want).
    #
    # Why fixed versions instead of "latest": modern LibreHardwareMonitorLib
    # references specific assembly-version pins for System.Memory and
    # System.Runtime.CompilerServices.Unsafe. Newer NuGet versions can ship
    # different internal asm versions and the strong-name binding mismatch
    # breaks Open(). 0.9.6 + 4.6.3 + 6.1.2 is the verified-working combo.
    $pkgs = @(
        @{ id='LibreHardwareMonitorLib';                 ver='0.9.6'; dir='runtimes\win-x64\lib\net472' }
        @{ id='DiskInfoToolkit';                         ver='1.1.2'; dir='lib\net472' }
        @{ id='RAMSPDToolkit-NDD';                       ver='1.4.2'; dir='lib\net472' }
        @{ id='HidSharp';                                ver='2.6.4'; dir='lib\net35' }
        @{ id='System.Memory';                           ver='4.6.3'; dir='lib\net462' }
        @{ id='System.Runtime.CompilerServices.Unsafe';  ver='6.1.2'; dir='lib\net462' }
    )

    foreach ($p in $pkgs) {
        $ext = Get-NuGetPackage -Id $p.id -Version $p.ver
        $srcDir = Join-Path $ext $p.dir
        if (-not (Test-Path $srcDir)) {
            throw "NuGet package $($p.id) $($p.ver) layout changed: expected $($p.dir) inside nupkg"
        }
        $dlls = Get-ChildItem -Path $srcDir -Filter '*.dll' -ErrorAction Stop
        if (-not $dlls) {
            throw "No DLLs found in $($p.id) $($p.ver) at $($p.dir)"
        }
        foreach ($d in $dlls) {
            Copy-Item -Path $d.FullName -Destination (Join-Path $VendorDir $d.Name) -Force
        }
    }

    if (-not (Test-LhmCompatible)) {
        throw "LibreHardwareMonitorLib install completed but the DLL still targets a non-Framework runtime. Aborting."
    }

    Write-Host "LibreHardwareMonitor stack installed (net472 build, PS5.1-compatible)." -ForegroundColor Green
    Write-Host "  Vendor DLLs:" -ForegroundColor DarkGray
    Get-ChildItem -Path $VendorDir -Filter '*.dll' | ForEach-Object {
        Write-Host ("    {0,-50} {1,8:N0} bytes" -f $_.Name, $_.Length) -ForegroundColor DarkGray
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

    Write-Host ""
    Write-Host "===================================================================" -ForegroundColor Cyan
    Write-Host "  PawnIO needs to be installed (one-time, kernel driver service)." -ForegroundColor Cyan
    Write-Host "  A small wizard window will open - click through it to install." -ForegroundColor Cyan
    Write-Host "  This installer accepts UAC and runs in about 5-10 seconds." -ForegroundColor Cyan
    Write-Host "===================================================================" -ForegroundColor Cyan
    Write-Host ""

    if ($isMsi) {
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$installerPath`"") -Wait -PassThru
    } else {
        # PawnIO_setup.exe uses non-standard arguments (/S, /SILENT both rejected
        # with 'unknown argument' errors). Launching interactively - user clicks
        # through the wizard. The installer is small and the wizard is short.
        $proc = Start-Process -FilePath $installerPath -Wait -PassThru
    }
    if ($proc.ExitCode -ne 0) {
        Write-Host "PawnIO installer exited with code $($proc.ExitCode). Trying to continue..." -ForegroundColor Yellow
    }

    Start-Sleep -Seconds 3
    if (-not (Test-PawnIoInstalled)) {
        throw "PawnIO service was not detected after install. If you cancelled the wizard, run '$installerPath' manually."
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

        if (-not (Test-LhmInstalled) -or -not (Test-LhmCompatible)) {
            Install-LibreHardwareMonitor
        } else {
            Write-Host "LibreHardwareMonitor is already installed (compatible build)."
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
