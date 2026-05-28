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
