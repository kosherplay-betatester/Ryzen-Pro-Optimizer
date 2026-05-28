BeforeAll { . "$PSScriptRoot\..\lib\co-reader-writer.ps1" }

Describe 'ConvertFrom-CoToolOutput' {
    It 'parses the comma-separated data line with header preamble' {
        $out = "Current PBO offsets:`n-10,-10,-10,-10,-20,-20,-20,-20`n"
        $r = ConvertFrom-CoToolOutput -Output $out -ExpectedCount 8
        $r.Count | Should -Be 8
        $r[0] | Should -Be -10
        $r[7] | Should -Be -20
    }
    It 'parses a single comma line' {
        $out = '-10,-20,0,5'
        $r = ConvertFrom-CoToolOutput -Output $out -ExpectedCount 4
        @($r) | Should -Be @(-10, -20, 0, 5)
    }
    It 'handles preamble noise without picking up stray numbers' {
        $out = "Initializing ZenStates 1.2.3...`nConnected to SMU on socket 0`nCurrent PBO offsets:`n0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0"
        $r = ConvertFrom-CoToolOutput -Output $out -ExpectedCount 16
        $r.Count | Should -Be 16
        @($r | Where-Object { $_ -ne 0 }).Count | Should -Be 0
    }
    It 'returns empty when no comma line is present' {
        $out = "no data here`nor here"
        $r = ConvertFrom-CoToolOutput -Output $out -ExpectedCount 16
        @($r).Count | Should -Be 0
    }
}

Describe 'Set-AllCoreCo range validation' {
    BeforeAll {
        $script:RyzenSmuCli = 'fake.exe'
    }
    It 'rejects values below -50' {
        { Set-AllCoreCo -Values @(-51, 0) } | Should -Throw "*out of safe range*"
    }
    It 'rejects values above 50' {
        { Set-AllCoreCo -Values @(0, 51) } | Should -Throw "*out of safe range*"
    }
}
