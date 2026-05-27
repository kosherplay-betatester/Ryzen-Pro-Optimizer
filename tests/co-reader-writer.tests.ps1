BeforeAll { . "$PSScriptRoot\..\lib\co-reader-writer.ps1" }

Describe 'ConvertFrom-CoToolOutput' {
    It 'parses one-per-line integers' {
        $out = "-10`n-10`n-10`n-10`n-20`n-20`n-20`n-20"
        $r = ConvertFrom-CoToolOutput -Output $out -ExpectedCount 8
        $r.Count | Should -Be 8
        $r[0] | Should -Be -10
        $r[4] | Should -Be -20
    }
    It 'parses comma-separated' {
        $out = "-10,-10,-10,-20,-20,-20"
        $r = ConvertFrom-CoToolOutput -Output $out -ExpectedCount 6
        $r.Count | Should -Be 6
        $r[5] | Should -Be -20
    }
    It 'parses mixed whitespace and ignores blanks' {
        $out = "`n  -5 -3 `n -2 "
        $r = ConvertFrom-CoToolOutput -Output $out -ExpectedCount 3
        @($r) | Should -Be @(-5, -3, -2)
    }
}

Describe 'Set-AllCoreCo range validation' {
    BeforeAll {
        # Initialize with a fake path so range check runs
        $script:RyzenSmuCli = 'fake.exe'
    }
    It 'rejects values below -50' {
        { Set-AllCoreCo -Values @(-51, 0) } | Should -Throw "*out of safe range*"
    }
    It 'rejects values above 50' {
        { Set-AllCoreCo -Values @(0, 51) } | Should -Throw "*out of safe range*"
    }
}
