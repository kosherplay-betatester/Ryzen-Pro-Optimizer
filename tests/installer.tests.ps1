BeforeAll {
    . "$PSScriptRoot\..\installer.ps1"
}

Describe 'Get-CoreCyclerZipUrl' {
    It 'returns the .zip asset URL from a release object' {
        $fakeRelease = [PSCustomObject]@{
            tag_name = 'v1.0.0'
            assets = @(
                [PSCustomObject]@{ name='source.tar.gz'; browser_download_url='http://x/source.tar.gz' },
                [PSCustomObject]@{ name='CoreCycler_v1.0.0.zip'; browser_download_url='http://x/CoreCycler_v1.0.0.zip' }
            )
            zipball_url = 'http://x/zipball'
        }
        Get-CoreCyclerZipUrl -Release $fakeRelease | Should -Be 'http://x/CoreCycler_v1.0.0.zip'
    }
    It 'falls back to zipball_url when no zip asset' {
        $fakeRelease = [PSCustomObject]@{
            tag_name = 'v1.0.0'
            assets = @()
            zipball_url = 'http://x/zipball'
        }
        Get-CoreCyclerZipUrl -Release $fakeRelease | Should -Be 'http://x/zipball'
    }
}
