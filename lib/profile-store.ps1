# ============================================================================
#  profile-store.ps1 - Named CO presets saved as JSON files
# ============================================================================
#  Used by  : server.ps1 (/api/profiles endpoints)
#  Storage  : repo's profiles/ directory (gitignored - your settings are
#             personal)
#
#  Each profile is a single .json file. Schema includes the CPU model
#  it was captured on so the UI can warn before applying a 7950X3D
#  profile to a 5800X (would set offsets on cores that don't exist or
#  with wrong CCD mapping).
#
#  Why files instead of a single index: easy to inspect, copy between
#  machines, version-control your favourites. The filename uses a
#  sanitised version of the profile name (Get-SafeProfileName strips
#  path-injection chars).
# ============================================================================
Set-StrictMode -Version Latest

$script:ProfilesDir = $null

function Initialize-ProfileStore {
    param([string]$RepoRoot)
    $script:ProfilesDir = Join-Path $RepoRoot 'profiles'
    if (-not (Test-Path $script:ProfilesDir)) { New-Item -ItemType Directory -Force -Path $script:ProfilesDir | Out-Null }
}

function Get-ProfilesDir { $script:ProfilesDir }

function Get-SafeProfileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw "Profile name required" }
    $Name -replace '[\\/:*?"<>|]','_'
}

function Get-ProfileList {
    if (-not $script:ProfilesDir -or -not (Test-Path $script:ProfilesDir)) { return @() }
    $items = @()
    Get-ChildItem -Path $script:ProfilesDir -Filter '*.json' | ForEach-Object {
        try {
            $obj = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $items += $obj
        } catch {
            Write-Log WARN "Failed to parse profile $($_.Name): $($_.Exception.Message)"
        }
    }
    , $items
}

function Get-ProfileByName {
    param([string]$Name)
    if (-not $script:ProfilesDir) { return $null }
    $safe = Get-SafeProfileName -Name $Name
    $path = Join-Path $script:ProfilesDir "$safe.json"
    if (-not (Test-Path $path)) { return $null }
    Get-Content $path -Raw | ConvertFrom-Json
}

function Save-CoProfile {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)]$Values,
        [string]$CpuModel = '',
        [int]$CoreCount = 0,
        [int]$CcdCount = 0,
        [string]$Notes = ''
    )
    if (-not $script:ProfilesDir) { throw "Initialize-ProfileStore must be called first" }
    $safe = Get-SafeProfileName -Name $Name
    $profile = [PSCustomObject]@{
        name = $Name
        createdAt = (Get-Date -Format 'o')
        cpuModel = $CpuModel
        coreCount = $CoreCount
        ccdCount = $CcdCount
        mode = $Mode
        values = $Values
        notes = $Notes
    }
    $path = Join-Path $script:ProfilesDir "$safe.json"
    $profile | ConvertTo-Json -Depth 10 | Set-Content -Path $path
    $profile
}

function Remove-CoProfile {
    param([string]$Name)
    if (-not $script:ProfilesDir) { return $false }
    $safe = Get-SafeProfileName -Name $Name
    $path = Join-Path $script:ProfilesDir "$safe.json"
    if (Test-Path $path) { Remove-Item $path; return $true }
    $false
}

# Convert a saved profile's values into a flat per-core integer array
function ConvertTo-CoreArray {
    param($Profile, [int]$CoreCount, [int]$CcdCount)
    $values = New-Object 'int[]' $CoreCount
    switch ($Profile.mode) {
        'all-cores' {
            for ($i = 0; $i -lt $CoreCount; $i++) { $values[$i] = [int]$Profile.values.all }
        }
        'per-ccd' {
            $coresPerCcd = $CoreCount / $CcdCount
            for ($c = 0; $c -lt $CcdCount; $c++) {
                $ccdVal = [int]$Profile.values."ccd$c"
                for ($i = 0; $i -lt $coresPerCcd; $i++) {
                    $values[($c * $coresPerCcd) + $i] = $ccdVal
                }
            }
        }
        'per-core' {
            for ($i = 0; $i -lt $CoreCount; $i++) {
                $values[$i] = [int]$Profile.values."$i"
            }
        }
        default { throw "Unknown profile mode: $($Profile.mode)" }
    }
    , $values
}
