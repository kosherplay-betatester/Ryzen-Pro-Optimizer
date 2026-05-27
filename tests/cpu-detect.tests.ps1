BeforeAll { . "$PSScriptRoot\..\lib\cpu-detect.ps1" }

Describe 'Get-CcdLabel and Get-CcdForCore' {
    It 'returns CCD0 only for single-CCD chip' {
        $cpu = [PSCustomObject]@{ IsDualCcd=$false; CoresPerCcd=8; VCacheCcdIndex=$null }
        Get-CcdLabel -CpuInfo $cpu -CcdIndex 0 | Should -Be 'CCD0'
        Get-CcdForCore -CpuInfo $cpu -Core 7 | Should -Be 0
    }
    It 'labels V-Cache CCD correctly for 7950X3D' {
        $cpu = [PSCustomObject]@{ IsDualCcd=$true; CoresPerCcd=8; VCacheCcdIndex=0 }
        Get-CcdLabel -CpuInfo $cpu -CcdIndex 0 | Should -Be 'CCD0 (V-Cache)'
        Get-CcdLabel -CpuInfo $cpu -CcdIndex 1 | Should -Be 'CCD1 (Standard)'
    }
    It 'maps cores to CCDs correctly for 16-core dual CCD' {
        $cpu = [PSCustomObject]@{ IsDualCcd=$true; CoresPerCcd=8; VCacheCcdIndex=0 }
        Get-CcdForCore -CpuInfo $cpu -Core 0 | Should -Be 0
        Get-CcdForCore -CpuInfo $cpu -Core 7 | Should -Be 0
        Get-CcdForCore -CpuInfo $cpu -Core 8 | Should -Be 1
        Get-CcdForCore -CpuInfo $cpu -Core 15 | Should -Be 1
    }
}

Describe 'Get-CpuInfo (live system)' {
    It 'returns an object with populated fields' {
        $info = Get-CpuInfo
        $info.Name | Should -Not -BeNullOrEmpty
        $info.Cores | Should -BeGreaterThan 0
    }
}
