BeforeAll { . "$PSScriptRoot\..\lib\corecycler-runner.ps1" }

Describe 'New-CoreCyclerConfig stress test program sections' {
    BeforeAll {
        $script:TmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("rpo-cfg-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null
    }
    AfterAll {
        if (Test-Path $script:TmpRoot) { Remove-Item -Recurse -Force $script:TmpRoot }
    }

    It 'emits a [yCruncher] section carrying the mode when program is YCRUNCHER' {
        $p = New-CoreCyclerConfig -RepoRoot $script:TmpRoot -StressTestProgram 'YCRUNCHER' `
                -Mode '19-ZN2 ~ Kagari' -TotalCores 16
        $cfg = Get-Content -Raw $p
        $cfg | Should -Match '(?m)^stressTestProgram = YCRUNCHER\r?$'
        $cfg | Should -Match '(?m)^\[yCruncher\]\r?$'
        $cfg | Should -Match '(?m)^mode = 19-ZN2 ~ Kagari\r?$'
        $cfg | Should -Match '(?m)^tests = N63, VT3\r?$'
        $cfg | Should -Match '(?m)^enableYCruncherLoggingWrapper = 1\r?$'
        # Regression: a [Prime95] section would make CoreCycler ignore the
        # y-cruncher mode entirely.
        $cfg | Should -Not -Match '(?m)^\[Prime95\]\r?$'
    }

    It 'emits a [Prime95] section for the default program' {
        $p = New-CoreCyclerConfig -RepoRoot $script:TmpRoot -Mode 'SSE' -TotalCores 16
        $cfg = Get-Content -Raw $p
        $cfg | Should -Match '(?m)^stressTestProgram = PRIME95\r?$'
        $cfg | Should -Match '(?m)^\[Prime95\]\r?$'
        $cfg | Should -Match '(?m)^mode = SSE\r?$'
        $cfg | Should -Not -Match '(?m)^\[yCruncher\]\r?$'
    }

    It 'honours a custom y-cruncher test list' {
        $p = New-CoreCyclerConfig -RepoRoot $script:TmpRoot -StressTestProgram 'YCRUNCHER' `
                -Mode '22-ZN4 ~ Kizuna' -YCruncherTests 'N63' -TotalCores 16
        (Get-Content -Raw $p) | Should -Match '(?m)^tests = N63\r?$'
    }

    It 'defaults numberOfThreads to 1 and honours an override' {
        $a = New-CoreCyclerConfig -RepoRoot $script:TmpRoot -TotalCores 16
        (Get-Content -Raw $a) | Should -Match '(?m)^numberOfThreads = 1\r?$'
        $b = New-CoreCyclerConfig -RepoRoot $script:TmpRoot -NumberOfThreads 2 -TotalCores 16
        (Get-Content -Raw $b) | Should -Match '(?m)^numberOfThreads = 2\r?$'
    }

    It 'ignores every core outside CoresToTest' {
        $p = New-CoreCyclerConfig -RepoRoot $script:TmpRoot -CoresToTest @(6,7,9) -TotalCores 12
        (Get-Content -Raw $p) | Should -Match '(?m)^coresToIgnore = 0, 1, 2, 3, 4, 5, 8, 10, 11\r?$'
    }
}
