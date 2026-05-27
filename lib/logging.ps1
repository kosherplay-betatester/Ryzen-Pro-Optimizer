Set-StrictMode -Version Latest

$script:LogFile = Join-Path $PSScriptRoot '..\runtime\server.log'
$script:LogLevel = 'INFO'  # DEBUG, INFO, WARN, ERROR

function Write-Log {
    param(
        [Parameter(Mandatory)][ValidateSet('DEBUG','INFO','WARN','ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $levels = @{ DEBUG=0; INFO=1; WARN=2; ERROR=3 }
    if ($levels[$Level] -lt $levels[$script:LogLevel]) { return }

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    $dir = Split-Path $script:LogFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    # Rotate if > 5MB
    if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 5MB)) {
        Move-Item -Force $script:LogFile "$($script:LogFile).old"
    }

    Add-Content -Path $script:LogFile -Value $line
    if ($Level -in @('WARN','ERROR')) { Write-Host $line }
}

function Set-LogLevel { param([string]$Level) $script:LogLevel = $Level }
function Get-LogPath { $script:LogFile }
function Set-LogPath { param([string]$Path) $script:LogFile = $Path }
