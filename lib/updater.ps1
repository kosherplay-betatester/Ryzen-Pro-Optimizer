# ============================================================================
#  updater.ps1 - Self-updater for Ryzen Pro Optimizer
# ============================================================================
#  Used by  : update.ps1 (called from Launch.bat before server boot)
#             Update.bat (manual force-check)
#
#  How updates roll out:
#    - Maintainer bumps $script:AppVersion in server.ps1 and pushes main.
#    - Users' launchers fetch raw server.ps1 on main, parse the constant,
#      compare to local. If remote is newer, prompt + apply.
#    - We pull the raw archive of main (refs/heads/main.zip), not a git
#      clone, so users don't need git installed. Once the project grows
#      formal GitHub Releases, swap RpoUpdateUrl to the release asset.
#
#  Preserve list (never overwritten / never deleted by the updater):
#    - runtime/         session state, panic-revert, history, logs
#    - profiles/        user-saved CO profiles
#    - corecycler/      third-party stress engine (managed by installer.ps1)
#    - vendor/          LibreHardwareMonitor DLL (managed by installer.ps1)
#    - installer-cache/ downloaded artifacts + our own backups
#
#  Safety - we refuse to apply when:
#    - Another RPO instance is listening on 127.0.0.1:8765
#      (would dead-lock DLL handles on overwrite + clobber its state)
#    - A panic-revert breadcrumb or RUNNING tune session is on disk
#      (mid-tune; overwriting the binaries would orphan the test process)
# ============================================================================
Set-StrictMode -Version Latest
. "$PSScriptRoot\logging.ps1"

$script:RpoUpdateRepo        = 'kosherplay-betatester/Ryzen-Pro-Optimizer'
$script:RpoUpdateBranch      = 'main'
$script:RpoVersionProbeUrl   = "https://raw.githubusercontent.com/$($script:RpoUpdateRepo)/$($script:RpoUpdateBranch)/server.ps1"
$script:RpoUpdateUrl         = "https://github.com/$($script:RpoUpdateRepo)/archive/refs/heads/$($script:RpoUpdateBranch).zip"
$script:RpoUpdatePreserve    = @('runtime','profiles','corecycler','vendor','installer-cache')
$script:RpoMinCheckIntervalH = 6     # don't probe more often than every N hours on normal launches
$script:RpoVersionRegex      = '\$script:AppVersion\s*=\s*[''"]([^''"]+)[''"]'

function Get-LocalRpoVersion {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $srv = Join-Path $RepoRoot 'server.ps1'
    if (-not (Test-Path $srv)) { return '0.0.0' }
    $content = Get-Content -Path $srv -Raw -ErrorAction SilentlyContinue
    if ($content -and $content -match $script:RpoVersionRegex) { return $Matches[1] }
    '0.0.0'
}

function Get-RemoteRpoVersion {
    param([int]$TimeoutSec = 5)
    # TLS 1.2 - GitHub rejects older. PS 5.1 still defaults to 1.0/1.1.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $resp = Invoke-WebRequest -Uri $script:RpoVersionProbeUrl -UseBasicParsing -TimeoutSec $TimeoutSec
    if ($resp.StatusCode -ne 200) { throw "HTTP $($resp.StatusCode) from $($script:RpoVersionProbeUrl)" }
    $text = [string]$resp.Content
    if ($text -match $script:RpoVersionRegex) { return $Matches[1] }
    throw "could not parse `$script:AppVersion line from remote server.ps1"
}

# Strict semver-style comparison via [System.Version]. Falls back to a
# string inequality test if either side won't parse (e.g. dev tags).
function Test-RpoNewerVersion {
    param([Parameter(Mandatory)][string]$Local, [Parameter(Mandatory)][string]$Remote)
    try {
        $lv = [Version]$Local
        $rv = [Version]$Remote
        return $rv -gt $lv
    } catch {
        return $Remote -ne $Local
    }
}

function Test-RpoInstanceRunning {
    # Quick TCP probe on the server port. 500 ms is plenty for a
    # localhost connect; anything longer would have launched anyway.
    $tc = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $tc.BeginConnect('127.0.0.1', 8765, $null, $null)
        $ok  = $iar.AsyncWaitHandle.WaitOne(500, $false)
        if ($ok -and $tc.Connected) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        try { $tc.Close() } catch {}
    }
}

function Test-RpoActiveTune {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $panic   = Join-Path $RepoRoot 'runtime\panic-revert.json'
    $session = Join-Path $RepoRoot 'runtime\tune-session.json'
    if (Test-Path $panic)   { return $true }
    if (Test-Path $session) {
        try {
            $s = Get-Content $session -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($s -and ($s.status -eq 'RUNNING' -or $s.status -eq 'STOPPING')) { return $true }
        } catch {}
    }
    return $false
}

# Rate-limit the *network* check on normal launches so we don't hit
# GitHub on every single boot. Manual Update.bat passes -Force to skip
# the gate.
function Test-RpoShouldCheckNow {
    param([Parameter(Mandatory)][string]$RepoRoot, [switch]$Force)
    if ($Force) { return $true }
    $stamp = Join-Path $RepoRoot 'runtime\last-update-check.txt'
    if (-not (Test-Path $stamp)) { return $true }
    try {
        $last = [DateTime](Get-Content $stamp -Raw -ErrorAction SilentlyContinue).Trim()
        return ((Get-Date) - $last).TotalHours -ge $script:RpoMinCheckIntervalH
    } catch {
        return $true
    }
}

function Update-RpoCheckStamp {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $dir   = Join-Path $RepoRoot 'runtime'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $stamp = Join-Path $dir 'last-update-check.txt'
    Set-Content -Path $stamp -Value (Get-Date -Format 'o') -Encoding ASCII
}

function Get-RpoSkippedVersion {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $f = Join-Path $RepoRoot 'runtime\skipped-version.txt'
    if (Test-Path $f) { return (Get-Content $f -Raw -ErrorAction SilentlyContinue).Trim() }
    $null
}

function Set-RpoSkippedVersion {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Version)
    $dir = Join-Path $RepoRoot 'runtime'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -Path (Join-Path $dir 'skipped-version.txt') -Value $Version -Encoding ASCII
}

# Apply a downloaded update to RepoRoot. Two-phase:
#   1. Backup non-preserved top-level entries to installer-cache/backups/
#      so the user has a one-shot rollback path.
#   2. Overlay the extracted archive into RepoRoot, removing local
#      directories the upstream tree no longer contains (clean replace).
# Preserve-list entries are never read, written, or deleted.
function Invoke-RpoUpdate {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RemoteVersion
    )
    $work = Join-Path $env:TEMP "rpo-update-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $zip  = Join-Path $work 'rpo.zip'

    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
        # Invoke-WebRequest's progress bar can slow large downloads ~10x in PS 5.1.
        $prevProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $script:RpoUpdateUrl -OutFile $zip -UseBasicParsing
        } finally {
            $ProgressPreference = $prevProgress
        }
        if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 1024) {
            throw "download archive missing or too small (got $((Get-Item $zip).Length) bytes)"
        }

        Expand-Archive -Path $zip -DestinationPath $work -Force
        # GitHub archives extract to "<repo>-<branch>/..."
        $extracted = Get-ChildItem -Path $work -Directory -Filter 'Ryzen-Pro-Optimizer-*' | Select-Object -First 1
        if (-not $extracted) { throw "extracted archive shape unexpected (no Ryzen-Pro-Optimizer-* dir)" }

        $bkRoot = Join-Path $RepoRoot 'installer-cache\backups'
        if (-not (Test-Path $bkRoot)) { New-Item -ItemType Directory -Path $bkRoot -Force | Out-Null }
        $localVer = Get-LocalRpoVersion -RepoRoot $RepoRoot
        $bkDir = Join-Path $bkRoot "$localVer-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        New-Item -ItemType Directory -Path $bkDir -Force | Out-Null

        # Backup pass - only non-preserved top-level entries.
        foreach ($e in Get-ChildItem -Path $RepoRoot) {
            if ($script:RpoUpdatePreserve -contains $e.Name) { continue }
            $dest = Join-Path $bkDir $e.Name
            if ($e.PSIsContainer) {
                Copy-Item -Path $e.FullName -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                Copy-Item -Path $e.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
            }
        }

        # Overlay pass - copy extracted top-level into RepoRoot.
        # Directories are removed-then-copied so files deleted upstream
        # also disappear locally (otherwise stale code accumulates).
        foreach ($e in Get-ChildItem -Path $extracted.FullName) {
            if ($script:RpoUpdatePreserve -contains $e.Name) { continue }
            $dest = Join-Path $RepoRoot $e.Name
            if ($e.PSIsContainer) {
                if (Test-Path $dest) { Remove-Item -Path $dest -Recurse -Force -ErrorAction SilentlyContinue }
                Copy-Item -Path $e.FullName -Destination $dest -Recurse -Force
            } else {
                Copy-Item -Path $e.FullName -Destination $dest -Force
            }
        }

        # Clear any skip-marker so a fresh "next update" prompt fires
        # normally next time.
        $skip = Join-Path $RepoRoot 'runtime\skipped-version.txt'
        if (Test-Path $skip) { Remove-Item $skip -Force -ErrorAction SilentlyContinue }

        @{ backupDir = $bkDir; newVersion = $RemoteVersion }
    } finally {
        if (Test-Path $work) { Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
