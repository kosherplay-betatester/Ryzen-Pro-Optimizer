# ============================================================================
#  corecycler-runner.ps1 - Subprocess manager for CoreCycler
# ============================================================================
#  Used by  : server.ps1 (test-start, test-stop, status poll)
#  Wraps    : corecycler/script-corecycler.ps1 (an external project)
#
#  Lifecycle:
#    1. New-CoreCyclerConfig  - generates runtime/generated-config.ini
#       from the UI selections (Prime95 mode, iterations, cores, auto-
#       adjust settings)
#    2. Start-CoreCyclerRun   - backs up CoreCycler's own config.ini,
#       swaps in ours, spawns the script in a new visible cmd window
#       so the user can see the test live, then discovers the log file
#       path so we can tail it
#    3. Get-LiveStatus        - tails the log to extract current core,
#       iteration, error/WHEA counts (shown in the UI status card)
#    4. Stop-CoreCyclerRun    - tries Ctrl+C via the Win32 console API
#       (clean shutdown); falls back to Stop-Process force if that fails.
#       Also kills any orphaned prime95.exe children.
#    5. Restores CoreCycler's original config.ini (we backed it up).
#
#  Why we run CoreCycler instead of reimplementing Prime95 orchestration:
#  sp00n's script has years of community testing on Ryzen quirks (HT
#  affinity, P-core/E-core gotchas on Intel, log formats), and we
#  benefit from every update by just refreshing the corecycler/ folder.
# ============================================================================
Set-StrictMode -Version Latest
. "$PSScriptRoot\logging.ps1"

$script:CcProcess = $null
$script:CcDir = $null
$script:LastLogPath = $null
$script:LastPrimeLogPath = $null
$script:GeneratedConfigPath = $null

function Initialize-CoreCyclerRunner {
    param([string]$RepoRoot)
    $script:CcDir = Join-Path $RepoRoot 'corecycler'
    if (-not (Test-Path (Join-Path $script:CcDir 'script-corecycler.ps1'))) {
        throw "CoreCycler not installed at $script:CcDir. Run Install.bat."
    }
    Write-Log INFO "CoreCycler runner initialized at $script:CcDir"
}

function New-CoreCyclerConfig {
    param(
        [string]$RepoRoot,
        [string]$StressTestProgram = 'PRIME95',
        [string]$Mode = 'SSE',
        [string]$RuntimePerCore = '6m',
        [int]$MaxIterations = 1,
        [int[]]$CoresToTest,
        [Parameter(Mandatory)][int]$TotalCores,
        [bool]$EnableAutomaticAdjustment = $false,
        [int[]]$AutoStartValues = $null,
        [int]$AutoMaxValue = 0,
        [int]$AutoIncrementBy = 1
    )
    $ignored = @()
    if ($null -ne $CoresToTest) {
        for ($i = 0; $i -lt $TotalCores; $i++) {
            if ($CoresToTest -notcontains $i) { $ignored += $i }
        }
    }

    $stopOnError = if ($EnableAutomaticAdjustment) { 0 } else { 0 }
    $skipOnError = if ($EnableAutomaticAdjustment) { 0 } else { 1 }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('[General]')
    [void]$sb.AppendLine("stressTestProgram = $StressTestProgram")
    [void]$sb.AppendLine("runtimePerCore = $RuntimePerCore")
    [void]$sb.AppendLine('numberOfThreads = 1')
    [void]$sb.AppendLine("maxIterations = $MaxIterations")
    [void]$sb.AppendLine("coresToIgnore = $($ignored -join ', ')")
    [void]$sb.AppendLine("skipCoreOnError = $skipOnError")
    [void]$sb.AppendLine("stopOnError = $stopOnError")
    [void]$sb.AppendLine('beepOnError = 0')
    [void]$sb.AppendLine('flashOnError = 0')
    [void]$sb.AppendLine('lookForWheaErrors = 1')
    [void]$sb.AppendLine('treatWheaWarningAsError = 1')
    [void]$sb.AppendLine('restartTestProgramForEachCore = 1')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[Prime95]')
    [void]$sb.AppendLine("mode = $Mode")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[Logging]')
    [void]$sb.AppendLine('logLevel = 4')
    [void]$sb.AppendLine('useWindowsEventLog = 1')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[AutomaticTestMode]')
    [void]$sb.AppendLine("enableAutomaticAdjustment = $([int]$EnableAutomaticAdjustment)")
    if ($EnableAutomaticAdjustment) {
        $sv = if ($AutoStartValues) { ($AutoStartValues -join ' ') } else { 'CurrentValues' }
        [void]$sb.AppendLine("startValues = $sv")
        [void]$sb.AppendLine("maxValue = $AutoMaxValue")
        [void]$sb.AppendLine("incrementBy = $AutoIncrementBy")
        [void]$sb.AppendLine('repeatCoreOnError = 1')
    }

    $runtimeDir = Join-Path $RepoRoot 'runtime'
    if (-not (Test-Path $runtimeDir)) { New-Item -ItemType Directory -Path $runtimeDir | Out-Null }
    $configPath = Join-Path $runtimeDir 'generated-config.ini'
    Set-Content -Path $configPath -Value $sb.ToString()
    $script:GeneratedConfigPath = $configPath
    Write-Log INFO "Generated CoreCycler config at $configPath"
    $configPath
}

function Start-CoreCyclerRun {
    param([string]$ConfigPath)
    if (-not $script:CcDir) { throw "Initialize-CoreCyclerRunner must be called first" }

    $ccConfig = Join-Path $script:CcDir 'config.ini'
    $ccConfigBak = Join-Path $script:CcDir 'config.ini.rpo-backup'

    if (Test-Path $ccConfig) {
        Copy-Item -Force $ccConfig $ccConfigBak
        Write-Log DEBUG "Backed up CoreCycler config.ini -> config.ini.rpo-backup"
    }
    Copy-Item -Force $ConfigPath $ccConfig

    $ccScript = Join-Path $script:CcDir 'script-corecycler.ps1'

    # Spawn in a new console window so user can see CoreCycler's output
    $script:CcProcess = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$ccScript`"") `
        -WorkingDirectory $script:CcDir `
        -WindowStyle Normal `
        -PassThru

    Write-Log INFO "CoreCycler started, PID $($script:CcProcess.Id)"

    # Discover the log file it creates (after a brief wait)
    $logDir = Join-Path $script:CcDir 'logs'
    Start-Sleep -Milliseconds 2500
    if (Test-Path $logDir) {
        $latest = Get-ChildItem -Path $logDir -Filter 'CoreCycler_*.log' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { $script:LastLogPath = $latest.FullName }
        $latestPrime = Get-ChildItem -Path $logDir -Filter 'Prime95_*.log' -ErrorAction SilentlyContinue |
                       Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestPrime) { $script:LastPrimeLogPath = $latestPrime.FullName }
        Write-Log INFO "Detected logs: CoreCycler=$script:LastLogPath Prime95=$script:LastPrimeLogPath"
    }
}

function Stop-CoreCyclerRun {
    if ($null -eq $script:CcProcess -or $script:CcProcess.HasExited) { return }
    try {
        # Try graceful Ctrl+C via console signal first
        try {
            # Best effort - uses native API; may not work if CoreCycler is in its own console
            $sigSent = $false
            $kernel32 = Add-Type -Name K32 -Namespace W32 -PassThru -MemberDefinition @'
                [DllImport("kernel32.dll")] public static extern bool AttachConsole(uint dwProcessId);
                [DllImport("kernel32.dll")] public static extern bool FreeConsole();
                [DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);
                [DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
'@ -ErrorAction SilentlyContinue
            if ($kernel32) {
                if ($kernel32::AttachConsole([uint32]$script:CcProcess.Id)) {
                    [void]$kernel32::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
                    [void]$kernel32::GenerateConsoleCtrlEvent(0, 0)  # 0 = CTRL_C_EVENT
                    Start-Sleep -Milliseconds 1500
                    [void]$kernel32::SetConsoleCtrlHandler([IntPtr]::Zero, $false)
                    [void]$kernel32::FreeConsole()
                    $sigSent = $true
                }
            }
            if (-not $sigSent -or -not $script:CcProcess.HasExited) {
                Start-Sleep -Milliseconds 1500
                if (-not $script:CcProcess.HasExited) {
                    Stop-Process -Id $script:CcProcess.Id -Force -ErrorAction SilentlyContinue
                    Write-Log INFO "CoreCycler force-stopped"
                } else {
                    Write-Log INFO "CoreCycler stopped via Ctrl+C"
                }
            }
        } catch {
            Stop-Process -Id $script:CcProcess.Id -Force -ErrorAction SilentlyContinue
            Write-Log WARN "Stop fallback to force kill: $($_.Exception.Message)"
        }
    } finally {
        # Also kill any Prime95 child processes that may have been left behind
        Get-Process -Name 'prime95' -ErrorAction SilentlyContinue | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
        $script:CcProcess = $null
    }

    # Restore original CoreCycler config.ini
    $ccConfig = Join-Path $script:CcDir 'config.ini'
    $ccConfigBak = Join-Path $script:CcDir 'config.ini.rpo-backup'
    if (Test-Path $ccConfigBak) {
        Copy-Item -Force $ccConfigBak $ccConfig
        Remove-Item -Force $ccConfigBak
    }
}

function Test-CoreCyclerRunning {
    $null -ne $script:CcProcess -and -not $script:CcProcess.HasExited
}

function Get-LatestLogs {
    @{
        coreCyclerLog = $script:LastLogPath
        prime95Log = $script:LastPrimeLogPath
    }
}

function Parse-LiveStatus {
    # Accept anything (null, empty string, single line, array). PowerShell's
    # [string[]] parameter binding rejects bare empty strings ("") even
    # with [AllowEmptyCollection()], which Get-Content can produce when a
    # log has exactly one empty line. Coerce inside the function instead.
    param([object]$LogLines = $null)
    $info = @{
        currentCore     = $null
        iteration       = $null
        iterationsTotal = $null
        errors          = 0
        wheaErrors      = 0
        runtime         = $null
    }
    if ($null -eq $LogLines -or $LogLines -eq '') { return $info }
    $lines = @($LogLines)
    foreach ($line in $lines) {
        if ($line -match 'Set to Core (\d+)') { $info.currentCore = [int]$Matches[1] }
        elseif ($line -match 'Iteration (\d+)/(\d+)') { $info.iteration = [int]$Matches[1]; $info.iterationsTotal = [int]$Matches[2] }
        elseif ($line -match 'cores with an error so far:\s+(\d+)') { $info.errors = [int]$Matches[1] }
        elseif ($line -match 'cores with a WHEA error so far:\s+(\d+)') { $info.wheaErrors = [int]$Matches[1] }
        elseif ($line -match 'Runtime (\d{2}h \d{2}m \d{2}s)') { $info.runtime = $Matches[1] }
    }
    $info
}

function Parse-LiveCoreStats {
    # Per-core breakdown from a CoreCycler log tail. Walks lines in order,
    # using "Set to Core N" as a divider to attribute iterations/errors to
    # the core that was active when the event fired. WHEA totals come from
    # CoreCycler's running aggregate ("cores with a WHEA error so far: N"),
    # delta-attributed to whichever core was current when the count moved.
    # Returns an array of @{ core; iterations; iterationsTotal; errors;
    # whea; status } ordered by first-tested. Empty array on empty input.
    # NB: keyed by [int] but stored in @{} (not [ordered]@{}) - the
    # OrderedDictionary indexer treats int as a positional index, which
    # blows up on first access. Order is tracked separately.
    param([object]$LogLines = $null)
    if ($null -eq $LogLines -or $LogLines -eq '') { return @() }
    $lines = @($LogLines)
    $perCore = @{}
    $order = New-Object System.Collections.Generic.List[int]
    $curCore = $null
    $wheaTotal = 0
    $sawComplete = $false

    foreach ($line in $lines) {
        if ($line -match 'Set to Core (\d+)') {
            $curCore = [int]$Matches[1]
            if (-not $perCore.ContainsKey($curCore)) {
                $perCore[$curCore] = @{
                    core            = $curCore
                    iterations      = 0
                    iterationsTotal = 0
                    errors          = 0
                    whea            = 0
                    status          = 'testing'
                }
                $order.Add($curCore)
            }
        }
        elseif ($null -ne $curCore -and $line -match 'Iteration (\d+)/(\d+)') {
            $iter = [int]$Matches[1]; $tot = [int]$Matches[2]
            $entry = $perCore[$curCore]
            if ($iter -gt $entry.iterations) { $entry.iterations = $iter }
            $entry.iterationsTotal = $tot
        }
        elseif ($null -ne $curCore -and ($line -match 'core_error\b' -or $line -match 'has thrown an error\b' -or $line -match '\bcore \d+ (has )?errored\b')) {
            $perCore[$curCore].errors++
        }
        elseif ($line -match 'cores with a WHEA error so far:\s*(\d+)') {
            $n = [int]$Matches[1]
            if ($n -gt $wheaTotal -and $null -ne $curCore) {
                $perCore[$curCore].whea += ($n - $wheaTotal)
            }
            $wheaTotal = $n
        }
        elseif ($line -match 'Test completed in') { $sawComplete = $true }
    }

    if ($order.Count -eq 0) { return @() }

    # Status: cores other than the most recently activated are settled
    # ("passed" if clean, "failed" if any error/WHEA). The most recent is
    # still "testing" unless we hit a global "Test completed in" marker.
    $lastKey = $order[$order.Count - 1]
    foreach ($k in $order) {
        $c = $perCore[$k]
        if ($k -ne $lastKey -or $sawComplete) {
            $c.status = if ($c.errors -gt 0 -or $c.whea -gt 0) { 'failed' } else { 'passed' }
        }
    }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($k in $order) { $result.Add($perCore[$k]) }
    $result.ToArray()
}

function Get-LiveStatus {
    if (-not $script:LastLogPath -or -not (Test-Path $script:LastLogPath)) { return $null }
    try {
        $tail = Get-Content -Path $script:LastLogPath -Tail 500 -ErrorAction SilentlyContinue
        $info = Parse-LiveStatus -LogLines $tail
        $info.perCore = Parse-LiveCoreStats -LogLines $tail
        $info
    } catch {
        $null
    }
}

# Classify a probe's outcome from CoreCycler + Prime95 log tails.
# WHEA wins (worst class), then P95 errors, then TIMEOUT if process
# didn't exit cleanly, else PASS. The caller layers ABORT_SAFETY on
# top by checking the Safety Guard separately.
function Test-CoreCyclerProbeResult {
    # Same defensive pattern as Parse-LiveStatus. [string[]] binding can
    # reject a bare empty string even with AllowEmptyCollection; using
    # [object] + coerce-inside is bulletproof across every weird thing
    # Get-Content can return (null, "", single line, array, locked file).
    param(
        [object]$LogLines = $null,
        [object]$PrimeLines = $null,
        [Parameter(Mandatory)][bool]$ExitedCleanly
    )
    $LogLines   = if ($null -eq $LogLines -or $LogLines -eq '')   { @() } else { @($LogLines) }
    $PrimeLines = if ($null -eq $PrimeLines -or $PrimeLines -eq '') { @() } else { @($PrimeLines) }
    foreach ($l in $LogLines) {
        if ($l -match 'cores with a WHEA error so far:\s*([1-9])') { return 'FAIL_WHEA' }
    }
    foreach ($l in $LogLines) {
        if ($l -match 'cores with an error so far:\s*([1-9])') { return 'FAIL_P95' }
        if ($l -match 'has thrown an error|core_error|core .* errored') { return 'FAIL_P95' }
    }
    foreach ($l in $PrimeLines) {
        if ($l -match 'FATAL ERROR|Rounding was|Hardware failure') { return 'FAIL_P95' }
    }
    if (-not $ExitedCleanly) { return 'TIMEOUT' }
    'PASS'
}

# Invoke a single-iteration probe on one scope (a CCD-group or a single
# core). Blocks until CoreCycler exits or TimeoutSeconds elapses, then
# returns one of PASS/FAIL_P95/FAIL_WHEA/TIMEOUT. Wraps:
#   1. New-CoreCyclerConfig (generate a single-iteration config)
#   2. Start-CoreCyclerRun  (spawn the subprocess)
#   3. wait loop with periodic safety inspection (caller supplies callback)
#   4. classify result and return
#
# Parameters:
#   $RepoRoot        - project root (passed to New-CoreCyclerConfig)
#   $ScopeCores      - int[] of physical core indices to test (whole CCD or one core)
#   $TotalCores      - total physical cores (passed to New-CoreCyclerConfig)
#   $ProbeRuntimeMin - mode.probeRuntimeMin (sets runtimePerCore)
#   $TimeoutSeconds  - how long to wait before forcing TIMEOUT
#   $TickCallback    - optional scriptblock invoked once a second; if it
#                      returns $true, probe is aborted as ABORT_SAFETY
function Invoke-Probe {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][int[]]$ScopeCores,
        [Parameter(Mandatory)][int]$TotalCores,
        [Parameter(Mandatory)][double]$ProbeRuntimeMin,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [scriptblock]$TickCallback = $null
    )
    $rtFmt = "{0}m" -f [int][Math]::Max(1, [Math]::Round($ProbeRuntimeMin))
    $cfg = New-CoreCyclerConfig -RepoRoot $RepoRoot `
        -StressTestProgram 'PRIME95' -Mode 'SSE' -MaxIterations 1 `
        -RuntimePerCore $rtFmt -CoresToTest $ScopeCores -TotalCores $TotalCores `
        -EnableAutomaticAdjustment $false
    Start-CoreCyclerRun -ConfigPath $cfg
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $aborted = $false
    while (Test-CoreCyclerRunning) {
        Start-Sleep -Seconds 1
        if ($TickCallback) {
            if ((& $TickCallback)) { $aborted = $true; break }
        }
        if ((Get-Date) -gt $deadline) { break }
    }
    $cleanExit = (-not (Test-CoreCyclerRunning))
    if (-not $cleanExit) {
        try { Stop-CoreCyclerRun } catch {}
    }
    if ($aborted) { return 'ABORT_SAFETY' }
    $logs = Get-LatestLogs
    # Wrap in @(...) so a 0- or 1-line log (very common for a probe that
    # exited fast) collapses to an empty/1-element array rather than $null
    # or a bare empty string. Test-CoreCyclerProbeResult declares
    # [string[]] $LogLines as Mandatory; an empty string would fail the
    # binding even though [AllowEmptyCollection()] is set.
    $ccLines = @()
    $primeLines = @()
    if ($logs.coreCyclerLog -and (Test-Path $logs.coreCyclerLog)) {
        $ccLines = @(Get-Content -Path $logs.coreCyclerLog -ErrorAction SilentlyContinue)
    }
    if ($logs.prime95Log -and (Test-Path $logs.prime95Log)) {
        $primeLines = @(Get-Content -Path $logs.prime95Log -ErrorAction SilentlyContinue)
    }
    Test-CoreCyclerProbeResult -LogLines $ccLines -PrimeLines $primeLines -ExitedCleanly $cleanExit
}
