BeforeAll {
    . "$PSScriptRoot\..\lib\smart-tuner-modes.ps1"
    . "$PSScriptRoot\..\lib\smart-tuner-search.ps1"
    . "$PSScriptRoot\..\lib\smart-tuner.ps1"
}

Describe 'Session persistence' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("rpo-sess-" + [Guid]::NewGuid().ToString('N') + ".json")
    }
    AfterEach { if (Test-Path $script:tmp) { Remove-Item $script:tmp -Force } }
    It 'Save-TuneSession writes atomically (no partial file on crash)' {
        $sess = @{
            sessionId='abc'; mode='daily-driver'; cpuModel='Test'
            scopes = @(@{id='CCD0'; status='COMPLETED'})
        }
        Save-TuneSession -Path $script:tmp -Session $sess
        Test-Path $script:tmp | Should -BeTrue
        Test-Path "$script:tmp.tmp" | Should -BeFalse   # tmp cleaned up
        $loaded = Load-TuneSession -Path $script:tmp
        $loaded.sessionId | Should -Be 'abc'
        $loaded.scopes[0].id | Should -Be 'CCD0'
    }
    It 'Load-TuneSession returns null when file missing' {
        Load-TuneSession -Path $script:tmp | Should -Be $null
    }
    It 'Clear-TuneSession removes the file' {
        Save-TuneSession -Path $script:tmp -Session @{sessionId='x'}
        Clear-TuneSession -Path $script:tmp
        Test-Path $script:tmp | Should -BeFalse
    }
}

Describe 'Plan-TuneSession' {
    It 'plans CCD0+CCD1 for dual-CCD with V-Cache CCD0 first' {
        $cpu = [PSCustomObject]@{
            Name='Test 7950X3D'; Cores=16; CcdCount=2; CoresPerCcd=8
            IsDualCcd=$true; VCacheCcdIndex=0
        }
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $plan = Plan-TuneSession -Cpu $cpu -Policy $policy
        $plan.Count | Should -Be 2
        $plan[0].id     | Should -Be 'CCD0'
        $plan[0].isVCache | Should -BeTrue
        $plan[0].cores  | Should -Be @(0,1,2,3,4,5,6,7)
        $plan[1].id     | Should -Be 'CCD1'
    }
    It 'plans single CCD for non-X3D parts' {
        $cpu = [PSCustomObject]@{
            Name='Test 7700X'; Cores=8; CcdCount=1; CoresPerCcd=8
            IsDualCcd=$false; VCacheCcdIndex=$null
        }
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $plan = Plan-TuneSession -Cpu $cpu -Policy $policy
        $plan.Count | Should -Be 1
        $plan[0].id | Should -Be 'CCD0'
    }
    It 'adds per-core refinement scopes when policy.refinePerCore is true' {
        $cpu = [PSCustomObject]@{
            Name='Test 7950X3D'; Cores=16; CcdCount=2; CoresPerCcd=8
            IsDualCcd=$true; VCacheCcdIndex=0
        }
        $policy = Get-ModePolicy -Mode 'max-stable' -Direction 'undervolt'
        $plan = Plan-TuneSession -Cpu $cpu -Policy $policy
        # 2 CCD scopes + 16 per-core scopes
        $plan.Count | Should -Be 18
        @($plan | Where-Object { $_.id -match '^core' }).Count | Should -Be 16
    }
}
