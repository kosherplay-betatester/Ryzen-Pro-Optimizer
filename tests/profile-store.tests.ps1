BeforeAll {
    . "$PSScriptRoot\..\lib\logging.ps1"
    . "$PSScriptRoot\..\lib\profile-store.ps1"
}

Describe 'Save-PreTuneSnapshot' {
    BeforeEach {
        $script:tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmpRoot | Out-Null
        Initialize-ProfileStore -RepoRoot $script:tmpRoot
    }
    AfterEach {
        if ($script:tmpRoot -and (Test-Path $script:tmpRoot)) {
            Remove-Item -Recurse -Force $script:tmpRoot -ErrorAction SilentlyContinue
        }
    }

    It 'saves a per-core profile with a pre-auto-adjust timestamped name' {
        $values = @(-10,-10,-10,-10,-10,-10,-10,-10,-20,-20,-20,-20,-20,-20,-20,-20)
        $saved = Save-PreTuneSnapshot -Process 'auto-adjust' -CurrentValues $values `
                    -CpuModel 'AMD Ryzen 9 7950X3D' -CcdCount 2
        $saved.name      | Should -Match '^pre-auto-adjust-\d{4}-\d{2}-\d{2}-\d{6}$'
        $saved.mode      | Should -Be 'per-core'
        $saved.coreCount | Should -Be 16
        $saved.ccdCount  | Should -Be 2
        $saved.cpuModel  | Should -Be 'AMD Ryzen 9 7950X3D'
        $saved.values.'0' | Should -Be -10
        $saved.values.'8' | Should -Be -20
        $saved.notes     | Should -Match 'Auto-Adjust'
    }

    It 'saves a per-core profile with a pre-smart-tune timestamped name' {
        $values = 0..15 | ForEach-Object { 0 }
        $saved = Save-PreTuneSnapshot -Process 'smart-tune' -CurrentValues $values `
                    -CpuModel 'AMD Ryzen 9 7950X3D' -CcdCount 2
        $saved.name  | Should -Match '^pre-smart-tune-\d{4}-\d{2}-\d{2}-\d{6}$'
        $saved.notes | Should -Match 'Smart Auto-Adjust'
    }

    It 'rejects an unknown process tag' {
        { Save-PreTuneSnapshot -Process 'something-else' -CurrentValues @(0) `
                -CpuModel 'x' -CcdCount 1 } | Should -Throw
    }

    It 'writes a file that round-trips through Get-ProfileList' {
        $values = @(0,-5,-5,-5,-5,-5,-5,-5)
        Save-PreTuneSnapshot -Process 'auto-adjust' -CurrentValues $values `
            -CpuModel 'AMD Ryzen 7 5800X3D' -CcdCount 1 | Out-Null
        $list = @(Get-ProfileList)
        $list.Count | Should -Be 1
        $list[0].mode | Should -Be 'per-core'
        $list[0].coreCount | Should -Be 8
    }
}
