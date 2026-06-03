# ============================================================================
#  update.ps1 - Auto-update orchestrator (called from Launch.bat / Update.bat)
# ============================================================================
#  Behavior:
#    -Force  : ignore rate-limit + skip-version marker (Update.bat passes this)
#    default : called by Launch.bat on every launch; gated by 6h cache so we
#              don't hit GitHub on rapid restart cycles
#
#  Decision tree:
#    1. Pre-flight: another instance? mid-tune? -> skip silently, continue
#    2. Rate-limit (-Force bypasses) -> if too soon, exit silently
#    3. Probe remote version (5s timeout) -> if offline, warn + continue
#    4. Compare versions -> if local >= remote, "up to date" + exit
#    5. Skip-marker matches remote -> note + exit
#    6. PROMPT (default Y) -> Y applies; N skips this run; S skips the version
#    7. On Y: download, backup, overlay, log path of backup
#
#  Never throws to the caller. Launch.bat continues either way.
# ============================================================================
param([switch]$Force)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\updater.ps1"

function Write-Banner {
    param([string]$Text, [ConsoleColor]$Color = 'Cyan')
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor $Color
    Write-Host "  $Text" -ForegroundColor $Color
    Write-Host ('=' * 62) -ForegroundColor $Color
}

try {
    $repoRoot = $PSScriptRoot
    $local    = Get-LocalRpoVersion -RepoRoot $repoRoot

    if (Test-RpoInstanceRunning) {
        Write-Host "Another Ryzen Pro Optimizer instance appears to be running (port 8765)." -ForegroundColor Yellow
        Write-Host "Skipping update check - close it first to update." -ForegroundColor Yellow
        return
    }
    if (Test-RpoActiveTune -RepoRoot $repoRoot) {
        Write-Host "A tune session is in progress on disk (panic-revert or running state file)." -ForegroundColor Yellow
        Write-Host "Skipping update check to avoid clobbering it. Resolve in the UI first." -ForegroundColor Yellow
        return
    }
    if (-not (Test-RpoShouldCheckNow -RepoRoot $repoRoot -Force:$Force)) {
        # Rate-limited - silently continue. Verbose path is via Update.bat.
        return
    }

    Write-Host "Checking for Ryzen Pro Optimizer updates (current: v$local)..." -ForegroundColor DarkGray
    Update-RpoCheckStamp -RepoRoot $repoRoot

    $remote = $null
    try {
        $remote = Get-RemoteRpoVersion -TimeoutSec 5
    } catch {
        Write-Host "Couldn't reach update server: $($_.Exception.Message). Launching with current version." -ForegroundColor Yellow
        return
    }

    if (-not (Test-RpoNewerVersion -Local $local -Remote $remote)) {
        Write-Host "Up to date (v$local)." -ForegroundColor Green
        return
    }

    $skipped = Get-RpoSkippedVersion -RepoRoot $repoRoot
    if ((-not $Force) -and $skipped -eq $remote) {
        Write-Host "Update v$remote available - skipping per previous user choice. Run Update.bat to install." -ForegroundColor DarkGray
        return
    }

    Write-Banner "UPDATE AVAILABLE: v$local  ->  v$remote" Yellow
    Write-Host "  Strongly recommended. Your profiles, history, and runtime"
    Write-Host "  state are preserved by the updater."
    Write-Host ''
    Write-Host "  [Y] Update now (recommended)" -ForegroundColor Green
    Write-Host "  [N] Not this time"
    Write-Host "  [S] Skip this version (don't ask again until v$remote+1)"
    Write-Host ''
    $choice = Read-Host "Choice (Y/N/S, default Y)"
    if (-not $choice) { $choice = 'Y' }

    switch ($choice.ToUpper()) {
        'N' {
            Write-Host "OK - launching v$local. You'll be prompted again next time." -ForegroundColor DarkGray
            return
        }
        'S' {
            Set-RpoSkippedVersion -RepoRoot $repoRoot -Version $remote
            Write-Host "OK - v$remote marked as skipped. Use Update.bat to install anyway." -ForegroundColor DarkGray
            return
        }
        default {
            # fall through to update
        }
    }

    Write-Host ''
    Write-Host "Downloading v$remote..." -ForegroundColor Cyan
    $result = $null
    try {
        $result = Invoke-RpoUpdate -RepoRoot $repoRoot -RemoteVersion $remote
    } catch {
        Write-Host ''
        Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Your install is unchanged. Continuing with v$local." -ForegroundColor Yellow
        return
    }

    Write-Banner "UPDATED: v$local  ->  v$remote" Green
    Write-Host "  Backup of previous version: $($result.backupDir)" -ForegroundColor DarkGray
    Write-Host "  Restore by copying its contents back into the install folder." -ForegroundColor DarkGray
    Write-Host ''

} catch {
    # Last-ditch catch so a launcher boot is never blocked by an updater bug.
    Write-Host "Updater error (ignored): $($_.Exception.Message)" -ForegroundColor Yellow
}
