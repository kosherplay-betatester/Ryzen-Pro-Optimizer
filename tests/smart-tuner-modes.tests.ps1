BeforeAll { . "$PSScriptRoot\..\lib\smart-tuner-modes.ps1" }

Describe 'Get-ModePolicy' {
    It 'returns Daily Driver defaults' {
        $p = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $p.probeRuntimeMin   | Should -Be 4
        $p.verifyIterations  | Should -Be 2
        $p.marginPoints      | Should -Be 2
        $p.refinePerCore     | Should -BeFalse
        $p.standardFloor     | Should -Be -30
        $p.vCacheFloor       | Should -Be -25
    }
    It 'returns Max Stable with per-core refinement' {
        $p = Get-ModePolicy -Mode 'max-stable' -Direction 'undervolt'
        $p.verifyIterations | Should -Be 5
        $p.marginPoints     | Should -Be 1
        $p.refinePerCore    | Should -BeTrue
    }
    It 'flips bounds for overclock direction' {
        $p = Get-ModePolicy -Mode 'overclock' -Direction 'overclock'
        $p.standardFloor    | Should -Be 0
        $p.standardCeiling  | Should -BeGreaterThan 0
        $p.marginPoints     | Should -Be -1  # negative = move back toward 0
    }
    It 'throws on unknown mode' {
        { Get-ModePolicy -Mode 'bogus' -Direction 'undervolt' } | Should -Throw
    }
}
