BeforeAll {
    function Write-Log { param($Level, $Message) }
    . "$PSScriptRoot\..\lib\log-parser.ps1"

    $script:Cpu = [PSCustomObject]@{
        IsDualCcd = $true; CoresPerCcd = 8; VCacheCcdIndex = 0
    }

    function New-TempLog {
        param([string[]]$Lines)
        $p = Join-Path ([IO.Path]::GetTempPath()) ("rpo-log-" + [Guid]::NewGuid().ToString('N') + ".log")
        Set-Content -Path $p -Value $Lines
        $p
    }
}

Describe 'Read-CoreCyclerLog failing-core attribution' {
    It 'credits a failing core named only on an ERROR: At Core line' {
        # A run that dies immediately after an error (y-cruncher
        # CALCULATIONERROR -> Exit-WithFatalError) never writes the matching
        # [EVENTLOG] core_error line for that last core.
        $log = New-TempLog @(
            'Iteration 1/1'
            '18:45:17 - Set to Core 6 (CPU 12 and 13)'
            '   Error type: CALCULATIONERROR'
            'ERROR: At Core 6 (CPU 12 or 13)'
            'FATAL ERROR:'
        )
        try {
            $r = Read-CoreCyclerLog -CoreCyclerLogPath $log -CpuInfo $script:Cpu `
                    -CurrentCoValues @(0) * 16
            @($r.coresFailed.core) | Should -Contain 6
            @($r.coresPassed)      | Should -Not -Contain 6
            $r.verdict             | Should -Be 'FAILED'
        } finally { Remove-Item -Force $log }
    }

    It 'does not double-count a core reported by both the event log and an ERROR line' {
        $log = New-TempLog @(
            'Iteration 1/1'
            'Set to Core 9 (CPU 18 and 19)'
            '   [EVENTLOG] Error on Core Core 9 (CPU 18 or 19)!'
            'core_error'
            'ERROR: At Core 9 (CPU 18 or 19)'
            'cores with an error so far: 1'
        )
        try {
            $r = Read-CoreCyclerLog -CoreCyclerLogPath $log -CpuInfo $script:Cpu `
                    -CurrentCoValues @(0) * 16
            @($r.coresFailed).Count | Should -Be 1
            $r.coresFailed[0].core  | Should -Be 9
        } finally { Remove-Item -Force $log }
    }

    It 'labels the V-Cache CCD and records the CO value each core failed at' {
        $log = New-TempLog @(
            'Iteration 1/1'
            'Set to Core 6 (CPU 12 and 13)'
            'ERROR: At Core 6 (CPU 12 or 13)'
            'Set to Core 11 (CPU 22 and 23)'
            'ERROR: At Core 11 (CPU 22 or 23)'
        )
        $co = @(-15,-15,-15,-15,-15,-15,-5,-5,-15,-5,-15,-5,-5,-5,-5,-5)
        try {
            $r = Read-CoreCyclerLog -CoreCyclerLogPath $log -CpuInfo $script:Cpu -CurrentCoValues $co
            $six = $r.coresFailed | Where-Object { $_.core -eq 6 }
            $six.ccdLabel    | Should -Be 'CCD0 (V-Cache)'
            $six.coAtFailure | Should -Be -5
            $eleven = $r.coresFailed | Where-Object { $_.core -eq 11 }
            $eleven.ccdLabel | Should -Be 'CCD1 (Standard)'
        } finally { Remove-Item -Force $log }
    }

    It 'still passes a clean run with no error lines' {
        $log = New-TempLog @(
            'Iteration 1/1'
            'Set to Core 0 (CPU 0 and 1)'
            'cores with an error so far: 0'
            'cores with a WHEA error so far: 0'
            'Test completed in 00h 06m 01s'
        )
        try {
            $r = Read-CoreCyclerLog -CoreCyclerLogPath $log -CpuInfo $script:Cpu `
                    -CurrentCoValues @(0) * 16
            $r.verdict              | Should -Be 'PASSED'
            @($r.coresFailed).Count | Should -Be 0
        } finally { Remove-Item -Force $log }
    }

}
