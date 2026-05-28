# ============================================================================
#  co-reader-writer.ps1 - Wraps ryzen-smu-cli for reading/writing CO
# ============================================================================
#  Used by  : server.ps1 (every CO endpoint), safety-guard.ps1 (step-back)
#  Wraps    : corecycler/tools/ryzen-smu-cli/ryzen-smu-cli.exe
#             (which talks to AMD's SMU registers via the PawnIO driver -
#              modern replacement for the deprecated WinRing0)
#
#  Why a CLI wrapper instead of P/Invoking PawnIO directly: the CLI is
#  bundled by CoreCycler, tested by sp00n's community, and gives us a
#  stable text protocol. We just parse its --get-offsets-terse output.
#
#  Output format we expect (parsed by ConvertFrom-CoToolOutput):
#       [preamble lines, maybe "Current PBO offsets:" header]
#       -10,-10,-10,-10,-10,-10,-10,-10,-20,-20,-20,-20,-20,-20,-20,-20
#
#  Range check on writes is -50..+50 - matches AMD's accepted range and
#  blocks accidental wild values from cargo-culted profiles.
# ============================================================================
Set-StrictMode -Version Latest
. "$PSScriptRoot\logging.ps1"

$script:RyzenSmuCli = $null

function Initialize-CoTool {
    param([string]$RepoRoot)
    $candidate = Join-Path $RepoRoot 'corecycler\tools\ryzen-smu-cli\ryzen-smu-cli.exe'
    if (-not (Test-Path $candidate)) {
        throw "ryzen-smu-cli.exe not found at $candidate. Run installer.ps1 first."
    }
    $script:RyzenSmuCli = $candidate
    Write-Log INFO "ryzen-smu-cli located at $candidate"
}

function Get-CoToolPath { $script:RyzenSmuCli }

# Parse ryzen-smu-cli --get-offsets-terse output into an int[].
# Per CoreCycler's reference implementation, the tool outputs:
#   [preamble lines, possibly "Current PBO offsets:" header]
#   -10,-10,-10,-10,-10,-10,-10,-10,-20,-20,-20,-20,-20,-20,-20,-20
#   (possibly trailing empty line)
# Strategy: take the LAST non-empty line, split by comma, parse each as int.
# Fallback: if that yields nothing, scan all lines for any line that looks
# like comma-separated integers (handles tool-version differences).
function ConvertFrom-CoToolOutput {
    param([string]$Output, [int]$ExpectedCount)

    $lines = @($Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

    function _parseCommaLine([string]$line) {
        $parts = $line -split ','
        $ints = @($parts | Where-Object { $_ -match '^\s*-?\d+\s*$' } | ForEach-Object { [int]$_.Trim() })
        # Require ALL comma-separated parts to be integers - otherwise this is not a data line
        if ($ints.Count -eq $parts.Count -and $ints.Count -gt 0) { return $ints }
        return $null
    }

    $values = $null
    if ($lines.Count -gt 0) {
        $values = _parseCommaLine $lines[-1]
    }
    if (-not $values) {
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $candidate = _parseCommaLine $lines[$i]
            if ($candidate) { $values = $candidate; break }
        }
    }
    if (-not $values) { $values = @() }

    Write-Log DEBUG "CO parser: $($values.Count) values from $($lines.Count) lines. Raw: $($Output -replace "`r?`n", ' | ')"

    if ($ExpectedCount -gt 0 -and $values.Count -ne $ExpectedCount) {
        Write-Log WARN "CO read returned $($values.Count) values, expected $ExpectedCount. Raw output: $Output"
    }
    , $values
}

function Get-AllCoreCo {
    param([int]$CoreCount)
    if (-not $script:RyzenSmuCli) { throw "Initialize-CoTool must be called first" }

    # Use System.Diagnostics.Process for proper stdout/stderr separation
    # (matches CoreCycler's approach and gives us cleaner output)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:RyzenSmuCli
    $psi.Arguments = '--get-offsets-terse'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $stdOut = $proc.StandardOutput.ReadToEnd()
    $stdErr = $proc.StandardError.ReadToEnd()
    if (-not $proc.WaitForExit(5000)) {
        try { $proc.Kill() } catch {}
        throw "ryzen-smu-cli --get-offsets-terse timed out after 5s"
    }
    $exitCode = $proc.ExitCode
    $proc.Dispose()

    if ($exitCode -ne 0) {
        $msg = "ryzen-smu-cli --get-offsets-terse failed (exit $exitCode). STDERR: $stdErr STDOUT: $stdOut"
        Write-Log ERROR $msg
        throw $msg
    }

    if ([string]::IsNullOrWhiteSpace($stdOut)) {
        $msg = "ryzen-smu-cli returned empty output. STDERR: $stdErr"
        Write-Log ERROR $msg
        throw $msg
    }

    $values = ConvertFrom-CoToolOutput -Output $stdOut -ExpectedCount $CoreCount

    if ($values.Count -ne $CoreCount) {
        # No silent padding - surface the real problem so we can fix the parser
        $msg = "CO read returned $($values.Count) values but expected $CoreCount. The tool's output format may differ from what's parsed. Raw output: $stdOut"
        Write-Log ERROR $msg
        throw $msg
    }
    , $values
}

function Set-AllCoreCo {
    param([int[]]$Values)
    if (-not $script:RyzenSmuCli) { throw "Initialize-CoTool must be called first" }
    foreach ($v in $Values) {
        if ($v -lt -50 -or $v -gt 50) { throw "CO value out of safe range: $v" }
    }
    $arg = ($Values -join ',')
    Write-Log INFO "Applying CO: $arg"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:RyzenSmuCli
    $psi.Arguments = "--offset $arg"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $stdOut = $proc.StandardOutput.ReadToEnd()
    $stdErr = $proc.StandardError.ReadToEnd()
    if (-not $proc.WaitForExit(5000)) {
        try { $proc.Kill() } catch {}
        throw "ryzen-smu-cli --offset timed out after 5s"
    }
    $exitCode = $proc.ExitCode
    $proc.Dispose()

    if ($exitCode -ne 0) {
        $msg = "ryzen-smu-cli --offset failed (exit $exitCode). STDERR: $stdErr STDOUT: $stdOut"
        Write-Log ERROR $msg
        throw $msg
    }
    Write-Log INFO "CO applied successfully"
}

function Reset-AllCoreCo {
    param([int]$CoreCount)
    $zeros = New-Object 'int[]' $CoreCount
    Set-AllCoreCo -Values $zeros
    Write-Log INFO "All $CoreCount cores reset to CO=0"
}
