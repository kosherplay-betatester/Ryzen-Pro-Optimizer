BeforeAll { . "$PSScriptRoot\..\lib\smart-tuner-narrative.ps1" }

Describe 'Narrative buffer' {
    BeforeEach { Clear-TunerNarrative }
    It 'records an entry with auto-assigned monotonic seqId' {
        $a = Write-TunerNarrative -Icon '⚙' -Message 'start'
        $b = Write-TunerNarrative -Icon '➤' -Message 'probe 1'
        $a.seqId | Should -Be 1
        $b.seqId | Should -Be 2
        $a.ts | Should -Not -BeNullOrEmpty
    }
    It 'Get-NewNarrativeEntries returns entries with seqId > since' {
        Write-TunerNarrative -Icon '⚙' -Message 'a'
        Write-TunerNarrative -Icon '➤' -Message 'b'
        Write-TunerNarrative -Icon '✓' -Message 'c'
        $new = Get-NewNarrativeEntries -SinceSeqId 1
        $new.Count | Should -Be 2
        $new[0].message | Should -Be 'b'
    }
    It 'keeps in-memory buffer capped at 500 entries' {
        for ($i = 0; $i -lt 600; $i++) { Write-TunerNarrative -Icon '➤' -Message "m$i" }
        $all = Get-NewNarrativeEntries -SinceSeqId 0
        $all.Count | Should -BeLessOrEqual 500
        # Newest must be present
        $all[-1].message | Should -Be 'm599'
    }
    It 'accepts optional structured payload' {
        $e = Write-TunerNarrative -Icon '➤' -Message 'probe' -Payload @{ scope='CCD0'; value=-20 }
        $e.payload.scope | Should -Be 'CCD0'
        $e.payload.value | Should -Be -20
    }
}
