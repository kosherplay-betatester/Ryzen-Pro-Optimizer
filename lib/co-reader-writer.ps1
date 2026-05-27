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

# Parse ryzen-smu-cli --get-offsets-terse output into an int[]
# Format observed: one integer per line, optionally with whitespace.
# Some versions also use comma-separation on a single line.
function ConvertFrom-CoToolOutput {
    param([string]$Output, [int]$ExpectedCount)
    $values = @()
    foreach ($line in ($Output -split "`r?`n")) {
        $trim = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trim)) { continue }
        # Split on comma or whitespace
        foreach ($part in ($trim -split '[,\s]+' | Where-Object { $_ -ne '' })) {
            if ($part -match '^-?\d+$') {
                $values += [int]$part
            }
        }
    }
    if ($ExpectedCount -gt 0 -and $values.Count -ne $ExpectedCount) {
        Write-Log WARN "CO read returned $($values.Count) values, expected $ExpectedCount. Raw output: $Output"
    }
    , $values
}

function Get-AllCoreCo {
    param([int]$CoreCount)
    if (-not $script:RyzenSmuCli) { throw "Initialize-CoTool must be called first" }
    $output = & $script:RyzenSmuCli --get-offsets-terse 2>&1
    if ($LASTEXITCODE -ne 0) {
        $msg = "ryzen-smu-cli --get-offsets-terse failed (exit $LASTEXITCODE): $output"
        Write-Log ERROR $msg
        throw $msg
    }
    $values = ConvertFrom-CoToolOutput -Output ([string]::Join("`n", @($output))) -ExpectedCount $CoreCount
    if ($values.Count -lt $CoreCount) {
        # Pad with zeros to expected size as a safety
        $padded = New-Object 'int[]' $CoreCount
        for ($i = 0; $i -lt $values.Count; $i++) { $padded[$i] = $values[$i] }
        $values = $padded
    } elseif ($values.Count -gt $CoreCount) {
        $values = $values[0..($CoreCount - 1)]
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
    $output = & $script:RyzenSmuCli --offset $arg 2>&1
    if ($LASTEXITCODE -ne 0) {
        $msg = "ryzen-smu-cli --offset failed (exit $LASTEXITCODE): $output"
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
