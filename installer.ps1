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
