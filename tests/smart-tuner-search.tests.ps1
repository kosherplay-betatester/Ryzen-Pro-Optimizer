BeforeAll {
    . "$PSScriptRoot\..\lib\smart-tuner-modes.ps1"
    . "$PSScriptRoot\..\lib\smart-tuner-search.ps1"
}

Describe 'New-ScopeState' {
    It 'creates a scope with mode-derived bounds (V-Cache CCD)' {
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $true -SeedValue 0 -Policy $policy
        $s.scopeId        | Should -Be 'CCD0'
        $s.bounds.floor   | Should -Be -25
        $s.bounds.ceiling | Should -Be 0
        $s.knownStable    | Should -Be $null
        $s.knownUnstable  | Should -Be $null
        $s.seedValue      | Should -Be 0
        $s.probesCompleted | Should -Be 0
    }
    It 'uses Standard CCD bounds when not V-Cache' {
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $s = New-ScopeState -ScopeId 'CCD1' -IsVCache $false -SeedValue 0 -Policy $policy
        $s.bounds.floor | Should -Be -30
    }
    It 'seeds knownStable when a history hint is provided' {
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $policy -KnownStableHint -18 -KnownCrashFloor -22
        $s.knownStable   | Should -Be -18
        $s.knownUnstable | Should -Be -22
    }
}

Describe 'Get-NextCandidate' {
    BeforeEach {
        $script:policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
    }
    It 'returns midpoint when both bounds known and headroom is full' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s.knownStable   = -10
        $s.knownUnstable = -20
        # Full headroom (1.0) means full half-step toward unstable
        $c = Get-NextCandidate -ScopeState $s -TelemetryHeadroom 1.0 -Policy $script:policy
        $c | Should -Be -15  # midpoint
    }
    It 'shrinks step when telemetry headroom is small' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s.knownStable   = -10
        $s.knownUnstable = -20
        $c = Get-NextCandidate -ScopeState $s -TelemetryHeadroom 0.0 -Policy $script:policy
        # zero headroom => step factor = 0.5 of midpoint distance = 2.5 -> clamped to stepMin 1
        # candidate = knownStable - max(stepMin, round(0.5 * 5)) = -10 - 3 = -13 (less aggressive than midpoint)
        $c | Should -BeIn -13, -12, -11   # any conservative step is valid
    }
    It 'uses floor when knownStable is null' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $c = Get-NextCandidate -ScopeState $s -TelemetryHeadroom 1.0 -Policy $script:policy
        # No knownStable - probe at midpoint of (seed, floor)
        $c | Should -Be -15   # midpoint of 0 and -30
    }
    It 'respects floor as hard limit' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s.knownStable   = -28
        $s.knownUnstable = $null
        $c = Get-NextCandidate -ScopeState $s -TelemetryHeadroom 1.0 -Policy $script:policy
        $c | Should -BeGreaterOrEqual $s.bounds.floor
    }
    It 'inverts direction for overclock policy' {
        $oc = Get-ModePolicy -Mode 'overclock' -Direction 'overclock'
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $oc
        $s.knownStable   = 5
        $s.knownUnstable = 15
        $c = Get-NextCandidate -ScopeState $s -TelemetryHeadroom 1.0 -Policy $oc
        $c | Should -Be 10   # midpoint, going UP
    }
}

Describe 'Update-ScopeFromResult' {
    BeforeEach {
        $script:policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
    }
    It 'sets knownStable on PASS' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s2 = Update-ScopeFromResult -ScopeState $s -Candidate -15 -Result 'PASS'
        $s2.knownStable     | Should -Be -15
        $s2.knownUnstable   | Should -Be $null
        $s2.probesCompleted | Should -Be 1
        $s2.lastCandidate   | Should -Be -15
        $s2.lastResult      | Should -Be 'PASS'
    }
    It 'sets knownUnstable on FAIL_P95' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s2 = Update-ScopeFromResult -ScopeState $s -Candidate -22 -Result 'FAIL_P95'
        $s2.knownUnstable | Should -Be -22
        $s2.knownStable   | Should -Be $null
    }
    It 'sets knownUnstable on FAIL_WHEA' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s2 = Update-ScopeFromResult -ScopeState $s -Candidate -22 -Result 'FAIL_WHEA'
        $s2.knownUnstable | Should -Be -22
    }
    It 'pushes knownUnstable one past candidate on ABORT_SAFETY (no stability signal)' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s2 = Update-ScopeFromResult -ScopeState $s -Candidate -22 -Result 'ABORT_SAFETY'
        # For undervolt, "+1" means closer to zero / safer => unstable=-21
        $s2.knownUnstable | Should -Be -21
    }
}

Describe 'Test-ScopeConverged' {
    BeforeEach {
        $script:policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
    }
    It 'returns false when bounds are not adjacent' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s.knownStable = -19; $s.knownUnstable = -25
        Test-ScopeConverged -ScopeState $s | Should -BeFalse
    }
    It 'returns true when bounds differ by 1' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s.knownStable = -20; $s.knownUnstable = -21
        Test-ScopeConverged -ScopeState $s | Should -BeTrue
    }
    It 'returns true when knownStable hits floor' {
        $s = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $s.knownStable = $s.bounds.floor
        Test-ScopeConverged -ScopeState $s | Should -BeTrue
    }
}
