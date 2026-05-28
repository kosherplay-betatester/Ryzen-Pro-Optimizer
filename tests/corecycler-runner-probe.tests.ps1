BeforeAll { . "$PSScriptRoot\..\lib\corecycler-runner.ps1" }

Describe 'Test-CoreCyclerProbeResult' {
    It 'returns PASS on clean completion' {
        $lines = @(
            'Iteration 1/1'
            'Set to Core 0'
            'cores with an error so far: 0'
            'cores with a WHEA error so far: 0'
            'Test completed in 00h 04m 12s'
        )
        Test-CoreCyclerProbeResult -LogLines $lines -PrimeLines @() -ExitedCleanly $true |
            Should -Be 'PASS'
    }
    It 'returns FAIL_WHEA when WHEA count > 0' {
        $lines = @(
            'Set to Core 5'
            'cores with a WHEA error so far: 1'
        )
        Test-CoreCyclerProbeResult -LogLines $lines -PrimeLines @() -ExitedCleanly $true |
            Should -Be 'FAIL_WHEA'
    }
    It 'returns FAIL_P95 when CoreCycler reports a core error' {
        $lines = @(
            'Set to Core 7'
            'has thrown an error'
            'cores with an error so far: 1'
        )
        Test-CoreCyclerProbeResult -LogLines $lines -PrimeLines @() -ExitedCleanly $true |
            Should -Be 'FAIL_P95'
    }
    It 'returns FAIL_P95 when Prime95 log shows FATAL ERROR even if CC log silent' {
        Test-CoreCyclerProbeResult -LogLines @('Set to Core 1') -PrimeLines @('Prime95 FATAL ERROR rounding') -ExitedCleanly $true |
            Should -Be 'FAIL_P95'
    }
    It 'returns TIMEOUT when neither pass nor fail and not exited cleanly' {
        Test-CoreCyclerProbeResult -LogLines @('Set to Core 2') -PrimeLines @() -ExitedCleanly $false |
            Should -Be 'TIMEOUT'
    }
}
