BeforeAll { . "$PSScriptRoot\..\lib\router.ps1" }
BeforeEach { Clear-Routes }

Describe 'router' {
    It 'finds an exact match' {
        Register-Route -Method GET -Path '/api/cpu' -Handler { 'cpu' }
        $r = Resolve-Route -Method GET -Path '/api/cpu'
        & $r.Handler | Should -Be 'cpu'
    }
    It 'returns null for unknown route' {
        Resolve-Route -Method GET -Path '/nope' | Should -BeNullOrEmpty
    }
    It 'distinguishes methods' {
        Register-Route -Method GET -Path '/x' -Handler { 'get' }
        Register-Route -Method POST -Path '/x' -Handler { 'post' }
        $r = Resolve-Route -Method POST -Path '/x'
        & $r.Handler | Should -Be 'post'
    }
    It 'matches parameterized paths and unescapes captures' {
        Register-Route -Method DELETE -Path '/api/profiles/{name}' -Handler { param($ctx, $params) $params }
        $r = Resolve-Route -Method DELETE -Path '/api/profiles/Daily%20Stable'
        $r.Params.name | Should -Be 'Daily Stable'
    }
}
