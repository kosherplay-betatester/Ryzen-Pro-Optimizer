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
