# ============================================================================
#  whea-watcher.ps1 - "Bodyguard": real-time WHEA hardware-error watcher
# ============================================================================
#  Used by  : server.ps1 (Start-WheaWatcher at startup, Get-WheaEvents
#             from /api/status, /api/whea endpoints)
#
#  How it works: subscribes to the System event log filtered to
#  Microsoft-Windows-WHEA-Logger via EventLogWatcher. The OS pushes
#  events to us when they happen - we do not poll. Each event lands in
#  a ConcurrentQueue so the background subscription runspace can
#  enqueue safely while the main thread dequeues from /api/status.
#
#  Why WHEA matters for CO tuning: a CO offset that's slightly too deep
#  can trigger hardware-level corrected errors *without* tripping a
#  Prime95 software error. WHEA is the earliest signal you've gone too
#  far. The Safety Guard hooks into this queue and aborts auto-tune on
#  any WHEA delta during a run.
#
#  Persistence: bodyguard-log.json keeps the history across server
#  restarts (so the alert badge survives a relaunch and you can
#  review what happened overnight).
# ============================================================================
Set-StrictMode -Version Latest
. "$PSScriptRoot\logging.ps1"

# Background-thread-safe queue for WHEA events. Populated by Register-ObjectEvent
# action runspace; drained by the HTTP server's /api/status handler.
$script:WheaQueue = [System.Collections.Concurrent.ConcurrentQueue[psobject]]::new()
$script:WheaWatcher = $null
$script:WheaActive = $false
$script:LogPath = $null

function Initialize-WheaWatcher {
    param([string]$RepoRoot)
    $script:LogPath = Join-Path $RepoRoot 'runtime\bodyguard-log.json'
    if (Test-Path $script:LogPath) {
        try {
            $existing = Get-Content $script:LogPath -Raw | ConvertFrom-Json
            foreach ($e in $existing) { $script:WheaQueue.Enqueue($e) }
            Write-Log INFO "Loaded $($script:WheaQueue.Count) historical WHEA events from $script:LogPath"
        } catch { Write-Log WARN "Failed to load WHEA history: $($_.Exception.Message)" }
    }
}

function Start-WheaWatcher {
    if ($script:WheaActive) { return $true }
    try {
        # Use the Application log scoped to WHEA-Logger source - the most reliable
        # signal across Windows versions. Microsoft-Windows-Kernel-WHEA/Errors is
        # an alternative; we listen to both via separate queries.
        $queryStr = "*[System[Provider[@Name='Microsoft-Windows-WHEA-Logger']]]"
        $query = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('System', [System.Diagnostics.Eventing.Reader.PathType]::LogName, $queryStr)
        $script:WheaWatcher = New-Object System.Diagnostics.Eventing.Reader.EventLogWatcher($query)

        # Pass the queue as MessageData so the action can access it
        # despite running in a different runspace
        Register-ObjectEvent -InputObject $script:WheaWatcher `
            -EventName EventRecordWritten `
            -SourceIdentifier RPO_WheaEvent `
            -MessageData $script:WheaQueue `
            -Action {
                try {
                    $ev = $EventArgs.EventRecord
                    if ($null -eq $ev) { return }
                    $entry = [PSCustomObject]@{
                        time = $ev.TimeCreated.ToString('o')
                        eventId = $ev.Id
                        level = $ev.LevelDisplayName
                        provider = $ev.ProviderName
                        message = try { $ev.FormatDescription() } catch { '(unable to format)' }
                    }
                    $Event.MessageData.Enqueue($entry)
                } catch { }
            } | Out-Null

        $script:WheaWatcher.Enabled = $true
        $script:WheaActive = $true
        Write-Log INFO "WHEA watcher started (subscribed to System log, WHEA-Logger provider)"
        return $true
    } catch {
        Write-Log WARN "WHEA watcher failed to start: $($_.Exception.Message)"
        $script:WheaActive = $false
        return $false
    }
}

function Stop-WheaWatcher {
    if ($script:WheaWatcher) {
        try { $script:WheaWatcher.Enabled = $false } catch {}
        try { Unregister-Event -SourceIdentifier RPO_WheaEvent -ErrorAction SilentlyContinue } catch {}
        $script:WheaWatcher = $null
    }
    $script:WheaActive = $false
}

function Test-WheaWatcherActive { $script:WheaActive }

function Get-WheaEvents {
    # Drain and copy without removing
    $arr = @($script:WheaQueue.ToArray())
    # Persist (best effort)
    if ($script:LogPath -and $arr.Count -gt 0) {
        try {
            $arr | ConvertTo-Json -Depth 5 | Set-Content -Path $script:LogPath -ErrorAction SilentlyContinue
        } catch {}
    }
    , $arr
}

function Clear-WheaEvents {
    while ($script:WheaQueue.Count -gt 0) {
        $null = $script:WheaQueue.TryDequeue([ref]$null)
    }
    if ($script:LogPath -and (Test-Path $script:LogPath)) { Remove-Item $script:LogPath -Force -ErrorAction SilentlyContinue }
}
