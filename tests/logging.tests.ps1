BeforeAll {
    . "$PSScriptRoot\..\lib\logging.ps1"
    $script:tmpLog = [IO.Path]::GetTempFileName()
    Set-LogPath -Path $script:tmpLog
}
AfterAll { Remove-Item $script:tmpLog -ErrorAction SilentlyContinue }

Describe 'logging' {
    BeforeEach {
        Clear-Content -Path $script:tmpLog -ErrorAction SilentlyContinue
        Set-LogLevel INFO
    }
    It 'writes a line with level and message' {
        Write-Log -Level INFO -Message 'hello'
        $content = Get-Content $script:tmpLog -Raw
        $content | Should -Match '\[INFO\] hello'
    }
    It 'filters below current level' {
        Set-LogLevel WARN
        Write-Log -Level DEBUG -Message 'debug-msg'
        $content = (Get-Content $script:tmpLog -Raw)
        if ($null -ne $content) { $content | Should -Not -Match 'debug-msg' }
    }
    It 'rotates when file exceeds 5MB' {
        $bigContent = 'x' * (6 * 1024 * 1024)
        Set-Content -Path (Get-LogPath) -Value $bigContent
        Write-Log -Level INFO -Message 'after-rotate'
        Test-Path "$(Get-LogPath).old" | Should -BeTrue
    }
}
