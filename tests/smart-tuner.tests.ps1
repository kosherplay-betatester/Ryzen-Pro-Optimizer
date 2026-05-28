BeforeAll { . "$PSScriptRoot\..\lib\smart-tuner.ps1" }

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
