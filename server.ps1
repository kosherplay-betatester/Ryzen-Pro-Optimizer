Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Project root
$RepoRoot = $PSScriptRoot

# Load libraries
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\router.ps1"
. "$PSScriptRoot\lib\http-server.ps1"

# ----- Routes -----

Register-Route -Method GET -Path '/api/ping' -Handler {
    @{ ok = $true; data = @{ message = 'pong'; time = (Get-Date -Format 'o') } }
}

# ----- Boot -----

$listener = Start-HttpServer
$url = "http://127.0.0.1:$(Get-ListenerPort)/"
try { Start-Process $url } catch { Write-Host "Open this URL manually: $url" }

try {
    Invoke-ServerLoop -Listener $listener -WebRoot (Join-Path $PSScriptRoot 'web')
} finally {
    try { $listener.Stop() } catch {}
    try { $listener.Close() } catch {}
    Write-Log INFO "Server stopped"
}
