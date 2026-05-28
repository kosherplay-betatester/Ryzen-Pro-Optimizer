BeforeAll {
    . "$PSScriptRoot\..\lib\smart-tuner-history.ps1"
}

Describe 'Add-HistoryEntry' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("rpo-hist-" + [Guid]::NewGuid().ToString('N') + ".jsonl")
    }
    AfterEach {
        if (Test-Path $script:tmp) { Remove-Item $script:tmp -Force }
    }
    It 'creates the file and appends a JSON line' {
        Add-HistoryEntry -Path $script:tmp -Entry @{
            cpuModel='AMD Ryzen 9 7950X3D'; scope='CCD0'; value=-20; result='PASS'
        }
        Test-Path $script:tmp | Should -BeTrue
        $lines = @(Get-Content $script:tmp)
        $lines.Count | Should -Be 1
        $obj = $lines[0] | ConvertFrom-Json
        $obj.scope    | Should -Be 'CCD0'
        $obj.value    | Should -Be -20
        $obj.result   | Should -Be 'PASS'
        $obj.ts       | Should -Not -BeNullOrEmpty
    }
    It 'appends without rewriting previous entries' {
        Add-HistoryEntry -Path $script:tmp -Entry @{ scope='CCD0'; value=-15; result='PASS' }
        Add-HistoryEntry -Path $script:tmp -Entry @{ scope='CCD0'; value=-20; result='FAIL_P95' }
        (Get-Content $script:tmp).Count | Should -Be 2
    }
}

Describe 'History queries' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("rpo-hist-" + [Guid]::NewGuid().ToString('N') + ".jsonl")
        $cpu = 'AMD Ryzen 9 7950X3D'
        Add-HistoryEntry -Path $script:tmp -Entry @{cpuModel=$cpu;scope='CCD0';value=-15;result='PASS'}
        Add-HistoryEntry -Path $script:tmp -Entry @{cpuModel=$cpu;scope='CCD0';value=-20;result='PASS'}
        Add-HistoryEntry -Path $script:tmp -Entry @{cpuModel=$cpu;scope='CCD0';value=-22;result='FAIL_WHEA'}
        Add-HistoryEntry -Path $script:tmp -Entry @{cpuModel=$cpu;scope='CCD0';value=-25;result='ABORT_CRASH'}
        Add-HistoryEntry -Path $script:tmp -Entry @{cpuModel='Other CPU';scope='CCD0';value=-30;result='FAIL_WHEA'}
        Add-HistoryEntry -Path $script:tmp -Entry @{cpuModel=$cpu;scope='CCD1';value=-25;result='PASS'}
    }
    AfterEach { if (Test-Path $script:tmp) { Remove-Item $script:tmp -Force } }

    It 'Get-KnownCrashFloor returns the shallowest failure for that scope+CPU' {
        # For undervolt: shallowest fail = closest to zero = -22 (less negative than -25)
        Get-KnownCrashFloor -Path $script:tmp -CpuModel 'AMD Ryzen 9 7950X3D' -Scope 'CCD0' | Should -Be -22
    }
    It 'Get-KnownCrashFloor ignores other CPUs' {
        Get-KnownCrashFloor -Path $script:tmp -CpuModel 'AMD Ryzen 9 7950X3D' -Scope 'CCD0' | Should -Be -22
    }
    It 'Get-KnownStableCeiling returns the deepest pass for that scope+CPU' {
        # For undervolt: deepest stable = most negative = -20
        Get-KnownStableCeiling -Path $script:tmp -CpuModel 'AMD Ryzen 9 7950X3D' -Scope 'CCD0' | Should -Be -20
    }
    It 'Get-Confidence returns PASS_count - FAIL_count at exact value' {
        Get-Confidence -Path $script:tmp -CpuModel 'AMD Ryzen 9 7950X3D' -Scope 'CCD0' -Value -20 | Should -Be 1
        Get-Confidence -Path $script:tmp -CpuModel 'AMD Ryzen 9 7950X3D' -Scope 'CCD0' -Value -22 | Should -Be -1
        Get-Confidence -Path $script:tmp -CpuModel 'AMD Ryzen 9 7950X3D' -Scope 'CCD0' -Value -99 | Should -Be 0
    }
    It 'returns nulls when no history exists' {
        Remove-Item $script:tmp -Force
        Get-KnownCrashFloor -Path $script:tmp -CpuModel 'X' -Scope 'CCD0' | Should -Be $null
        Get-KnownStableCeiling -Path $script:tmp -CpuModel 'X' -Scope 'CCD0' | Should -Be $null
    }
}

Describe 'Compact-History' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("rpo-hist-" + [Guid]::NewGuid().ToString('N') + ".jsonl")
        # 6 entries: 4 PASS + 2 FAIL. Cap = 4. Should keep both FAILs + the 2 newest PASSes.
        Add-HistoryEntry -Path $script:tmp -Entry @{ts='2026-01-01T00:00:00Z';scope='a';value=-10;result='PASS'}
        Add-HistoryEntry -Path $script:tmp -Entry @{ts='2026-01-02T00:00:00Z';scope='a';value=-11;result='PASS'}
        Add-HistoryEntry -Path $script:tmp -Entry @{ts='2026-01-03T00:00:00Z';scope='a';value=-20;result='FAIL_WHEA'}
        Add-HistoryEntry -Path $script:tmp -Entry @{ts='2026-01-04T00:00:00Z';scope='a';value=-12;result='PASS'}
        Add-HistoryEntry -Path $script:tmp -Entry @{ts='2026-01-05T00:00:00Z';scope='a';value=-25;result='ABORT_CRASH'}
        Add-HistoryEntry -Path $script:tmp -Entry @{ts='2026-01-06T00:00:00Z';scope='a';value=-13;result='PASS'}
    }
    AfterEach { if (Test-Path $script:tmp) { Remove-Item $script:tmp -Force } }
    It 'prunes oldest non-crash entries to fit MaxEntries, preserving all crashes' {
        Compact-History -Path $script:tmp -MaxEntries 4
        $lines = Get-Content $script:tmp
        $lines.Count | Should -Be 4
        $objs = $lines | ForEach-Object { $_ | ConvertFrom-Json }
        # Both crash entries must survive
        @($objs | Where-Object { $_.result -in 'FAIL_WHEA','ABORT_CRASH' }).Count | Should -Be 2
        # Oldest PASS (Jan 1) should be gone; newer PASSes kept
        @($objs | Where-Object { $_.ts -eq '2026-01-01T00:00:00Z' }).Count | Should -Be 0
        @($objs | Where-Object { $_.ts -eq '2026-01-06T00:00:00Z' }).Count | Should -Be 1
    }
    It 'is a no-op when entries are under cap' {
        Compact-History -Path $script:tmp -MaxEntries 100
        (Get-Content $script:tmp).Count | Should -Be 6
    }
}
