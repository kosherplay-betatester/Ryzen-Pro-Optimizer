# ============================================================================
#  smart-tuner.ps1 - Orchestrator for Smart Auto-Adjust
# ============================================================================
#  Drives the per-scope bisection loop, applies CO values via the
#  existing co-reader-writer, integrates with the Safety Guard, and
#  persists session state after every probe so a crash mid-run is
#  recoverable. Wires the search engine, history store, mode policy,
#  narrative emitter, and probe wrapper together.
#
#  Public surface:
#    Start-SmartTune     -Mode -Direction
#    Stop-SmartTune
#    Resume-SmartTune
#    Discard-SmartTune
#    Get-SmartTuneState  (for /api/smart-tune/state)
#    Save-TuneSession / Load-TuneSession / Clear-TuneSession (also used
#                       on startup to detect a previous session)
# ============================================================================
Set-StrictMode -Version Latest

if (Get-Command Write-Log -ErrorAction SilentlyContinue) {} # logging optional in tests

function Save-TuneSession {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Session
    )
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.tmp"
    $Session | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Force $tmp $Path
}

function Load-TuneSession {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { Get-Content -Path $Path -Raw | ConvertFrom-Json } catch { $null }
}

function Clear-TuneSession {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue }
}

# Build the list of scopes to probe, in order. V-Cache CCD always first
# (failing fast on the tighter silicon is safer than failing late after
# a long Standard run). Per-core scopes appended when policy demands.
function Plan-TuneSession {
    param(
        [Parameter(Mandatory)]$Cpu,
        [Parameter(Mandatory)]$Policy
    )
    $scopes = New-Object System.Collections.Generic.List[object]
    $vCacheIdx = $Cpu.VCacheCcdIndex
    $ccdOrder = if ($null -ne $vCacheIdx) {
        @($vCacheIdx) + @(0..($Cpu.CcdCount - 1) | Where-Object { $_ -ne $vCacheIdx })
    } else {
        @(0..($Cpu.CcdCount - 1))
    }
    foreach ($ccd in $ccdOrder) {
        $start = $ccd * $Cpu.CoresPerCcd
        $cores = @($start..($start + $Cpu.CoresPerCcd - 1))
        $scopes.Add([PSCustomObject]@{
            id        = "CCD$ccd"
            isVCache  = ($null -ne $vCacheIdx -and $vCacheIdx -eq $ccd)
            cores     = $cores
            status    = 'PENDING'
            phase     = 'A'
        })
    }
    if ($Policy.refinePerCore) {
        for ($c = 0; $c -lt $Cpu.Cores; $c++) {
            $ccd = if ($Cpu.IsDualCcd) { [int]([Math]::Floor($c / $Cpu.CoresPerCcd)) } else { 0 }
            $scopes.Add([PSCustomObject]@{
                id        = "core$c"
                isVCache  = ($null -ne $vCacheIdx -and $vCacheIdx -eq $ccd)
                cores     = @($c)
                status    = 'PENDING'
                phase     = 'B'
            })
        }
    }
    , @($scopes.ToArray())
}

# One iteration of the bisection for one scope:
#   1. Compute candidate via Get-NextCandidate (modulated by telemetry)
#   2. Apply CO via $ApplyFn (caller's responsibility - usually
#      Set-AllCoreCo wrapped in panic-revert)
#   3. Run probe via $ProbeFn (returns one of the result strings)
#   4. Update state via Update-ScopeFromResult
#
# Factored so tests can inject a fake $ProbeFn and $ApplyFn - real
# orchestrator uses Invoke-Probe and Save-PanicRevertState + Set-AllCoreCo.
function Step-OneProbe {
    param(
        [Parameter(Mandatory)]$ScopeState,
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)][scriptblock]$ProbeFn,
        [Parameter(Mandatory)][scriptblock]$ApplyFn,
        [Parameter(Mandatory)][double]$TelemetryHeadroom
    )
    $candidate = Get-NextCandidate -ScopeState $ScopeState -TelemetryHeadroom $TelemetryHeadroom -Policy $Policy
    & $ApplyFn $candidate
    $result = & $ProbeFn
    Update-ScopeFromResult -ScopeState $ScopeState -Candidate $candidate -Result $result
}

# Returns a value in [0, 1] describing how far we are from the safety
# limits. 1.0 = lots of headroom, 0.0 = at or past a limit.
# Used by the search engine to shrink step sizes near the edge.
function Get-TelemetryHeadroom {
    param(
        $Snapshot,
        [Parameter(Mandatory)][int]$MaxTempC,
        [Parameter(Mandatory)][double]$MaxVid
    )
    if ($null -eq $Snapshot) { return 0.0 }
    $temp = if ($null -ne $Snapshot.packageTemp) { [double]$Snapshot.packageTemp } else { 0.0 }
    $vid  = 0.0
    foreach ($c in @($Snapshot.cores)) {
        if ($null -ne $c.voltage -and $c.voltage -gt $vid) { $vid = [double]$c.voltage }
    }
    $tHead = [Math]::Max(0.0, [Math]::Min(1.0, ($MaxTempC - $temp) / [double]$MaxTempC))
    $vHead = [Math]::Max(0.0, [Math]::Min(1.0, ($MaxVid  - $vid)  / [double]$MaxVid))
    [Math]::Min($tHead, $vHead)
}

# Loop Step-OneProbe until convergence or MaxProbes hit. Pure logic,
# I/O is in the injected scriptblocks.
function Tune-Scope {
    param(
        [Parameter(Mandatory)]$ScopeState,
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)][scriptblock]$ProbeFn,
        [Parameter(Mandatory)][scriptblock]$ApplyFn,
        [Parameter(Mandatory)][scriptblock]$HeadroomFn,
        [int]$MaxProbes = 12
    )
    $state = $ScopeState
    while (-not (Test-ScopeConverged -ScopeState $state) -and $state.probesCompleted -lt $MaxProbes) {
        $headroom = [double](& $HeadroomFn)
        $state = Step-OneProbe -ScopeState $state -Policy $Policy `
            -ProbeFn $ProbeFn -ApplyFn $ApplyFn -TelemetryHeadroom $headroom
    }
    $state
}

# In-memory orchestrator state. Reset by Stop-SmartTune.
$script:Tune = @{
    Status       = 'IDLE'        # IDLE | RUNNING | STOPPING | STOPPED | COMPLETED | FAILED
    SessionId    = $null
    StartedAt    = $null
    Mode         = $null
    Direction    = $null
    Cpu          = $null
    Policy       = $null
    Scopes       = @()           # array of @{id,isVCache,cores,status,locked,scopeState,...}
    CurrentIdx   = -1
    SessionPath  = $null
    HistoryPath  = $null
}

function Start-SmartTune {
    param(
        [Parameter(Mandatory)]$Cpu,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Direction,
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][string]$HistoryPath
    )
    Clear-TunerNarrative
    $policy = Get-ModePolicy -Mode $Mode -Direction $Direction
    $plan = Plan-TuneSession -Cpu $Cpu -Policy $policy

    $script:Tune.Status      = 'RUNNING'
    $script:Tune.SessionId   = [Guid]::NewGuid().ToString('N').Substring(0,8)
    $script:Tune.StartedAt   = (Get-Date).ToUniversalTime().ToString('o')
    $script:Tune.Mode        = $Mode
    $script:Tune.Direction   = $Direction
    $script:Tune.Cpu         = $Cpu
    $script:Tune.Policy      = $policy
    $script:Tune.Scopes      = $plan
    $script:Tune.CurrentIdx  = -1
    $script:Tune.SessionPath = $SessionPath
    $script:Tune.HistoryPath = $HistoryPath

    Write-TunerNarrative -Icon 'gear' -Message "Smart Tune started · $Mode · $Direction"
    Write-TunerNarrative -Icon 'target' -Message "Plan: $($plan.Count) scopes to tune"
    Save-TuneSession -Path $SessionPath -Session (Get-SmartTuneState -SinceSeqId 0)
}

function Stop-SmartTune {
    if ($script:Tune.Status -eq 'RUNNING') {
        Write-TunerNarrative -Icon 'gear' -Message 'Smart Tune stopped by user'
    }
    $script:Tune.Status = 'STOPPED'
}

function Discard-SmartTune {
    Stop-SmartTune
    if ($script:Tune.SessionPath) { Clear-TuneSession -Path $script:Tune.SessionPath }
    $script:Tune.Status = 'IDLE'
}

function Get-SmartTuneState {
    param([int]$SinceSeqId = 0)
    [PSCustomObject]@{
        status      = $script:Tune.Status
        sessionId   = $script:Tune.SessionId
        startedAt   = $script:Tune.StartedAt
        mode        = $script:Tune.Mode
        direction   = $script:Tune.Direction
        scopes      = @($script:Tune.Scopes)
        currentIdx  = $script:Tune.CurrentIdx
        narrative   = (Get-NewNarrativeEntries -SinceSeqId $SinceSeqId)
        latestSeqId = (Get-CurrentNarrativeSeqId)
    }
}

# One orchestrator tick: drives ONE probe of the current scope.
# Returns $true if there's more work, $false if the whole session is
# done. Designed to be called from the HTTP status handler so the
# server stays responsive between probes.
function Step-SmartTune {
    param(
        [Parameter(Mandatory)][scriptblock]$ProbeFn,
        [Parameter(Mandatory)][scriptblock]$ApplyFn,
        [Parameter(Mandatory)][scriptblock]$HeadroomFn,
        [int]$MaxProbesPerScope = 12
    )
    if ($script:Tune.Status -ne 'RUNNING') { return $false }
    if ($script:Tune.Scopes.Count -eq 0)  { $script:Tune.Status = 'COMPLETED'; return $false }

    # Advance to next pending scope if needed
    if ($script:Tune.CurrentIdx -lt 0 -or
        $script:Tune.CurrentIdx -ge $script:Tune.Scopes.Count -or
        $script:Tune.Scopes[$script:Tune.CurrentIdx].status -in 'LOCKED','FAILED') {

        $next = -1
        for ($i = 0; $i -lt $script:Tune.Scopes.Count; $i++) {
            if ($script:Tune.Scopes[$i].status -eq 'PENDING') { $next = $i; break }
        }
        if ($next -lt 0) {
            $script:Tune.Status = 'COMPLETED'
            Write-TunerNarrative -Icon 'lock' -Message 'All scopes locked. Smart Tune complete.'
            Save-TuneSession -Path $script:Tune.SessionPath -Session (Get-SmartTuneState -SinceSeqId 0)
            return $false
        }
        $script:Tune.CurrentIdx = $next
        $sc = $script:Tune.Scopes[$next]
        $sc | Add-Member -NotePropertyName scopeState -NotePropertyValue (
            New-ScopeState -ScopeId $sc.id -IsVCache $sc.isVCache -SeedValue 0 -Policy $script:Tune.Policy
        ) -Force
        $sc.status = 'PROBING'
        Write-TunerNarrative -Icon 'arrow' -Message "Starting scope $($sc.id)" -Payload @{ scope = $sc.id }
    }

    $cur = $script:Tune.Scopes[$script:Tune.CurrentIdx]
    if ($cur.scopeState.probesCompleted -ge $MaxProbesPerScope) {
        # Out of probe budget without convergence - mark FAILED and move on
        $cur.status = 'FAILED'
        Write-TunerNarrative -Icon 'warn' -Message "Scope $($cur.id) exceeded probe budget without converging"
        Save-TuneSession -Path $script:Tune.SessionPath -Session (Get-SmartTuneState -SinceSeqId 0)
        return $true
    }

    if (Test-ScopeConverged -ScopeState $cur.scopeState) {
        $locked = Get-LockInValue -ScopeState $cur.scopeState -Policy $script:Tune.Policy
        if ($null -ne $locked) {
            $cur | Add-Member -NotePropertyName locked -NotePropertyValue $locked -Force
            $cur.status = 'LOCKED'
            Write-TunerNarrative -Icon 'lock' -Message "Locked $($cur.id) at $locked" -Payload @{ scope = $cur.id; value = $locked }
        } else {
            $cur.status = 'FAILED'
            Write-TunerNarrative -Icon 'warn' -Message "Scope $($cur.id) failed to find a stable value in range"
        }
        Save-TuneSession -Path $script:Tune.SessionPath -Session (Get-SmartTuneState -SinceSeqId 0)
        return $true
    }

    # Do one probe
    $headroom = [double](& $HeadroomFn)
    $cand = Get-NextCandidate -ScopeState $cur.scopeState -TelemetryHeadroom $headroom -Policy $script:Tune.Policy
    Write-TunerNarrative -Icon 'arrow' -Message "Probe $($cur.scopeState.probesCompleted + 1) of $($cur.id): trying CO=$cand" -Payload @{ scope=$cur.id; value=$cand }
    & $ApplyFn $cand
    $result = & $ProbeFn
    $cur.scopeState = Update-ScopeFromResult -ScopeState $cur.scopeState -Candidate $cand -Result $result

    $icon = switch ($result) { 'PASS' {'pass'} 'FAIL_WHEA' {'warn'} default {'fail'} }
    Write-TunerNarrative -Icon $icon -Message "$($cur.id) probe $($cur.scopeState.probesCompleted): $result at CO=$cand" -Payload @{ scope=$cur.id; value=$cand; result=$result }

    # Append to history
    if ($script:Tune.HistoryPath) {
        Add-HistoryEntry -Path $script:Tune.HistoryPath -Entry @{
            cpuModel  = $script:Tune.Cpu.Name
            scope     = $cur.id
            value     = $cand
            result    = $result
            mode      = $script:Tune.Mode
            sessionId = $script:Tune.SessionId
        }
    }
    Save-TuneSession -Path $script:Tune.SessionPath -Session (Get-SmartTuneState -SinceSeqId 0)
    $true
}
