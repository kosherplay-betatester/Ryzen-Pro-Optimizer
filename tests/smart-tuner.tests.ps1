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

Describe 'Step-OneProbe' {
    BeforeEach {
        $script:policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $script:scope = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $script:policy
        $script:applied = $null
        $script:applyFn = { param($v) $applied = $v }
    }
    It 'updates scope after one probe (PASS case)' {
        $probeFn = { 'PASS' }
        $new = Step-OneProbe -ScopeState $script:scope -Policy $script:policy `
            -ProbeFn $probeFn -ApplyFn $script:applyFn -TelemetryHeadroom 1.0
        $new.probesCompleted | Should -Be 1
        $new.lastResult      | Should -Be 'PASS'
        $new.knownStable     | Should -Not -Be $null
        $new.lastCandidate   | Should -Not -Be $null
    }
    It 'updates scope after one probe (FAIL_WHEA case)' {
        $probeFn = { 'FAIL_WHEA' }
        $new = Step-OneProbe -ScopeState $script:scope -Policy $script:policy `
            -ProbeFn $probeFn -ApplyFn $script:applyFn -TelemetryHeadroom 1.0
        $new.lastResult    | Should -Be 'FAIL_WHEA'
        $new.knownUnstable | Should -Not -Be $null
    }
    It 'converges to lock value after a scripted sequence' {
        $script:results = @('PASS','PASS','FAIL_P95','PASS','FAIL_WHEA')
        $script:i = 0
        $probeFn = {
            if ($script:i -ge $script:results.Count) { return 'PASS' }
            $r = $script:results[$script:i]
            $script:i++
            $r
        }
        $state = $script:scope
        $maxProbes = 10
        $probeCount = 0
        while (-not (Test-ScopeConverged -ScopeState $state) -and $probeCount -lt $maxProbes) {
            $state = Step-OneProbe -ScopeState $state -Policy $script:policy `
                -ProbeFn $probeFn -ApplyFn $script:applyFn -TelemetryHeadroom 1.0
            $probeCount++
        }
        Test-ScopeConverged -ScopeState $state | Should -BeTrue
        $locked = Get-LockInValue -ScopeState $state -Policy $script:policy
        $locked | Should -Not -Be $null
    }
}

Describe 'Tune-Scope' {
    It 'iterates Step-OneProbe until convergence, returns final state' {
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $scope  = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $policy
        $script:applied = @()
        $applyFn = { param($v) $script:applied += $v }
        # Scripted probes: 4 PASS then FAIL_WHEA -> should converge fast
        $script:i = 0
        $script:results = @('PASS','PASS','PASS','PASS','FAIL_WHEA','FAIL_WHEA','FAIL_WHEA','FAIL_WHEA')
        $probeFn = { $r = $script:results[$script:i]; $script:i = [Math]::Min($script:i+1, $script:results.Count-1); $r }
        $headroomFn = { 1.0 }
        $final = Tune-Scope -ScopeState $scope -Policy $policy `
            -ProbeFn $probeFn -ApplyFn $applyFn -HeadroomFn $headroomFn -MaxProbes 20
        Test-ScopeConverged -ScopeState $final | Should -BeTrue
        $final.probesCompleted | Should -BeLessThan 20
    }
    It 'stops at MaxProbes safety cap even if not converged' {
        $policy = Get-ModePolicy -Mode 'daily-driver' -Direction 'undervolt'
        $scope  = New-ScopeState -ScopeId 'CCD0' -IsVCache $false -SeedValue 0 -Policy $policy
        $probeFn = { 'PASS' }   # would loop forever without cap
        $applyFn = { }
        $headroomFn = { 1.0 }
        $final = Tune-Scope -ScopeState $scope -Policy $policy `
            -ProbeFn $probeFn -ApplyFn $applyFn -HeadroomFn $headroomFn -MaxProbes 5
        $final.probesCompleted | Should -Be 5
    }
}

Describe 'Get-TelemetryHeadroom' {
    It 'returns positive value when both temp and VID under limits' {
        $snap = [PSCustomObject]@{
            packageTemp = 50; cores = @([PSCustomObject]@{ voltage = 1.0 })
        }
        Get-TelemetryHeadroom -Snapshot $snap -MaxTempC 95 -MaxVid 1.45 | Should -BeGreaterThan 0.2
    }
    It 'returns 0.0 when temp is at limit' {
        $snap = [PSCustomObject]@{
            packageTemp = 95; cores = @([PSCustomObject]@{ voltage = 1.0 })
        }
        Get-TelemetryHeadroom -Snapshot $snap -MaxTempC 95 -MaxVid 1.45 | Should -Be 0.0
    }
    It 'returns 0.0 on null snapshot (defensive default)' {
        Get-TelemetryHeadroom -Snapshot $null -MaxTempC 95 -MaxVid 1.45 | Should -Be 0.0
    }
}
