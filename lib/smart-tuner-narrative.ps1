# ============================================================================
#  smart-tuner-narrative.ps1 - Narrative log emitter + ring buffer
# ============================================================================
#  Every orchestrator state change calls Write-TunerNarrative to record
#  what's happening. Browser polls /api/smart-tune/state?since=<seqId>
#  and only gets new entries - efficient and ordering-safe.
#
#  Why a ring buffer instead of streaming straight to disk: the browser
#  needs entries quickly (1Hz poll), and re-reading a growing file
#  every poll is wasteful. We mirror to log file too (server.log via
#  Write-Log) for forensic value, but the live buffer is in-memory.
# ============================================================================
Set-StrictMode -Version Latest

$script:NarrativeBuffer = [System.Collections.Generic.List[object]]::new()
$script:NarrativeSeqId  = 0
$script:NarrativeMax    = 500

function Write-TunerNarrative {
    param(
        [Parameter(Mandatory)][string]$Icon,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Payload = $null
    )
    $script:NarrativeSeqId++
    $entry = [PSCustomObject]@{
        seqId   = $script:NarrativeSeqId
        ts      = (Get-Date).ToUniversalTime().ToString('o')
        icon    = $Icon
        message = $Message
        payload = if ($Payload) { [PSCustomObject]$Payload } else { $null }
    }
    $script:NarrativeBuffer.Add($entry)
    while ($script:NarrativeBuffer.Count -gt $script:NarrativeMax) {
        $script:NarrativeBuffer.RemoveAt(0)
    }
    # Mirror to server.log if logging is available
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log INFO ("TUNE {0} {1}" -f $Icon, $Message)
    }
    $entry
}

function Get-NewNarrativeEntries {
    param([Parameter(Mandatory)][int]$SinceSeqId)
    , @($script:NarrativeBuffer | Where-Object { $_.seqId -gt $SinceSeqId })
}

function Clear-TunerNarrative {
    $script:NarrativeBuffer.Clear()
    $script:NarrativeSeqId = 0
}

function Get-CurrentNarrativeSeqId { $script:NarrativeSeqId }
