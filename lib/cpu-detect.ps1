Set-StrictMode -Version Latest

# Maps known Ryzen model suffixes to (zenGen, dualCcd, vCacheCcdIndex-or-null)
$script:CpuOverrides = @{
    '7950X3D' = @{ zenGen=4; dualCcd=$true;  vCacheCcdIndex=0 }
    '7900X3D' = @{ zenGen=4; dualCcd=$true;  vCacheCcdIndex=0 }
    '7800X3D' = @{ zenGen=4; dualCcd=$false; vCacheCcdIndex=0 }
    '7950X'   = @{ zenGen=4; dualCcd=$true;  vCacheCcdIndex=$null }
    '7900X'   = @{ zenGen=4; dualCcd=$true;  vCacheCcdIndex=$null }
    '7900'    = @{ zenGen=4; dualCcd=$true;  vCacheCcdIndex=$null }
    '7700X'   = @{ zenGen=4; dualCcd=$false; vCacheCcdIndex=$null }
    '7700'    = @{ zenGen=4; dualCcd=$false; vCacheCcdIndex=$null }
    '7600X'   = @{ zenGen=4; dualCcd=$false; vCacheCcdIndex=$null }
    '7600'    = @{ zenGen=4; dualCcd=$false; vCacheCcdIndex=$null }
    '5950X'   = @{ zenGen=3; dualCcd=$true;  vCacheCcdIndex=$null }
    '5900X'   = @{ zenGen=3; dualCcd=$true;  vCacheCcdIndex=$null }
    '5800X3D' = @{ zenGen=3; dualCcd=$false; vCacheCcdIndex=0 }
    '5800X'   = @{ zenGen=3; dualCcd=$false; vCacheCcdIndex=$null }
    '5700X'   = @{ zenGen=3; dualCcd=$false; vCacheCcdIndex=$null }
    '5700G'   = @{ zenGen=3; dualCcd=$false; vCacheCcdIndex=$null }
    '5600X'   = @{ zenGen=3; dualCcd=$false; vCacheCcdIndex=$null }
    '5600G'   = @{ zenGen=3; dualCcd=$false; vCacheCcdIndex=$null }
    '5600'    = @{ zenGen=3; dualCcd=$false; vCacheCcdIndex=$null }
    '9950X3D' = @{ zenGen=5; dualCcd=$true;  vCacheCcdIndex=0 }
    '9950X'   = @{ zenGen=5; dualCcd=$true;  vCacheCcdIndex=$null }
    '9900X3D' = @{ zenGen=5; dualCcd=$true;  vCacheCcdIndex=0 }
    '9900X'   = @{ zenGen=5; dualCcd=$true;  vCacheCcdIndex=$null }
    '9800X3D' = @{ zenGen=5; dualCcd=$false; vCacheCcdIndex=0 }
    '9700X'   = @{ zenGen=5; dualCcd=$false; vCacheCcdIndex=$null }
    '9600X'   = @{ zenGen=5; dualCcd=$false; vCacheCcdIndex=$null }
}

function Get-CpuInfo {
    $proc = Get-CimInstance Win32_Processor | Select-Object -First 1
    $name = $proc.Name -replace '\s+',' '
    $name = $name.Trim()
    $cores = [int]$proc.NumberOfCores
    $threads = [int]$proc.NumberOfLogicalProcessors
    $manufacturer = $proc.Manufacturer

    $info = [ordered]@{
        Name = $name
        Manufacturer = $manufacturer
        Cores = $cores
        Threads = $threads
        IsAmd = ($manufacturer -match 'AMD' -or $name -match 'AMD')
        IsRyzen = $name -match 'Ryzen'
        SuggestedModel = $null
        ZenGen = $null
        IsDualCcd = $null
        VCacheCcdIndex = $null
        CcdCount = $null
        CoresPerCcd = $null
        SupportsCurveOptimizer = $false
        UnsupportedReason = $null
    }

    if (-not $info.IsAmd -or -not $info.IsRyzen) {
        $info.UnsupportedReason = 'Not an AMD Ryzen CPU.'
        return [PSCustomObject]$info
    }

    if ($name -match 'Ryzen \d+ (\d{4}[A-Z0-9]*)') {
        $info.SuggestedModel = $Matches[1]
    }

    if ($info.SuggestedModel -and $script:CpuOverrides.ContainsKey($info.SuggestedModel)) {
        $o = $script:CpuOverrides[$info.SuggestedModel]
        $info.ZenGen = $o.zenGen
        $info.IsDualCcd = $o.dualCcd
        $info.VCacheCcdIndex = $o.vCacheCcdIndex
    } else {
        # Heuristic fallback: >8 cores = dual CCD on consumer Ryzen
        $info.IsDualCcd = $cores -gt 8
        # Zen gen guess from leading model digit
        if ($name -match 'Ryzen \d+ (\d)\d{3}') {
            switch ($Matches[1]) {
                '5' { $info.ZenGen = 3 }
                '7' { $info.ZenGen = 4 }
                '9' { $info.ZenGen = 5 }
                default { $info.ZenGen = $null }
            }
        }
    }

    $info.CcdCount = if ($info.IsDualCcd) { 2 } else { 1 }
    if ($info.CcdCount -gt 0) {
        $info.CoresPerCcd = [int]($cores / $info.CcdCount)
    }

    if ($info.ZenGen -ne $null -and $info.ZenGen -ge 3) {
        $info.SupportsCurveOptimizer = $true
    } else {
        $info.UnsupportedReason = "Curve Optimizer was introduced with Zen 3 (Ryzen 5000). Your CPU appears to be older or unrecognized."
    }

    [PSCustomObject]$info
}

function Get-CcdLabel {
    param($CpuInfo, [int]$CcdIndex)
    if (-not $CpuInfo.IsDualCcd) { return 'CCD0' }
    $isVCache = ($null -ne $CpuInfo.VCacheCcdIndex) -and ($CpuInfo.VCacheCcdIndex -eq $CcdIndex)
    if ($isVCache) { "CCD$CcdIndex (V-Cache)" } else { "CCD$CcdIndex (Standard)" }
}

function Get-CcdForCore {
    param($CpuInfo, [int]$Core)
    if (-not $CpuInfo.IsDualCcd) { return 0 }
    [int]([math]::Floor($Core / $CpuInfo.CoresPerCcd))
}
