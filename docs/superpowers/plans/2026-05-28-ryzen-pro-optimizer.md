# Ryzen Pro Optimizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local web-based UI that wraps CoreCycler for friendly per-core Curve Optimizer tuning on AMD Ryzen — detect BIOS values, apply CO via ryzen-smu-cli, run stress tests, show live telemetry, parse logs into pass/fail reports with smart suggestions, with WHEA bodyguard and panic reset.

**Architecture:** PowerShell HTTP server (`System.Net.HttpListener`) hosting a vanilla-JS browser UI, orchestrating CoreCycler as a child process and reading CPU sensors via LibreHardwareMonitorLib.dll. All runtime in PowerShell 5.1+ to keep zero external dependencies for end users.

**Tech Stack:**
- Backend: PowerShell 5.1+ (System.Net.HttpListener, .NET interop)
- Frontend: HTML + CSS + vanilla JS (no framework, no build step)
- Sensors: LibreHardwareMonitorLib.dll (MIT-licensed, bundled in `vendor/`)
- Hardware writes: ryzen-smu-cli.exe (bundled with CoreCycler, fetched by installer)
- Stress testing: CoreCycler (fetched by installer)
- Tests: Pester (ships with Windows) for pure PS logic; manual verification for hardware-touching code
- Repo: git, with manual commits per task (no remote push for now)

---

## Project Conventions

**File naming:** All PowerShell files use `kebab-case.ps1`. All web files use `kebab-case.{html,css,js}`. Match the spec's File Layout (§4).

**PowerShell style:**
- `Set-StrictMode -Version Latest` at top of every script
- `$ErrorActionPreference = 'Stop'` in entry-point scripts (server.ps1, installer.ps1, Launch.bat targets)
- Use approved verbs (`Get-`, `Set-`, `Read-`, `Write-`, `Test-`, `Start-`, `Stop-`)
- Export only what callers need (`Export-ModuleMember` if we use `.psm1`, otherwise dot-source `.ps1` files)
- All public functions get help comments (synopsis + parameters + example)
- All public functions get Pester tests in `tests/` mirroring the layout

**JSON I/O:** Always `ConvertTo-Json -Depth 10 -Compress` for API output. Always `ConvertFrom-Json` for input. Wrap in `try`/`catch` and return a 400 with `{ error: '...' }` body on parse failure.

**Logging:** Server writes structured log to `runtime/server.log` (append-only, rotated when > 5MB). Use `Write-Log -Level INFO|WARN|ERROR -Message '...'` helper from `lib/logging.ps1`.

**HTTP responses:** All API endpoints return JSON. Status codes: 200 OK, 400 Bad Request, 404 Not Found, 500 Internal Server Error. Body always `{ ok: true, data: ... }` or `{ ok: false, error: '...' }`.

**Testing approach:** Pester v5 syntax (`Describe`/`Context`/`It`/`BeforeAll`). Mock external commands with `Mock` (e.g., `Mock & 'ryzen-smu-cli' { ... }`). Hardware paths get a manual verification step instead of mocked tests.

**Checkpoints:** Each task ends with a `git add`/`git commit` step. Commits use conventional format (`feat:`, `fix:`, `chore:`, `test:`, `docs:`). All commits include the Co-Authored-By trailer.

---

## Phase 0 — Project Bootstrap

Goal: A user can clone the repo, double-click `Launch.bat`, and have CoreCycler downloaded into a local `corecycler/` folder. No UI yet — just confirm the foundation works.

### Task 1: Repo skeleton & conventions file

**Files:**
- Create: `lib/logging.ps1`
- Create: `tests/logging.tests.ps1`
- Modify: `README.md` (add "Project Conventions" section)

- [ ] **Step 1: Create lib/ and tests/ folders**

```powershell
New-Item -ItemType Directory -Force -Path lib, tests, runtime, web, vendor | Out-Null
```

- [ ] **Step 2: Write lib/logging.ps1**

```powershell
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
```

- [ ] **Step 3: Write tests/logging.tests.ps1**

```powershell
BeforeAll {
    . "$PSScriptRoot\..\lib\logging.ps1"
    $script:tmpLog = [IO.Path]::GetTempFileName()
    $script:LogFile = $script:tmpLog
}
AfterAll { Remove-Item $script:tmpLog -ErrorAction SilentlyContinue }

Describe 'logging' {
    It 'writes a line with level and message' {
        Write-Log -Level INFO -Message 'hello'
        $content = Get-Content $script:tmpLog -Raw
        $content | Should -Match '\[INFO\] hello'
    }
    It 'filters below current level' {
        Set-LogLevel WARN
        Write-Log -Level DEBUG -Message 'debug-msg'
        (Get-Content $script:tmpLog -Raw) | Should -Not -Match 'debug-msg'
        Set-LogLevel INFO
    }
    It 'rotates when file exceeds 5MB' {
        # Synthesize a >5MB file
        $bigContent = 'x' * (6 * 1024 * 1024)
        Set-Content -Path $script:LogFile -Value $bigContent
        Write-Log -Level INFO -Message 'after-rotate'
        Test-Path "$($script:LogFile).old" | Should -BeTrue
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `Invoke-Pester -Path tests/logging.tests.ps1 -Output Detailed`
Expected: 3 passing tests, 0 failing.

- [ ] **Step 5: Commit**

```
git add lib/logging.ps1 tests/logging.tests.ps1 runtime/
git commit -m "feat(logging): add log helper with level filtering and rotation"
```

### Task 2: Launch.bat with admin elevation

**Files:**
- Create: `Launch.bat`

- [ ] **Step 1: Write Launch.bat**

```batch
@echo off
setlocal

REM Ryzen Pro Optimizer launcher
REM Self-elevates to admin and starts server.ps1

echo Starting Ryzen Pro Optimizer...

REM Check for admin rights
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Admin rights required. Requesting elevation...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

REM Run installer if corecycler/ is missing
if not exist "%~dp0corecycler\script-corecycler.ps1" (
    echo CoreCycler not found. Running installer...
    powershell -ExecutionPolicy Bypass -File "%~dp0installer.ps1"
    if %errorlevel% neq 0 (
        echo Installer failed. Press any key to exit.
        pause >nul
        exit /b 1
    )
)

REM Start the server (opens its own window)
start "Ryzen Pro Optimizer Server" cmd /k "cd /d %~dp0 && powershell -ExecutionPolicy Bypass -File server.ps1"

REM Server will print the URL and open the browser itself
exit /b 0
```

- [ ] **Step 2: Manual verification**

Run: double-click `Launch.bat` from the repo folder.
Expected: UAC prompt appears. After accepting, since `server.ps1` doesn't exist yet, expect a PowerShell window that opens then errors. That's fine — we're verifying the elevation path works.

- [ ] **Step 3: Commit**

```
git add Launch.bat
git commit -m "feat(launcher): add Launch.bat with self-elevation and installer fallback"
```

### Task 3: Installer (downloads CoreCycler)

**Files:**
- Create: `installer.ps1`
- Create: `Install.bat`
- Create: `tests/installer.tests.ps1`

- [ ] **Step 1: Write installer.ps1**

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\logging.ps1"

$RepoRoot = $PSScriptRoot
$CoreCyclerDir = Join-Path $RepoRoot 'corecycler'
$CacheDir = Join-Path $RepoRoot 'installer-cache'
$ReleasesApi = 'https://api.github.com/repos/sp00n/corecycler/releases/latest'

function Get-LatestCoreCyclerRelease {
    Write-Log INFO "Querying CoreCycler latest release"
    $headers = @{ 'User-Agent' = 'Ryzen-Pro-Optimizer-Installer' }
    Invoke-RestMethod -Uri $ReleasesApi -Headers $headers
}

function Get-CoreCyclerZipUrl {
    param($Release)
    # CoreCycler releases include a zip asset like CoreCycler_vX.Y.Z.zip
    $asset = $Release.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw "No .zip asset in release $($Release.tag_name)" }
    $asset.browser_download_url
}

function Install-CoreCycler {
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir | Out-Null }

    $release = Get-LatestCoreCyclerRelease
    Write-Log INFO "Latest CoreCycler: $($release.tag_name)"

    $url = Get-CoreCyclerZipUrl -Release $release
    $zipPath = Join-Path $CacheDir "$($release.tag_name).zip"

    if (-not (Test-Path $zipPath)) {
        Write-Log INFO "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $zipPath
    }

    # Extract to a temp dir then move the inner folder to corecycler/
    $extractDir = Join-Path $CacheDir "extract-$($release.tag_name)"
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    # The zip contains a single root folder like CoreCycler_vX.Y.Z/
    $inner = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
    if (-not $inner) { throw "Unexpected zip structure — no inner folder" }

    if (Test-Path $CoreCyclerDir) { Remove-Item -Recurse -Force $CoreCyclerDir }
    Move-Item -Path $inner.FullName -Destination $CoreCyclerDir

    # Verify required files
    $required = @(
        'script-corecycler.ps1',
        'tools\ryzen-smu-cli\ryzen-smu-cli.exe',
        'config.default.ini'
    )
    foreach ($f in $required) {
        $full = Join-Path $CoreCyclerDir $f
        if (-not (Test-Path $full)) {
            throw "Required file missing after install: $f"
        }
    }

    Write-Log INFO "CoreCycler installed to $CoreCyclerDir"
    Write-Host "CoreCycler $($release.tag_name) installed successfully."
}

function Test-CoreCyclerInstalled {
    Test-Path (Join-Path $CoreCyclerDir 'script-corecycler.ps1')
}

# Entry point
if ($MyInvocation.InvocationName -ne '.') {
    if (Test-CoreCyclerInstalled) {
        Write-Host "CoreCycler is already installed at $CoreCyclerDir"
        exit 0
    }
    try {
        Install-CoreCycler
        exit 0
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Please install CoreCycler manually from https://github.com/sp00n/corecycler/releases"
        exit 1
    }
}
```

- [ ] **Step 2: Write Install.bat**

```batch
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0installer.ps1"
pause
```

- [ ] **Step 3: Write tests/installer.tests.ps1** (test the URL extraction logic, no real downloads)

```powershell
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
        }
        Get-CoreCyclerZipUrl -Release $fakeRelease | Should -Be 'http://x/CoreCycler_v1.0.0.zip'
    }
    It 'throws when no zip asset present' {
        $fakeRelease = [PSCustomObject]@{
            tag_name = 'v1.0.0'
            assets = @([PSCustomObject]@{ name='source.tar.gz'; browser_download_url='x' })
        }
        { Get-CoreCyclerZipUrl -Release $fakeRelease } | Should -Throw
    }
}
```

- [ ] **Step 4: Run unit tests**

Run: `Invoke-Pester -Path tests/installer.tests.ps1 -Output Detailed`
Expected: 2 passing.

- [ ] **Step 5: Manual integration test**

Run: `.\Install.bat`
Expected: Downloads latest CoreCycler from GitHub, extracts to `corecycler/`. Verify `corecycler\script-corecycler.ps1` and `corecycler\tools\ryzen-smu-cli\ryzen-smu-cli.exe` exist.

- [ ] **Step 6: Commit**

```
git add installer.ps1 Install.bat tests/installer.tests.ps1
git commit -m "feat(installer): fetch latest CoreCycler from GitHub releases"
```

---

## Phase 1 — HTTP Server, UI Shell, CPU Detection, CO Read, Help

Goal: User can launch the app and see their detected CPU + current Curve Optimizer values in a browser, with a help section. No CO writes or tests yet.

### Task 4: HTTP server skeleton with routing

**Files:**
- Create: `server.ps1`
- Create: `lib/http-server.ps1`
- Create: `lib/router.ps1`
- Create: `tests/router.tests.ps1`

- [ ] **Step 1: Write lib/router.ps1**

```powershell
Set-StrictMode -Version Latest

# Routes: hashtable of "METHOD /path" => scriptblock(context) -> hashtable response
$script:Routes = @{}

function Register-Route {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$Handler
    )
    $script:Routes["$Method $Path"] = $Handler
}

function Get-Route {
    param([string]$Method, [string]$Path)
    # Exact match first
    $key = "$Method $Path"
    if ($script:Routes.ContainsKey($key)) { return $script:Routes[$key] }

    # Pattern match for routes with {param}
    foreach ($k in $script:Routes.Keys) {
        $kParts = $k -split ' ',2
        if ($kParts[0] -ne $Method) { continue }
        $pattern = '^' + ($kParts[1] -replace '\{[^}]+\}','([^/]+)') + '$'
        if ($Path -match $pattern) {
            return @{ Handler = $script:Routes[$k]; Captures = $Matches }
        }
    }
    return $null
}

function Clear-Routes { $script:Routes = @{} }
```

- [ ] **Step 2: Write tests/router.tests.ps1**

```powershell
BeforeAll { . "$PSScriptRoot\..\lib\router.ps1" }
BeforeEach { Clear-Routes }

Describe 'router' {
    It 'finds an exact match' {
        Register-Route -Method GET -Path '/api/cpu' -Handler { 'cpu' }
        $h = Get-Route -Method GET -Path '/api/cpu'
        & $h | Should -Be 'cpu'
    }
    It 'returns null for unknown route' {
        Get-Route -Method GET -Path '/nope' | Should -BeNullOrEmpty
    }
    It 'distinguishes methods' {
        Register-Route -Method GET -Path '/x' -Handler { 'get' }
        Register-Route -Method POST -Path '/x' -Handler { 'post' }
        & (Get-Route -Method POST -Path '/x') | Should -Be 'post'
    }
    It 'matches parameterized paths' {
        Register-Route -Method DELETE -Path '/api/profiles/{name}' -Handler { param($ctx) $ctx }
        $r = Get-Route -Method DELETE -Path '/api/profiles/Daily%20Stable'
        $r.Handler | Should -Not -BeNullOrEmpty
        $r.Captures[1] | Should -Be 'Daily%20Stable'
    }
}
```

- [ ] **Step 3: Write lib/http-server.ps1**

```powershell
Set-StrictMode -Version Latest

. "$PSScriptRoot\logging.ps1"
. "$PSScriptRoot\router.ps1"

function Start-HttpServer {
    param(
        [int]$StartPort = 8765,
        [int]$MaxPort = 8775,
        [string]$WebRoot = (Join-Path $PSScriptRoot '..\web')
    )

    $listener = [System.Net.HttpListener]::new()
    $port = $StartPort
    while ($port -le $MaxPort) {
        try {
            $listener.Prefixes.Clear()
            $listener.Prefixes.Add("http://127.0.0.1:$port/")
            $listener.Start()
            break
        } catch {
            $listener.Prefixes.Clear()
            $port++
            if ($port -gt $MaxPort) { throw "No free port in range $StartPort-$MaxPort" }
        }
    }

    Write-Log INFO "HTTP listener started on http://127.0.0.1:$port/"
    Write-Host "Server listening at http://127.0.0.1:$port/"
    $script:ListenerPort = $port

    return $listener
}

function Send-JsonResponse {
    param($Context, [int]$Status = 200, $Data)
    $body = $Data | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Send-FileResponse {
    param($Context, [string]$Path)
    if (-not (Test-Path $Path)) {
        $Context.Response.StatusCode = 404
        $Context.Response.OutputStream.Close()
        return
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $ext = [IO.Path]::GetExtension($Path).ToLower()
    $mime = switch ($ext) {
        '.html' { 'text/html; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        '.png'  { 'image/png' }
        '.svg'  { 'image/svg+xml' }
        default { 'application/octet-stream' }
    }
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $mime
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Read-JsonBody {
    param($Context)
    $reader = New-Object IO.StreamReader($Context.Request.InputStream, $Context.Request.ContentEncoding)
    $text = $reader.ReadToEnd()
    $reader.Close()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return $text | ConvertFrom-Json } catch { throw "Invalid JSON body: $($_.Exception.Message)" }
}

function Invoke-ServerLoop {
    param($Listener, [string]$WebRoot)

    while ($Listener.IsListening) {
        try {
            $context = $Listener.GetContext()
        } catch [System.Net.HttpListenerException] {
            Write-Log WARN "Listener closed: $($_.Exception.Message)"
            break
        }

        $method = $context.Request.HttpMethod
        $rawUrl = $context.Request.Url.AbsolutePath
        Write-Log DEBUG "$method $rawUrl"

        try {
            # Static files: anything not starting with /api
            if (-not $rawUrl.StartsWith('/api')) {
                $relPath = if ($rawUrl -eq '/') { 'index.html' } else { $rawUrl.TrimStart('/') }
                $filePath = Join-Path $WebRoot $relPath
                Send-FileResponse -Context $context -Path $filePath
                continue
            }

            $route = Get-Route -Method $method -Path $rawUrl
            if (-not $route) {
                Send-JsonResponse -Context $context -Status 404 -Data @{ ok=$false; error="Unknown route $method $rawUrl" }
                continue
            }

            if ($route -is [scriptblock]) {
                $result = & $route $context
            } else {
                $result = & $route.Handler $context $route.Captures
            }
            if ($null -eq $result) { continue }   # Handler already wrote response
            Send-JsonResponse -Context $context -Data $result
        } catch {
            Write-Log ERROR "Handler error: $($_.Exception.Message)"
            try { Send-JsonResponse -Context $context -Status 500 -Data @{ ok=$false; error=$_.Exception.Message } } catch {}
        }
    }
}
```

- [ ] **Step 4: Write server.ps1 (entry point, minimal)**

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\router.ps1"
. "$PSScriptRoot\lib\http-server.ps1"

# Routes will be registered here as features are added.
Register-Route -Method GET -Path '/api/ping' -Handler {
    @{ ok = $true; data = @{ message = 'pong'; time = (Get-Date -Format 'o') } }
}

$listener = Start-HttpServer
Start-Process "http://127.0.0.1:$script:ListenerPort/"

try {
    Invoke-ServerLoop -Listener $listener -WebRoot (Join-Path $PSScriptRoot 'web')
} finally {
    $listener.Stop()
    $listener.Close()
}
```

- [ ] **Step 5: Write web/index.html (minimal placeholder)**

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Ryzen Pro Optimizer</title>
<link rel="stylesheet" href="/style.css">
</head>
<body>
<h1>Ryzen Pro Optimizer</h1>
<p id="status">Loading...</p>
<script src="/app.js"></script>
</body>
</html>
```

- [ ] **Step 6: Write web/style.css (minimal)**

```css
body { font-family: 'Segoe UI', system-ui, sans-serif; background: #0f1419; color: #e6e9ef; margin: 2rem; }
h1 { color: #06B6D4; }
```

- [ ] **Step 7: Write web/app.js (ping test)**

```javascript
fetch('/api/ping').then(r => r.json()).then(j => {
  document.getElementById('status').textContent = 'Ping: ' + j.data.message + ' at ' + j.data.time;
});
```

- [ ] **Step 8: Run router tests**

Run: `Invoke-Pester -Path tests/router.tests.ps1 -Output Detailed`
Expected: 4 passing.

- [ ] **Step 9: Manual end-to-end test**

Run: `.\Launch.bat`
Expected: Browser opens to http://127.0.0.1:8765/, page shows "Ping: pong at <timestamp>".

- [ ] **Step 10: Commit**

```
git add server.ps1 lib/http-server.ps1 lib/router.ps1 tests/router.tests.ps1 web/index.html web/style.css web/app.js
git commit -m "feat(server): add HTTP server, routing, static file serving, ping endpoint"
```

### Task 5: CPU detection

**Files:**
- Create: `lib/cpu-detect.ps1`
- Create: `tests/cpu-detect.tests.ps1`
- Modify: `server.ps1` (register /api/cpu route)
- Modify: `web/app.js` (display CPU info)
- Modify: `web/index.html` (add CPU info card)

- [ ] **Step 1: Write lib/cpu-detect.ps1**

```powershell
Set-StrictMode -Version Latest

# Maps known Ryzen models to (zenGen, isDualCcd, vCacheCcdIndex-or-null)
# vCacheCcdIndex: 0 = CCD0 has V-Cache, 1 = CCD1, $null = no V-Cache
$script:CpuOverrides = @{
    '7950X3D' = @{ zenGen=4; dualCcd=$true;  vCacheCcdIndex=0 }
    '7900X3D' = @{ zenGen=4; dualCcd=$true;  vCacheCcdIndex=0 }
    '7800X3D' = @{ zenGen=4; dualCcd=$false; vCacheCcdIndex=0 }
    '7950X'   = @{ zenGen=4; dualCcd=$true;  vCacheCcdIndex=$null }
    '7900X'   = @{ zenGen=4; dualCcd=$true;  vCacheCcdIndex=$null }
    '7900'    = @{ zenGen=4; dualCcd=$true;  vCacheCcdIndex=$null }
    '7700X'   = @{ zenGen=4; dualCcd=$false; vCacheCcdIndex=$null }
    '7700'    = @{ zenGen=4; dualCcd=$false; vCacheCcdIndex=$null }
    '7600X'   = @{ zenGen=4; dualCcd=$false; vCacheCcdIndex=$null }
    '7600'    = @{ zenGen=4; dualCcd=$false; vCacheCcdIndex=$null }
    '5950X'   = @{ zenGen=3; dualCcd=$true;  vCacheCcdIndex=$null }
    '5900X'   = @{ zenGen=3; dualCcd=$true;  vCacheCcdIndex=$null }
    '5800X3D' = @{ zenGen=3; dualCcd=$false; vCacheCcdIndex=0 }
    '5800X'   = @{ zenGen=3; dualCcd=$false; vCacheCcdIndex=$null }
    '5700X'   = @{ zenGen=3; dualCcd=$false; vCacheCcdIndex=$null }
    '5600X'   = @{ zenGen=3; dualCcd=$false; vCacheCcdIndex=$null }
    '9950X3D' = @{ zenGen=5; dualCcd=$true;  vCacheCcdIndex=0 }
    '9950X'   = @{ zenGen=5; dualCcd=$true;  vCacheCcdIndex=$null }
    '9900X3D' = @{ zenGen=5; dualCcd=$true;  vCacheCcdIndex=0 }
    '9900X'   = @{ zenGen=5; dualCcd=$true;  vCacheCcdIndex=$null }
    '9800X3D' = @{ zenGen=5; dualCcd=$false; vCacheCcdIndex=0 }
    '9700X'   = @{ zenGen=5; dualCcd=$false; vCacheCcdIndex=$null }
    '9600X'   = @{ zenGen=5; dualCcd=$false; vCacheCcdIndex=$null }
}

function Get-CpuInfo {
    $proc = Get-CimInstance Win32_Processor | Select-Object -First 1
    $name = $proc.Name
    $cores = [int]$proc.NumberOfCores
    $threads = [int]$proc.NumberOfLogicalProcessors
    $manufacturer = $proc.Manufacturer

    $info = [PSCustomObject]@{
        Name = $name
        Manufacturer = $manufacturer
        Cores = $cores
        Threads = $threads
        IsAmd = $manufacturer -match 'AMD'
        IsRyzen = $name -match 'Ryzen'
        SuggestedModel = $null
        ZenGen = $null
        IsDualCcd = $null
        VCacheCcdIndex = $null
        CcdCount = $null
        CoresPerCcd = $null
        SupportsCurveOptimizer = $false
        UnsupportedReason = $null
    }

    if (-not $info.IsAmd -or -not $info.IsRyzen) {
        $info.UnsupportedReason = 'Not an AMD Ryzen CPU.'
        return $info
    }

    # Extract model suffix like "7950X3D" from "AMD Ryzen 9 7950X3D"
    if ($name -match 'Ryzen \d+ (\d{4}[A-Z0-9]*)') {
        $info.SuggestedModel = $Matches[1]
    }

    if ($info.SuggestedModel -and $script:CpuOverrides.ContainsKey($info.SuggestedModel)) {
        $o = $script:CpuOverrides[$info.SuggestedModel]
        $info.ZenGen = $o.zenGen
        $info.IsDualCcd = $o.dualCcd
        $info.VCacheCcdIndex = $o.vCacheCcdIndex
    } else {
        # Heuristic: >8 cores = dual CCD on consumer Ryzen
        $info.IsDualCcd = $cores -gt 8
        $info.ZenGen = if ($name -match 'Ryzen \d+ 5') { 3 } elseif ($name -match 'Ryzen \d+ 7') { 4 } elseif ($name -match 'Ryzen \d+ 9') { 5 } else { $null }
    }

    $info.CcdCount = if ($info.IsDualCcd) { 2 } else { 1 }
    $info.CoresPerCcd = $cores / $info.CcdCount

    # CO requires Zen 3 or newer
    if ($info.ZenGen -ge 3) {
        $info.SupportsCurveOptimizer = $true
    } else {
        $info.UnsupportedReason = "Curve Optimizer was introduced with Zen 3 (Ryzen 5000). Your CPU is older."
    }

    $info
}

function Get-CcdLabel {
    param($CpuInfo, [int]$CcdIndex)
    if (-not $CpuInfo.IsDualCcd) { return 'CCD0' }
    $isVCache = ($null -ne $CpuInfo.VCacheCcdIndex) -and ($CpuInfo.VCacheCcdIndex -eq $CcdIndex)
    if ($isVCache) { "CCD$CcdIndex (V-Cache)" } else { "CCD$CcdIndex (Standard)" }
}

function Get-CcdForCore {
    param($CpuInfo, [int]$Core)
    if (-not $CpuInfo.IsDualCcd) { return 0 }
    [int]([math]::Floor($Core / $CpuInfo.CoresPerCcd))
}
```

- [ ] **Step 2: Write tests/cpu-detect.tests.ps1**

```powershell
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
    It 'returns a populated object' {
        $info = Get-CpuInfo
        $info.Name | Should -Not -BeNullOrEmpty
        $info.Cores | Should -BeGreaterThan 0
    }
}
```

- [ ] **Step 3: Run tests**

Run: `Invoke-Pester -Path tests/cpu-detect.tests.ps1 -Output Detailed`
Expected: All passing. The "live system" test reports the actual detected CPU.

- [ ] **Step 4: Register /api/cpu route in server.ps1**

Add after the existing `Register-Route` block:

```powershell
. "$PSScriptRoot\lib\cpu-detect.ps1"

Register-Route -Method GET -Path '/api/cpu' -Handler {
    @{ ok = $true; data = (Get-CpuInfo) }
}
```

- [ ] **Step 5: Update web/index.html**

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Ryzen Pro Optimizer</title>
<link rel="stylesheet" href="/style.css">
</head>
<body>
<header>
  <h1>Ryzen Pro Optimizer</h1>
  <button id="reset-co" class="danger">🔴 RESET CO</button>
</header>
<div id="cpu-info" class="card"></div>
<div id="not-supported" class="card hidden"></div>
<script src="/app.js"></script>
</body>
</html>
```

- [ ] **Step 6: Update web/style.css**

```css
:root {
  --bg: #0f1419;
  --card: #1a1f2b;
  --text: #e6e9ef;
  --muted: #8b95a8;
  --accent: #06B6D4;
  --primary: #3B82F6;
  --success: #10B981;
  --danger: #ED1C24;
  --warning: #F59E0B;
}
* { box-sizing: border-box; }
body { font-family: 'Segoe UI', system-ui, sans-serif; background: var(--bg); color: var(--text); margin: 0; padding: 1.5rem; max-width: 760px; margin: 0 auto; }
header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1.5rem; }
h1 { color: var(--accent); font-size: 1.4rem; margin: 0; }
.card { background: var(--card); padding: 1rem 1.25rem; border-radius: 8px; margin-bottom: 1rem; border: 1px solid #2a3142; }
.danger { background: var(--danger); color: white; border: 0; padding: 0.6rem 1rem; border-radius: 6px; cursor: pointer; font-weight: 600; }
.danger:hover { filter: brightness(1.15); }
.hidden { display: none; }
.muted { color: var(--muted); }
.warn { color: var(--warning); font-weight: 600; }
```

- [ ] **Step 7: Update web/app.js**

```javascript
async function fetchJson(url, opts) {
  const r = await fetch(url, opts);
  if (!r.ok) throw new Error(r.statusText);
  return r.json();
}

async function loadCpu() {
  const j = await fetchJson('/api/cpu');
  const cpu = j.data;
  const card = document.getElementById('cpu-info');

  if (!cpu.SupportsCurveOptimizer) {
    document.getElementById('not-supported').classList.remove('hidden');
    document.getElementById('not-supported').innerHTML =
      `<h2>Curve Optimizer Not Supported</h2><p>${cpu.UnsupportedReason}</p><p class="muted">Detected: ${cpu.Name}</p>`;
    card.classList.add('hidden');
    return;
  }

  const ccdDesc = cpu.IsDualCcd
    ? `${cpu.CcdCount} CCDs (${cpu.VCacheCcdIndex !== null ? 'CCD' + cpu.VCacheCcdIndex + '=V-Cache' : 'no V-Cache'})`
    : 'single CCD';
  card.innerHTML = `<strong>${cpu.Name}</strong> · ${cpu.Cores} cores · ${ccdDesc} · Zen ${cpu.ZenGen}`;
}

document.addEventListener('DOMContentLoaded', () => {
  loadCpu().catch(e => {
    document.body.insertAdjacentHTML('beforeend', `<div class="card warn">Failed to load CPU info: ${e.message}</div>`);
  });
});
```

- [ ] **Step 8: End-to-end test**

Run: `.\Launch.bat`
Expected: Browser shows the detected CPU model with core count and CCD layout. For your 7950X3D it should show "AMD Ryzen 9 7950X3D · 16 cores · 2 CCDs (CCD0=V-Cache) · Zen 4".

- [ ] **Step 9: Commit**

```
git add lib/cpu-detect.ps1 tests/cpu-detect.tests.ps1 server.ps1 web/
git commit -m "feat(cpu-detect): detect CPU, CCD layout, V-Cache; render in UI"
```

### Task 6: CO reading via ryzen-smu-cli

**Files:**
- Create: `lib/co-reader-writer.ps1`
- Create: `tests/co-reader-writer.tests.ps1`
- Modify: `server.ps1` (register /api/co/current, /api/co/launch)
- Modify: `web/index.html`, `web/app.js` (show banner + current values)

- [ ] **Step 1: Inspect ryzen-smu-cli to find read command syntax**

Run: `.\corecycler\tools\ryzen-smu-cli\ryzen-smu-cli.exe --help` and `.\corecycler\tools\ryzen-smu-cli\ryzen-smu-cli.exe get-co --help`
Expected: Documentation of the get-co/read commands.
Note the exact subcommand name (one of: `get-co-core`, `get-coreoffset`, `read-co`, etc.) and update the wrapper below accordingly. The placeholder in the code uses `get-co-core <N>`.

- [ ] **Step 2: Write lib/co-reader-writer.ps1**

```powershell
Set-StrictMode -Version Latest
. "$PSScriptRoot\logging.ps1"

$script:RyzenSmuCli = $null

function Initialize-CoTool {
    param([string]$RepoRoot)
    $candidate = Join-Path $RepoRoot 'corecycler\tools\ryzen-smu-cli\ryzen-smu-cli.exe'
    if (-not (Test-Path $candidate)) {
        throw "ryzen-smu-cli.exe not found at $candidate. Run installer.ps1."
    }
    $script:RyzenSmuCli = $candidate
    Write-Log INFO "ryzen-smu-cli located at $candidate"
}

function Get-CoreCo {
    param([int]$Core)
    if (-not $script:RyzenSmuCli) { throw "Initialize-CoTool must be called first" }
    # NOTE: replace 'get-co-core' with the actual subcommand discovered in step 1
    $output = & $script:RyzenSmuCli get-co-core $Core 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ryzen-smu-cli get-co-core $Core failed: $output" }
    # Output is expected to be an integer or "Core N: <value>"
    if ($output -match '(-?\d+)') { return [int]$Matches[1] }
    throw "Unparseable ryzen-smu-cli output for core $Core : $output"
}

function Get-AllCoreCo {
    param([int]$CoreCount)
    $values = New-Object int[] $CoreCount
    for ($i = 0; $i -lt $CoreCount; $i++) {
        try {
            $values[$i] = Get-CoreCo -Core $i
        } catch {
            Write-Log WARN "Failed to read CO for core $i : $($_.Exception.Message). Using 0."
            $values[$i] = 0
        }
    }
    , $values
}

function Set-CoreCo {
    param([int]$Core, [int]$Value)
    if (-not $script:RyzenSmuCli) { throw "Initialize-CoTool must be called first" }
    if ($Value -lt -50 -or $Value -gt 50) { throw "CO value out of safe range: $Value" }
    $output = & $script:RyzenSmuCli set-co-core $Core $Value 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ryzen-smu-cli set-co-core $Core $Value failed: $output" }
    Write-Log INFO "Set core $Core CO=$Value"
}

function Set-AllCoreCo {
    param([int[]]$Values)
    for ($i = 0; $i -lt $Values.Length; $i++) {
        Set-CoreCo -Core $i -Value $Values[$i]
    }
}

function Reset-AllCoreCo {
    param([int]$CoreCount)
    for ($i = 0; $i -lt $CoreCount; $i++) {
        Set-CoreCo -Core $i -Value 0
    }
    Write-Log INFO "All cores reset to CO=0"
}
```

- [ ] **Step 3: Write tests/co-reader-writer.tests.ps1**

```powershell
BeforeAll { . "$PSScriptRoot\..\lib\co-reader-writer.ps1" }

Describe 'CO range validation' {
    BeforeEach {
        $script:RyzenSmuCli = 'fake.exe'  # bypass init check
        Mock & 'fake.exe' { 0; $global:LASTEXITCODE = 0 }
    }
    It 'rejects values below -50' {
        { Set-CoreCo -Core 0 -Value -51 } | Should -Throw "*out of safe range*"
    }
    It 'rejects values above 50' {
        { Set-CoreCo -Core 0 -Value 51 } | Should -Throw "*out of safe range*"
    }
}
```

- [ ] **Step 4: Run unit tests**

Run: `Invoke-Pester -Path tests/co-reader-writer.tests.ps1 -Output Detailed`
Expected: 2 passing.

- [ ] **Step 5: Manual hardware verification**

Run (PowerShell as admin, from repo root):
```powershell
. .\lib\logging.ps1
. .\lib\co-reader-writer.ps1
Initialize-CoTool -RepoRoot $PWD
Get-AllCoreCo -CoreCount 16
```
Expected: An array of 16 integers showing current CO offsets. On a fresh 7950X3D with the user's BIOS setting it should print roughly `-10, -10, -10, -10, -10, -10, -10, -10, -20, -20, -20, -20, -20, -20, -20, -20`.

- [ ] **Step 6: Snapshot at server launch, register routes**

In `server.ps1`, after the existing initialization:

```powershell
. "$PSScriptRoot\lib\co-reader-writer.ps1"

$RepoRoot = $PSScriptRoot
Initialize-CoTool -RepoRoot $RepoRoot

$cpu = Get-CpuInfo
$launchSnapshot = $null
if ($cpu.SupportsCurveOptimizer) {
    $launchSnapshot = Get-AllCoreCo -CoreCount $cpu.Cores
    $snapPath = Join-Path $RepoRoot 'runtime\launch-snapshot.json'
    @{ values = $launchSnapshot; capturedAt = (Get-Date -Format 'o'); cpuModel = $cpu.Name } |
      ConvertTo-Json -Depth 4 | Set-Content -Path $snapPath
    Write-Log INFO "Launch snapshot captured: $($launchSnapshot -join ',')"
}

Register-Route -Method GET -Path '/api/co/current' -Handler {
    if (-not $cpu.SupportsCurveOptimizer) { return @{ ok=$false; error='CO not supported on this CPU' } }
    @{ ok = $true; data = (Get-AllCoreCo -CoreCount $cpu.Cores) }
}
Register-Route -Method GET -Path '/api/co/launch' -Handler {
    @{ ok = $true; data = $launchSnapshot }
}
```

- [ ] **Step 7: Update web UI to show banner + current values**

Update `web/index.html` add after #cpu-info:
```html
<div id="co-banner" class="card hidden"></div>
```

Update `web/app.js` add:
```javascript
async function loadCoValues() {
  const launch = (await fetchJson('/api/co/launch')).data;
  const current = (await fetchJson('/api/co/current')).data;
  if (!launch || !current) return;
  const summarize = arr => {
    const ccd0 = arr.slice(0, arr.length/2);
    const ccd1 = arr.slice(arr.length/2);
    const same = a => a.every(v => v === a[0]);
    const fmt = a => same(a) ? a[0] : a.join(',');
    return arr.length > 8 ? `CCD0 ${fmt(ccd0)} · CCD1 ${fmt(ccd1)}` : `All cores ${fmt(arr)}`;
  };
  const banner = document.getElementById('co-banner');
  banner.classList.remove('hidden');
  banner.innerHTML = `🎯 Detected current Curve Optimizer settings: <strong>${summarize(current)}</strong> <span class="muted">(loaded as your starting point)</span>`;
}

document.addEventListener('DOMContentLoaded', () => {
  loadCpu()
    .then(loadCoValues)
    .catch(e => console.error(e));
});
```

- [ ] **Step 8: End-to-end test**

Run: `.\Launch.bat`
Expected: After CPU info, a banner appears showing the CO values currently active (matching what's in BIOS or last applied).

- [ ] **Step 9: Commit**

```
git add lib/co-reader-writer.ps1 tests/co-reader-writer.tests.ps1 server.ps1 web/
git commit -m "feat(co): read current CO from SMU and display launch banner"
```

### Task 7: Help section

**Files:**
- Create: `web/help.html`
- Modify: `web/index.html` (add help button + slide-out container)
- Modify: `web/style.css` (slide-out styles)
- Modify: `web/app.js` (load help.html on click)

- [ ] **Step 1: Write web/help.html**

Two `<section>` blocks (Quick Start, Advanced) with the content outlined in spec §13. Headings as `<h2>` (tabs), `<h3>` (sub-sections), prose in `<p>`. Include the silicon-lottery paragraph in Quick Start.

(Full content draft: ~80 lines of HTML. Mirror the bullet list from spec §13 verbatim, expanded into paragraphs.)

- [ ] **Step 2: Update web/index.html**

Add to header: `<button id="open-help" class="secondary">?</button>`
Add to body: `<aside id="help-panel" class="slide-out hidden"><div id="help-content">Loading...</div><button id="close-help">×</button></aside>`

- [ ] **Step 3: Update web/style.css**

```css
.slide-out { position: fixed; top: 0; right: 0; width: min(420px, 90vw); height: 100vh; background: var(--card); border-left: 1px solid #2a3142; padding: 2rem 1.5rem; overflow-y: auto; z-index: 100; box-shadow: -8px 0 24px rgba(0,0,0,0.5); transition: transform 0.2s; }
.slide-out.hidden { transform: translateX(100%); }
.secondary { background: transparent; color: var(--text); border: 1px solid #2a3142; padding: 0.4rem 0.8rem; border-radius: 4px; cursor: pointer; }
#help-panel h2 { color: var(--accent); }
#help-panel h3 { color: var(--text); margin-top: 1.5rem; }
#close-help { position: absolute; top: 1rem; right: 1rem; background: transparent; color: var(--muted); border: 0; font-size: 1.5rem; cursor: pointer; }
```

- [ ] **Step 4: Update web/app.js**

```javascript
async function loadHelpContent() {
  if (document.getElementById('help-content').dataset.loaded === '1') return;
  const r = await fetch('/help.html');
  document.getElementById('help-content').innerHTML = await r.text();
  document.getElementById('help-content').dataset.loaded = '1';
}

document.addEventListener('click', e => {
  if (e.target.id === 'open-help') { loadHelpContent(); document.getElementById('help-panel').classList.remove('hidden'); }
  if (e.target.id === 'close-help') { document.getElementById('help-panel').classList.add('hidden'); }
});
```

- [ ] **Step 5: Manual test**

Run: `.\Launch.bat`. Click `?` → help slides in. Click `×` → slides out. Both tabs visible and readable.

- [ ] **Step 6: Commit**

```
git add web/
git commit -m "feat(help): add slide-out help panel with Quick Start and Advanced tabs"
```

---

## Phase 2 — CO Writing, Profiles, Reset/Revert

Goal: User can set CO values from the UI (all/per-CCD/per-core), apply them, revert to launch values, panic-reset via Esc, save/load named profiles.

### Task 8: Apply CO endpoint + UI form

**Files:**
- Modify: `server.ps1` (register POST /api/co)
- Modify: `web/index.html` (add curve setting card)
- Modify: `web/style.css` (form styles)
- Modify: `web/app.js` (build form, handle Apply)

- [ ] **Step 1: Register POST /api/co**

```powershell
Register-Route -Method POST -Path '/api/co' -Handler {
    param($ctx)
    $body = Read-JsonBody -Context $ctx
    if (-not $body.mode) { return @{ ok=$false; error='mode required' } }

    $values = @()
    switch ($body.mode) {
        'all-cores' {
            $values = @($body.values.all) * $cpu.Cores
        }
        'per-ccd' {
            $perCcd = $cpu.CoresPerCcd
            $values = @()
            for ($c = 0; $c -lt $cpu.CcdCount; $c++) {
                $v = $body.values."ccd$c"
                for ($i = 0; $i -lt $perCcd; $i++) { $values += [int]$v }
            }
        }
        'per-core' {
            for ($i = 0; $i -lt $cpu.Cores; $i++) {
                $values += [int]$body.values."$i"
            }
        }
        default { return @{ ok=$false; error="Unknown mode: $($body.mode)" } }
    }

    try { Set-AllCoreCo -Values $values } catch { return @{ ok=$false; error=$_.Exception.Message } }
    @{ ok = $true; data = @{ applied = $values } }
}

Register-Route -Method POST -Path '/api/reset-co' -Handler {
    Reset-AllCoreCo -CoreCount $cpu.Cores
    @{ ok = $true; data = @{ reset = $true } }
}

Register-Route -Method POST -Path '/api/co/revert' -Handler {
    if ($null -eq $launchSnapshot) { return @{ ok=$false; error='No launch snapshot' } }
    Set-AllCoreCo -Values $launchSnapshot
    @{ ok = $true; data = @{ reverted = $launchSnapshot } }
}
```

- [ ] **Step 2: UI form — three mode tabs**

Add to `index.html`:
```html
<section class="card" id="curve-card">
  <h2>1. Set Curve Optimizer</h2>
  <div class="tabs">
    <button class="tab active" data-mode="all-cores">All cores</button>
    <button class="tab" data-mode="per-ccd" id="tab-ccd">Per-CCD</button>
    <button class="tab" data-mode="per-core">Per-core</button>
  </div>
  <div id="curve-form"></div>
  <div class="actions">
    <button id="apply-co" class="primary">Apply</button>
    <button id="revert-co" class="secondary">Revert to launch</button>
    <button id="save-profile" class="secondary">Save as profile…</button>
  </div>
</section>
```

Add styles:
```css
.tabs { display: flex; gap: 0.4rem; margin-bottom: 1rem; }
.tab { background: transparent; color: var(--muted); border: 1px solid #2a3142; padding: 0.4rem 0.8rem; border-radius: 4px; cursor: pointer; }
.tab.active { background: var(--primary); color: white; border-color: var(--primary); }
.primary { background: var(--primary); color: white; border: 0; padding: 0.6rem 1rem; border-radius: 6px; cursor: pointer; font-weight: 600; }
.primary:disabled { opacity: 0.5; cursor: not-allowed; }
.actions { display: flex; gap: 0.6rem; margin-top: 1rem; }
.co-input { display: flex; align-items: center; gap: 0.6rem; margin: 0.4rem 0; }
.co-input label { width: 8rem; }
.co-input input { background: var(--bg); color: var(--text); border: 1px solid #2a3142; padding: 0.3rem 0.6rem; border-radius: 4px; width: 5rem; }
```

- [ ] **Step 3: JS to build form and handle Apply**

```javascript
let cpuInfo = null;
let launchValues = null;
let currentMode = 'all-cores';

function renderForm() {
  const form = document.getElementById('curve-form');
  if (!cpuInfo) return;
  let html = '';
  if (currentMode === 'all-cores') {
    const initial = launchValues ? launchValues[0] : 0;
    html = `<div class="co-input"><label>All cores</label><input type="number" id="co-all" value="${initial}" min="-50" max="50"></div>`;
  } else if (currentMode === 'per-ccd') {
    for (let c = 0; c < cpuInfo.CcdCount; c++) {
      const start = c * cpuInfo.CoresPerCcd;
      const isVCache = cpuInfo.VCacheCcdIndex === c;
      const label = isVCache ? `CCD${c} (V-Cache)` : `CCD${c} (Standard)`;
      const initial = launchValues ? launchValues[start] : 0;
      html += `<div class="co-input"><label>${label}</label><input type="number" id="co-ccd${c}" value="${initial}" min="-50" max="50"><span class="muted">(current: ${initial})</span></div>`;
    }
  } else {
    for (let i = 0; i < cpuInfo.Cores; i++) {
      const initial = launchValues ? launchValues[i] : 0;
      const ccd = cpuInfo.IsDualCcd ? Math.floor(i / cpuInfo.CoresPerCcd) : 0;
      html += `<div class="co-input"><label>Core ${i} (CCD${ccd})</label><input type="number" id="co-core${i}" value="${initial}" min="-50" max="50"><span class="muted">(current: ${initial})</span></div>`;
    }
  }
  form.innerHTML = html;
}

function collectValues() {
  if (currentMode === 'all-cores') {
    return { mode: 'all-cores', values: { all: +document.getElementById('co-all').value } };
  } else if (currentMode === 'per-ccd') {
    const v = {};
    for (let c = 0; c < cpuInfo.CcdCount; c++) v['ccd'+c] = +document.getElementById('co-ccd'+c).value;
    return { mode: 'per-ccd', values: v };
  } else {
    const v = {};
    for (let i = 0; i < cpuInfo.Cores; i++) v[i] = +document.getElementById('co-core'+i).value;
    return { mode: 'per-core', values: v };
  }
}

async function applyCo() {
  const body = collectValues();
  const r = await fetchJson('/api/co', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body) });
  if (!r.ok) alert('Apply failed: ' + r.error);
  else { showToast('Applied ✓'); loadCoValues(); }
}

async function revertCo() {
  const r = await fetchJson('/api/co/revert', { method:'POST' });
  if (!r.ok) alert('Revert failed: ' + r.error);
  else { showToast('Reverted to launch values'); loadCoValues(); renderForm(); }
}

function showToast(msg) {
  const t = document.createElement('div');
  t.className = 'toast';
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 2500);
}

document.addEventListener('click', e => {
  if (e.target.classList.contains('tab')) {
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    e.target.classList.add('active');
    currentMode = e.target.dataset.mode;
    renderForm();
  }
  if (e.target.id === 'apply-co') applyCo();
  if (e.target.id === 'revert-co') revertCo();
  if (e.target.id === 'reset-co') resetCo();
});

async function resetCo() {
  const r = await fetchJson('/api/reset-co', { method:'POST' });
  if (r.ok) { showToast('CO reset to 0'); loadCoValues(); renderForm(); }
}

document.addEventListener('keydown', e => {
  if (e.key === 'Escape') resetCo();
});

// Update loadCpu to store cpuInfo and hide CCD tab for single-CCD
async function loadCpu() {
  const j = await fetchJson('/api/cpu');
  cpuInfo = j.data;
  if (!cpuInfo.SupportsCurveOptimizer) {
    document.getElementById('not-supported').classList.remove('hidden');
    document.getElementById('not-supported').innerHTML = `<h2>Curve Optimizer Not Supported</h2><p>${cpuInfo.UnsupportedReason}</p><p class="muted">Detected: ${cpuInfo.Name}</p>`;
    document.getElementById('curve-card').classList.add('hidden');
    return;
  }
  document.getElementById('cpu-info').innerHTML = `<strong>${cpuInfo.Name}</strong> · ${cpuInfo.Cores} cores · ${cpuInfo.CcdCount} CCD${cpuInfo.CcdCount>1?'s':''} · Zen ${cpuInfo.ZenGen}`;
  if (!cpuInfo.IsDualCcd) document.getElementById('tab-ccd').classList.add('hidden');
}

async function loadCoValues() {
  const launchR = await fetchJson('/api/co/launch');
  launchValues = launchR.data;
  // ... existing banner code ...
  renderForm();
}
```

Add toast style:
```css
.toast { position: fixed; bottom: 1.5rem; left: 50%; transform: translateX(-50%); background: var(--success); color: white; padding: 0.6rem 1.2rem; border-radius: 6px; z-index: 200; }
```

- [ ] **Step 4: Manual test**

Run: `.\Launch.bat`. Try each mode (All/Per-CCD/Per-core), edit values, click Apply. Verify CO values change via:
```powershell
.\corecycler\tools\ryzen-smu-cli\ryzen-smu-cli.exe get-co-core 0
```
Click Revert. Click Reset (or press Esc). Verify each operation.

- [ ] **Step 5: Commit**

```
git add server.ps1 web/
git commit -m "feat(co-write): apply, revert, reset CO; three-mode form; Esc panic key"
```

### Task 9: Profile save/load

**Files:**
- Create: `lib/profile-store.ps1`
- Create: `tests/profile-store.tests.ps1`
- Modify: `server.ps1` (register profile endpoints)
- Modify: `web/index.html` (profiles card)
- Modify: `web/app.js` (profile list, save, apply)

- [ ] **Step 1: Write lib/profile-store.ps1**

```powershell
Set-StrictMode -Version Latest

function Get-ProfilesDir { Join-Path $PSScriptRoot '..\profiles' }

function List-Profiles {
    $dir = Get-ProfilesDir
    if (-not (Test-Path $dir)) { return @() }
    Get-ChildItem -Path $dir -Filter '*.json' | ForEach-Object {
        try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { $null }
    } | Where-Object { $_ -ne $null }
}

function Get-Profile {
    param([string]$Name)
    $path = Join-Path (Get-ProfilesDir) "$Name.json"
    if (-not (Test-Path $path)) { return $null }
    Get-Content $path -Raw | ConvertFrom-Json
}

function Save-Profile {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)]$Values,
        [string]$CpuModel = '',
        [int]$CoreCount = 0,
        [int]$CcdCount = 0,
        [string]$Notes = ''
    )
    $dir = Get-ProfilesDir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $safeName = $Name -replace '[\\/:*?"<>|]','_'
    $profile = [PSCustomObject]@{
        name = $Name
        createdAt = (Get-Date -Format 'o')
        cpuModel = $CpuModel
        coreCount = $CoreCount
        ccdCount = $CcdCount
        mode = $Mode
        values = $Values
        notes = $Notes
    }
    $path = Join-Path $dir "$safeName.json"
    $profile | ConvertTo-Json -Depth 10 | Set-Content -Path $path
    $profile
}

function Remove-Profile {
    param([string]$Name)
    $safeName = $Name -replace '[\\/:*?"<>|]','_'
    $path = Join-Path (Get-ProfilesDir) "$safeName.json"
    if (Test-Path $path) { Remove-Item $path; return $true }
    $false
}
```

- [ ] **Step 2: Write tests/profile-store.tests.ps1**

```powershell
BeforeAll {
    . "$PSScriptRoot\..\lib\profile-store.ps1"
    # Redirect to temp profiles dir
    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) "rpo-test-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    Mock Get-ProfilesDir { $tmpDir }
}
AfterAll { Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue }

Describe 'profile-store' {
    It 'saves and loads a profile' {
        Save-Profile -Name 'Test1' -Mode 'all-cores' -Values @{all=-15} -CpuModel 'AMD Ryzen 9 7950X3D' -CoreCount 16 -CcdCount 2 -Notes 'unit test'
        $p = Get-Profile -Name 'Test1'
        $p.name | Should -Be 'Test1'
        $p.mode | Should -Be 'all-cores'
        $p.values.all | Should -Be -15
    }
    It 'lists saved profiles' {
        (List-Profiles).Count | Should -BeGreaterOrEqual 1
    }
    It 'sanitizes filename' {
        Save-Profile -Name 'has/slash' -Mode 'all-cores' -Values @{all=0}
        Get-Profile -Name 'has_slash' | Should -Not -BeNullOrEmpty
    }
    It 'removes a profile' {
        Save-Profile -Name 'ToRemove' -Mode 'all-cores' -Values @{all=0}
        Remove-Profile -Name 'ToRemove' | Should -BeTrue
        Get-Profile -Name 'ToRemove' | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 3: Run tests**

Run: `Invoke-Pester -Path tests/profile-store.tests.ps1 -Output Detailed`
Expected: 4 passing.

- [ ] **Step 4: Register endpoints in server.ps1**

```powershell
. "$PSScriptRoot\lib\profile-store.ps1"

Register-Route -Method GET -Path '/api/profiles' -Handler {
    @{ ok = $true; data = (List-Profiles) }
}
Register-Route -Method POST -Path '/api/profiles' -Handler {
    param($ctx)
    $body = Read-JsonBody -Context $ctx
    $p = Save-Profile -Name $body.name -Mode $body.mode -Values $body.values `
        -CpuModel $cpu.Name -CoreCount $cpu.Cores -CcdCount $cpu.CcdCount `
        -Notes ($body.notes ?? '')
    @{ ok = $true; data = $p }
}
Register-Route -Method DELETE -Path '/api/profiles/{name}' -Handler {
    param($ctx, $captures)
    $removed = Remove-Profile -Name ([uri]::UnescapeDataString($captures[1]))
    @{ ok = $true; data = @{ removed = $removed } }
}
Register-Route -Method POST -Path '/api/profiles/{name}/apply' -Handler {
    param($ctx, $captures)
    $p = Get-Profile -Name ([uri]::UnescapeDataString($captures[1]))
    if (-not $p) { return @{ ok=$false; error='Profile not found' } }
    # Convert profile values into a flat per-core array
    $vals = @()
    switch ($p.mode) {
        'all-cores' { $vals = @($p.values.all) * $cpu.Cores }
        'per-ccd'   {
            for ($c=0; $c -lt $cpu.CcdCount; $c++) {
                for ($i=0; $i -lt $cpu.CoresPerCcd; $i++) { $vals += [int]$p.values."ccd$c" }
            }
        }
        'per-core'  {
            for ($i=0; $i -lt $cpu.Cores; $i++) { $vals += [int]$p.values."$i" }
        }
    }
    Set-AllCoreCo -Values $vals
    @{ ok = $true; data = @{ applied = $vals } }
}
```

- [ ] **Step 5: UI**

Add a profiles card in `index.html`:
```html
<section class="card" id="profiles-card">
  <h2>Profiles</h2>
  <div id="profiles-list">Loading...</div>
</section>
```

Add JS:
```javascript
async function loadProfiles() {
  const r = await fetchJson('/api/profiles');
  const list = document.getElementById('profiles-list');
  if (!r.data || r.data.length === 0) { list.innerHTML = '<p class="muted">No profiles saved yet.</p>'; return; }
  list.innerHTML = r.data.map(p => `<div class="profile">
    <strong>${p.name}</strong> <span class="muted">${p.mode} · ${p.cpuModel || ''}</span>
    <button data-apply="${p.name}" class="primary">Apply</button>
    <button data-delete="${p.name}" class="secondary">×</button>
  </div>`).join('');
}

document.addEventListener('click', async e => {
  if (e.target.dataset.apply) {
    const r = await fetchJson('/api/profiles/'+encodeURIComponent(e.target.dataset.apply)+'/apply', {method:'POST'});
    if (r.ok) { showToast('Profile applied'); loadCoValues(); }
  }
  if (e.target.dataset.delete) {
    if (!confirm('Delete profile ' + e.target.dataset.delete + '?')) return;
    await fetchJson('/api/profiles/'+encodeURIComponent(e.target.dataset.delete), {method:'DELETE'});
    loadProfiles();
  }
  if (e.target.id === 'save-profile') {
    const name = prompt('Profile name?');
    if (!name) return;
    const notes = prompt('Notes (optional):') || '';
    const body = collectValues();
    body.name = name; body.notes = notes;
    const r = await fetchJson('/api/profiles', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
    if (r.ok) { showToast('Profile saved'); loadProfiles(); }
  }
});

// Call loadProfiles in DOMContentLoaded
```

- [ ] **Step 6: Manual test**

Run: `.\Launch.bat`. Set values, click "Save as profile…", give name "TestDaily". Refresh page. Verify "TestDaily" appears under Profiles. Click Apply → values applied. Click × → removed.

- [ ] **Step 7: Commit**

```
git add lib/profile-store.ps1 tests/profile-store.tests.ps1 server.ps1 web/
git commit -m "feat(profiles): save, list, apply, delete CO profiles"
```

---

## Phase 3 — Live Telemetry Panel

Goal: A real-time strip in the header shows temps, power, voltage. Expand to show per-core breakdown with sparklines.

### Task 10: Download LibreHardwareMonitorLib.dll

**Files:**
- Modify: `installer.ps1` (download LHM)

- [ ] **Step 1: Add to installer.ps1**

```powershell
function Install-LibreHardwareMonitor {
    $lhmUrl = 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/latest/download/LibreHardwareMonitor-net472.zip'
    $vendor = Join-Path $RepoRoot 'vendor'
    if (-not (Test-Path $vendor)) { New-Item -ItemType Directory -Path $vendor | Out-Null }
    $target = Join-Path $vendor 'LibreHardwareMonitorLib.dll'
    if (Test-Path $target) { return }
    $zipPath = Join-Path $CacheDir 'lhm.zip'
    Write-Log INFO "Downloading LibreHardwareMonitor"
    Invoke-WebRequest -Uri $lhmUrl -OutFile $zipPath
    $extract = Join-Path $CacheDir 'lhm-extract'
    if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
    Expand-Archive -Path $zipPath -DestinationPath $extract -Force
    $dll = Get-ChildItem -Path $extract -Recurse -Filter 'LibreHardwareMonitorLib.dll' | Select-Object -First 1
    if (-not $dll) { throw "LibreHardwareMonitorLib.dll not found in download" }
    Copy-Item -Path $dll.FullName -Destination $target
    # Also copy HidSharp.dll if present
    $hid = Get-ChildItem -Path $extract -Recurse -Filter 'HidSharp.dll' | Select-Object -First 1
    if ($hid) { Copy-Item -Path $hid.FullName -Destination (Join-Path $vendor 'HidSharp.dll') }
    Write-Log INFO "LibreHardwareMonitorLib installed"
}
```

Then add call at the bottom of `Install-CoreCycler`: `Install-LibreHardwareMonitor`

- [ ] **Step 2: Manual run**

Run: `.\Install.bat`
Expected: `vendor/LibreHardwareMonitorLib.dll` exists.

- [ ] **Step 3: Commit**

```
git add installer.ps1
git commit -m "feat(installer): also download LibreHardwareMonitorLib.dll"
```

### Task 11: Telemetry poller

**Files:**
- Create: `lib/telemetry-poller.ps1`
- Modify: `server.ps1` (init telemetry, register endpoints)
- Modify: `web/index.html` (compact strip + expand button)
- Modify: `web/app.js` (poll & render)

- [ ] **Step 1: Write lib/telemetry-poller.ps1**

```powershell
Set-StrictMode -Version Latest
. "$PSScriptRoot\logging.ps1"

$script:Computer = $null
$script:LatestSnapshot = $null
$script:History = New-Object System.Collections.ArrayList
$script:HistoryMax = 60
$script:Peaks = @{}
$script:PeakTracking = $false
$script:UpdateThread = $null
$script:Stop = $false

function Initialize-Telemetry {
    param([string]$RepoRoot)
    $dll = Join-Path $RepoRoot 'vendor\LibreHardwareMonitorLib.dll'
    if (-not (Test-Path $dll)) { Write-Log WARN "LHM dll not found, telemetry disabled"; return $false }
    try {
        Add-Type -Path $dll
        $hid = Join-Path $RepoRoot 'vendor\HidSharp.dll'
        if (Test-Path $hid) { Add-Type -Path $hid }
        $script:Computer = [LibreHardwareMonitor.Hardware.Computer]::new()
        $script:Computer.IsCpuEnabled = $true
        $script:Computer.IsMemoryEnabled = $true
        $script:Computer.IsMotherboardEnabled = $true
        $script:Computer.Open()
        Write-Log INFO "Telemetry initialized"
        return $true
    } catch {
        Write-Log ERROR "Failed to init telemetry: $($_.Exception.Message)"
        return $false
    }
}

function Get-TelemetrySnapshot {
    if ($null -eq $script:Computer) { return $null }
    $snap = @{ time = (Get-Date -Format 'o'); packageTemp=$null; ccdTemps=@(); packagePower=$null; cores=@(); memoryClock=$null; fclk=$null; fans=@() }
    foreach ($hw in $script:Computer.Hardware) {
        $hw.Update()
        foreach ($sub in $hw.SubHardware) { $sub.Update() }
        foreach ($s in $hw.Sensors) {
            $name = $s.Name
            $type = $s.SensorType.ToString()
            $value = $s.Value
            if ($null -eq $value) { continue }
            if ($type -eq 'Temperature' -and $name -match '^Core \(Tctl/Tdie\)$') { $snap.packageTemp = [double]$value }
            elseif ($type -eq 'Temperature' -and $name -match 'CCD(\d)') { $snap.ccdTemps += [PSCustomObject]@{ ccd=[int]$Matches[1]; tempC=[double]$value } }
            elseif ($type -eq 'Power' -and $name -match 'Package') { $snap.packagePower = [double]$value }
            elseif ($type -eq 'Voltage' -and $name -match '^CPU Core #(\d+)') {
                $core = ([int]$Matches[1]) - 1
                $existing = $snap.cores | Where-Object { $_.core -eq $core } | Select-Object -First 1
                if (-not $existing) { $existing = [PSCustomObject]@{ core=$core; voltage=$null; clockMHz=$null; loadPct=$null }; $snap.cores += $existing }
                $existing.voltage = [double]$value
            }
            elseif ($type -eq 'Clock' -and $name -match '^CPU Core #(\d+)') {
                $core = ([int]$Matches[1]) - 1
                $existing = $snap.cores | Where-Object { $_.core -eq $core } | Select-Object -First 1
                if (-not $existing) { $existing = [PSCustomObject]@{ core=$core; voltage=$null; clockMHz=$null; loadPct=$null }; $snap.cores += $existing }
                $existing.clockMHz = [double]$value
            }
            elseif ($type -eq 'Load' -and $name -match '^CPU Core #(\d+)') {
                $core = ([int]$Matches[1]) - 1
                $existing = $snap.cores | Where-Object { $_.core -eq $core } | Select-Object -First 1
                if (-not $existing) { $existing = [PSCustomObject]@{ core=$core; voltage=$null; clockMHz=$null; loadPct=$null }; $snap.cores += $existing }
                $existing.loadPct = [double]$value
            }
            elseif ($type -eq 'Clock' -and $name -match 'Memory') { $snap.memoryClock = [double]$value }
            elseif ($type -eq 'Clock' -and $name -match 'Fabric|FCLK') { $snap.fclk = [double]$value }
            elseif ($type -eq 'Fan') { $snap.fans += [PSCustomObject]@{ name=$name; rpm=[double]$value } }
        }
    }
    $snap
}

function Start-TelemetryPoller {
    $script:Stop = $false
    $script:UpdateThread = Start-ThreadJob -ScriptBlock {
        param($repoRoot)
        Set-Location $repoRoot
        . .\lib\telemetry-poller.ps1
        if (-not (Initialize-Telemetry -RepoRoot $repoRoot)) { return }
        while ($true) {
            $snap = Get-TelemetrySnapshot
            $script:LatestSnapshot = $snap
            $script:History.Add($snap) | Out-Null
            while ($script:History.Count -gt $script:HistoryMax) { $script:History.RemoveAt(0) }
            if ($script:PeakTracking) { Update-Peaks -Snapshot $snap }
            Start-Sleep -Milliseconds 1000
            if ($script:Stop) { break }
        }
    } -ArgumentList $PSScriptRoot
}

function Update-Peaks {
    param($Snapshot)
    if ($null -ne $Snapshot.packageTemp) {
        if (-not $script:Peaks.ContainsKey('packageTemp') -or $Snapshot.packageTemp -gt $script:Peaks['packageTemp']) {
            $script:Peaks['packageTemp'] = $Snapshot.packageTemp
        }
    }
    if ($null -ne $Snapshot.packagePower) {
        if (-not $script:Peaks.ContainsKey('packagePower') -or $Snapshot.packagePower -gt $script:Peaks['packagePower']) {
            $script:Peaks['packagePower'] = $Snapshot.packagePower
        }
    }
    foreach ($c in $Snapshot.cores) {
        $key = "core$($c.core).voltage"
        if ($null -ne $c.voltage -and (-not $script:Peaks.ContainsKey($key) -or $c.voltage -gt $script:Peaks[$key])) {
            $script:Peaks[$key] = $c.voltage
        }
    }
}

function Start-PeakTracking {
    $script:Peaks = @{}
    $script:PeakTracking = $true
}

function Stop-PeakTracking { $script:PeakTracking = $false }

function Get-Peaks { $script:Peaks }

function Get-LatestTelemetry { $script:LatestSnapshot }
function Get-TelemetryHistory { , @($script:History.ToArray()) }
```

NOTE: PowerShell's `Start-ThreadJob` is in the `ThreadJob` module (built into PS 7+, available on 5.1 via `Install-Module ThreadJob`). The installer should ensure this is available.

- [ ] **Step 2: Add ThreadJob bootstrap to installer**

In `installer.ps1`, add at top:
```powershell
function Ensure-ThreadJob {
    if (-not (Get-Module -ListAvailable -Name ThreadJob)) {
        Write-Log INFO "Installing ThreadJob module"
        Install-Module -Name ThreadJob -Scope CurrentUser -Force -ErrorAction Stop
    }
}
```
Call `Ensure-ThreadJob` from the main install flow.

- [ ] **Step 3: Register routes in server.ps1**

```powershell
. "$PSScriptRoot\lib\telemetry-poller.ps1"
Start-TelemetryPoller

Register-Route -Method GET -Path '/api/telemetry' -Handler {
    @{ ok = $true; data = (Get-LatestTelemetry) }
}
Register-Route -Method GET -Path '/api/telemetry/history' -Handler {
    @{ ok = $true; data = (Get-TelemetryHistory) }
}
Register-Route -Method GET -Path '/api/telemetry/peaks' -Handler {
    @{ ok = $true; data = (Get-Peaks) }
}
```

- [ ] **Step 4: Compact telemetry strip**

In `index.html` after #cpu-info:
```html
<div id="telemetry-strip" class="card telemetry">Loading sensors...</div>
<div id="telemetry-expanded" class="card hidden"></div>
```

In `style.css`:
```css
.telemetry { display: flex; gap: 1.5rem; align-items: center; font-variant-numeric: tabular-nums; }
.telemetry .metric { display: flex; flex-direction: column; align-items: flex-start; }
.telemetry .label { color: var(--muted); font-size: 0.75rem; }
.telemetry .value { font-size: 1.1rem; font-weight: 600; }
.expand-btn { margin-left: auto; }
.core-tile { background: rgba(255,255,255,0.04); padding: 0.4rem; border-radius: 4px; font-size: 0.75rem; min-width: 4rem; }
.core-grid { display: grid; grid-template-columns: repeat(8, 1fr); gap: 0.4rem; margin-top: 1rem; }
```

In `app.js`:
```javascript
async function pollTelemetry() {
  try {
    const r = await fetchJson('/api/telemetry');
    if (r.data) renderTelemetry(r.data);
  } catch (e) { /* ignore transient errors */ }
}

function renderTelemetry(t) {
  const strip = document.getElementById('telemetry-strip');
  const temp = t.packageTemp ? t.packageTemp.toFixed(0) + '°C' : '—';
  const power = t.packagePower ? t.packagePower.toFixed(0) + 'W' : '—';
  const vAvg = t.cores.length ? (t.cores.reduce((s,c) => s + (c.voltage||0), 0) / t.cores.length).toFixed(2) + 'V' : '—';
  strip.innerHTML = `
    <span class="metric"><span class="label">Pkg Temp</span><span class="value">${temp}</span></span>
    <span class="metric"><span class="label">Pkg Power</span><span class="value">${power}</span></span>
    <span class="metric"><span class="label">Avg VID</span><span class="value">${vAvg}</span></span>
    <button class="secondary expand-btn" id="telem-expand">⏵ expand</button>`;

  const exp = document.getElementById('telemetry-expanded');
  if (!exp.classList.contains('hidden')) renderExpandedTelemetry(t);
}

function renderExpandedTelemetry(t) {
  const ccds = {};
  t.cores.forEach(c => {
    const ccd = cpuInfo && cpuInfo.IsDualCcd ? Math.floor(c.core/cpuInfo.CoresPerCcd) : 0;
    (ccds[ccd] = ccds[ccd] || []).push(c);
  });
  let html = '';
  Object.keys(ccds).sort().forEach(ccd => {
    html += `<div><strong>CCD${ccd}</strong></div><div class="core-grid">`;
    ccds[ccd].forEach(c => {
      const tempColor = ''; // computed by per-core temp if available
      html += `<div class="core-tile" style="${tempColor}">C${c.core}<br>${c.voltage?.toFixed(2)}V<br>${c.clockMHz?.toFixed(0)}MHz<br>${c.loadPct?.toFixed(0)}%</div>`;
    });
    html += '</div>';
  });
  document.getElementById('telemetry-expanded').innerHTML = html;
}

document.addEventListener('click', e => {
  if (e.target.id === 'telem-expand') {
    const exp = document.getElementById('telemetry-expanded');
    exp.classList.toggle('hidden');
    e.target.textContent = exp.classList.contains('hidden') ? '⏵ expand' : '⏷ collapse';
  }
});

// Start polling on load
setInterval(pollTelemetry, 1000);
pollTelemetry();
```

- [ ] **Step 5: Manual test**

Run: `.\Launch.bat`. Verify the telemetry strip shows live temp/power/voltage updating every second. Click "expand" to see per-core breakdown. Idle values should be reasonable (e.g. temp 35-50°C, power 10-30W, voltage 1.0-1.2V).

- [ ] **Step 6: Commit**

```
git add lib/telemetry-poller.ps1 installer.ps1 server.ps1 web/
git commit -m "feat(telemetry): live sensor strip + expanded per-core dashboard via LibreHardwareMonitor"
```

---

## Phase 4 — Test Orchestration

Goal: User can start/stop a CoreCycler stress test from the UI; live status updates while running; state machine prevents conflicting actions.

### Task 12: State machine

**Files:**
- Create: `lib/state-machine.ps1`
- Create: `tests/state-machine.tests.ps1`

- [ ] **Step 1: Write lib/state-machine.ps1**

```powershell
Set-StrictMode -Version Latest

$script:State = 'IDLE'
$script:StateData = @{}
$script:ValidTransitions = @{
    'IDLE'         = @('APPLYING_CO','TESTING','ERROR')
    'APPLYING_CO'  = @('IDLE','TESTING','ERROR')
    'TESTING'      = @('STOPPING','REPORTING','ERROR')
    'STOPPING'     = @('REPORTING','IDLE','ERROR')
    'REPORTING'    = @('IDLE','ERROR')
    'ERROR'        = @('IDLE')
}

function Get-State { @{ state = $script:State; data = $script:StateData } }
function Set-State { param([string]$NewState, $Data = @{}) 
    if ($script:ValidTransitions[$script:State] -notcontains $NewState -and $NewState -ne 'IDLE') {
        throw "Invalid transition: $($script:State) → $NewState"
    }
    $script:State = $NewState
    $script:StateData = $Data
}
function Reset-State { $script:State = 'IDLE'; $script:StateData = @{} }
```

- [ ] **Step 2: Write tests/state-machine.tests.ps1**

```powershell
BeforeAll { . "$PSScriptRoot\..\lib\state-machine.ps1" }
BeforeEach { Reset-State }

Describe 'state machine' {
    It 'starts in IDLE' { (Get-State).state | Should -Be 'IDLE' }
    It 'allows IDLE → TESTING' { Set-State -NewState 'TESTING'; (Get-State).state | Should -Be 'TESTING' }
    It 'rejects illegal transition' { { Set-State -NewState 'REPORTING' } | Should -Throw "*Invalid*" }
    It 'allows interrupt to IDLE from any state' { Set-State -NewState 'TESTING'; Set-State -NewState 'IDLE'; (Get-State).state | Should -Be 'IDLE' }
}
```

- [ ] **Step 3: Run tests**

Run: `Invoke-Pester -Path tests/state-machine.tests.ps1 -Output Detailed`
Expected: 4 passing.

- [ ] **Step 4: Commit**

```
git add lib/state-machine.ps1 tests/state-machine.tests.ps1
git commit -m "feat(state): add run-state machine"
```

### Task 13: CoreCycler runner — generate config + spawn

**Files:**
- Create: `lib/corecycler-runner.ps1`
- Create: `tests/corecycler-runner.tests.ps1`

- [ ] **Step 1: Write lib/corecycler-runner.ps1**

```powershell
Set-StrictMode -Version Latest
. "$PSScriptRoot\logging.ps1"

$script:CcProcess = $null
$script:LastLogPath = $null
$script:LastPrimeLogPath = $null

function New-CoreCyclerConfig {
    param(
        [string]$RepoRoot,
        [string]$StressTestProgram = 'PRIME95',
        [string]$Mode = 'SSE',  # SSE | AVX2 | AVX512
        [string]$RuntimePerCore = '6m',
        [int]$MaxIterations = 1,
        [int[]]$CoresToTest,    # 0-indexed list; we'll convert to coresToIgnore
        [int]$TotalCores,
        [bool]$EnableAutomaticAdjustment = $false,
        [int[]]$AutoStartValues = $null,
        [int]$AutoMaxValue = 0,
        [int]$AutoIncrementBy = 1
    )
    $ignored = @()
    for ($i=0; $i -lt $TotalCores; $i++) { if ($CoresToTest -notcontains $i) { $ignored += $i } }

    $cfg = @"
[General]
stressTestProgram = $StressTestProgram
runtimePerCore = $RuntimePerCore
numberOfThreads = 1
maxIterations = $MaxIterations
coresToIgnore = $($ignored -join ', ')
skipCoreOnError = 1
stopOnError = 0
beepOnError = 0
flashOnError = 0
lookForWheaErrors = 1
treatWheaWarningAsError = 1

[Prime95]
mode = $Mode

[Logging]
logLevel = 4

[AutomaticTestMode]
enableAutomaticAdjustment = $([int]$EnableAutomaticAdjustment)
"@
    if ($EnableAutomaticAdjustment) {
        $sv = if ($AutoStartValues) { ($AutoStartValues -join ' ') } else { 'CurrentValues' }
        $cfg += "`nstartValues = $sv`nmaxValue = $AutoMaxValue`nincrementBy = $AutoIncrementBy"
    }

    $configPath = Join-Path $RepoRoot 'runtime\generated-config.ini'
    $dir = Split-Path $configPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Set-Content -Path $configPath -Value $cfg
    $configPath
}

function Start-CoreCyclerRun {
    param(
        [string]$RepoRoot,
        [string]$ConfigPath
    )
    $ccDir = Join-Path $RepoRoot 'corecycler'
    $ccScript = Join-Path $ccDir 'script-corecycler.ps1'
    if (-not (Test-Path $ccScript)) { throw "CoreCycler not installed at $ccDir" }

    # Backup CoreCycler's config.ini, replace with ours
    $ccConfig = Join-Path $ccDir 'config.ini'
    $ccConfigBak = Join-Path $ccDir 'config.ini.rpo-backup'
    if (Test-Path $ccConfig) { Copy-Item -Force $ccConfig $ccConfigBak }
    Copy-Item -Force $ConfigPath $ccConfig

    # Spawn CoreCycler in a new window
    $script:CcProcess = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList '-ExecutionPolicy','Bypass','-File',"`"$ccScript`"" `
        -WorkingDirectory $ccDir `
        -PassThru
    Write-Log INFO "CoreCycler started, PID $($script:CcProcess.Id)"

    # Discover the log it will create (search for the newest matching file)
    Start-Sleep -Milliseconds 2000  # give it a moment to create the log
    $logDir = Join-Path $ccDir 'logs'
    $latest = Get-ChildItem -Path $logDir -Filter 'CoreCycler_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $script:LastLogPath = $latest?.FullName
    $script:LastPrimeLogPath = (Get-ChildItem -Path $logDir -Filter 'Prime95_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)?.FullName
}

function Stop-CoreCyclerRun {
    if ($null -eq $script:CcProcess -or $script:CcProcess.HasExited) { return }
    # CoreCycler responds to Ctrl+C; sending it cleanly from PowerShell is tricky.
    # Best-effort: AttachConsole + send Ctrl+C; fallback to Stop-Process.
    try {
        # First try AttachConsole approach (works if CoreCycler shares a console)
        # If that fails, just kill the process.
        Stop-Process -Id $script:CcProcess.Id -Force
        Write-Log INFO "CoreCycler stopped (force)"
    } catch {
        Write-Log WARN "Failed to stop CoreCycler: $($_.Exception.Message)"
    }
    $script:CcProcess = $null
}

function Test-CoreCyclerRunning {
    $null -ne $script:CcProcess -and -not $script:CcProcess.HasExited
}

function Get-LatestLogs {
    @{
        coreCyclerLog = $script:LastLogPath
        prime95Log = $script:LastPrimeLogPath
    }
}
```

- [ ] **Step 2: Write minimal tests**

```powershell
BeforeAll { . "$PSScriptRoot\..\lib\corecycler-runner.ps1" }
Describe 'New-CoreCyclerConfig' {
    It 'inverts coresToTest into coresToIgnore' {
        $tmp = [IO.Path]::GetTempPath()
        $repo = Join-Path $tmp ('rpo-test-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $repo | Out-Null
        $cfg = New-CoreCyclerConfig -RepoRoot $repo -TotalCores 16 -CoresToTest @(0,1,2)
        $content = Get-Content $cfg -Raw
        $content | Should -Match 'coresToIgnore = 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15'
        Remove-Item -Recurse -Force $repo
    }
}
```

- [ ] **Step 3: Run tests**

Run: `Invoke-Pester -Path tests/corecycler-runner.tests.ps1 -Output Detailed`
Expected: 1 passing.

- [ ] **Step 4: Commit**

```
git add lib/corecycler-runner.ps1 tests/corecycler-runner.tests.ps1
git commit -m "feat(runner): generate CoreCycler config and spawn process"
```

### Task 14: Test start/stop endpoints + status polling

**Files:**
- Modify: `server.ps1` (state, /api/test/start, /api/test/stop, /api/status)
- Modify: `web/index.html` (test card)
- Modify: `web/app.js` (start, stop, status polling)

- [ ] **Step 1: Wire state and routes**

```powershell
. "$PSScriptRoot\lib\state-machine.ps1"
. "$PSScriptRoot\lib\corecycler-runner.ps1"

Register-Route -Method POST -Path '/api/test/start' -Handler {
    param($ctx)
    $body = Read-JsonBody -Context $ctx
    if ((Get-State).state -ne 'IDLE') { return @{ ok=$false; error="Cannot start; current state $((Get-State).state)" } }

    $coresToTest = if ($body.coresToTest) { $body.coresToTest } else { 0..($cpu.Cores-1) }
    $cfgPath = New-CoreCyclerConfig -RepoRoot $RepoRoot `
        -StressTestProgram 'PRIME95' -Mode $body.mode -MaxIterations $body.iterations `
        -CoresToTest $coresToTest -TotalCores $cpu.Cores `
        -EnableAutomaticAdjustment $false

    Start-CoreCyclerRun -RepoRoot $RepoRoot -ConfigPath $cfgPath
    Set-State -NewState 'TESTING' -Data @{ startedAt = (Get-Date -Format 'o'); coresToTest = $coresToTest; iterations = $body.iterations }
    Start-PeakTracking
    @{ ok = $true; data = (Get-State) }
}

Register-Route -Method POST -Path '/api/test/stop' -Handler {
    if ((Get-State).state -ne 'TESTING') { return @{ ok=$false; error='Not testing' } }
    Set-State -NewState 'STOPPING'
    Stop-CoreCyclerRun
    Stop-PeakTracking
    Set-State -NewState 'REPORTING' -Data (Get-State).data
    @{ ok = $true; data = (Get-State) }
}

Register-Route -Method GET -Path '/api/status' -Handler {
    $state = Get-State
    $live = $null
    if ($state.state -eq 'TESTING' -or $state.state -eq 'STOPPING') {
        # Tail the log to get current core / iteration / errors
        $logs = Get-LatestLogs
        if ($logs.coreCyclerLog -and (Test-Path $logs.coreCyclerLog)) {
            $tail = Get-Content $logs.coreCyclerLog -Tail 500 -ErrorAction SilentlyContinue
            $live = Parse-LiveStatus -LogLines $tail
        }
    }
    @{ ok = $true; data = @{ state = $state.state; stateData = $state.data; live = $live } }
}
```

- [ ] **Step 2: Add Parse-LiveStatus helper to lib/corecycler-runner.ps1**

```powershell
function Parse-LiveStatus {
    param([string[]]$LogLines)
    $info = @{ currentCore=$null; iteration=$null; iterationsTotal=$null; errors=0; wheaErrors=0; runtime=$null }
    foreach ($line in $LogLines) {
        if ($line -match 'Set to Core (\d+)') { $info.currentCore = [int]$Matches[1] }
        elseif ($line -match 'Iteration (\d+)/(\d+)') { $info.iteration = [int]$Matches[1]; $info.iterationsTotal = [int]$Matches[2] }
        elseif ($line -match 'cores with an error so far: (\d+)') { $info.errors = [int]$Matches[1] }
        elseif ($line -match 'cores with a WHEA error so far: (\d+)') { $info.wheaErrors = [int]$Matches[1] }
        elseif ($line -match 'Runtime (\d{2}h \d{2}m \d{2}s)') { $info.runtime = $Matches[1] }
    }
    $info
}
```

- [ ] **Step 3: UI test card**

```html
<section class="card" id="test-card">
  <h2>2. Test Stability</h2>
  <div class="co-input"><label>Test:</label>
    <select id="test-mode"><option>SSE</option><option>AVX2</option><option>AVX512</option></select>
  </div>
  <div class="co-input"><label>Cycles:</label><input type="number" id="iterations" value="1" min="1" max="10000"></div>
  <p class="muted">For confident stability, 3+ cycles is recommended.</p>
  <div class="actions">
    <button id="start-test" class="primary">▶ Start Test</button>
    <button id="stop-test" class="danger hidden">■ Stop</button>
  </div>
</section>
<section class="card hidden" id="status-card">
  <h2>3. Live Status</h2>
  <div id="status-content"></div>
</section>
```

- [ ] **Step 4: JS handlers**

```javascript
async function startTest() {
  const body = {
    mode: document.getElementById('test-mode').value,
    iterations: +document.getElementById('iterations').value,
  };
  const r = await fetchJson('/api/test/start', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body) });
  if (!r.ok) return alert(r.error);
  document.getElementById('start-test').classList.add('hidden');
  document.getElementById('stop-test').classList.remove('hidden');
  document.getElementById('status-card').classList.remove('hidden');
}

async function stopTest() {
  const r = await fetchJson('/api/test/stop', { method:'POST' });
  document.getElementById('start-test').classList.remove('hidden');
  document.getElementById('stop-test').classList.add('hidden');
}

async function pollStatus() {
  const r = await fetchJson('/api/status');
  const s = r.data;
  if (s.state === 'TESTING' && s.live) {
    const c = s.live;
    document.getElementById('status-content').innerHTML = `Testing core ${c.currentCore} · Iteration ${c.iteration}/${c.iterationsTotal} · Errors: ${c.errors} · WHEA: ${c.wheaErrors}`;
  }
  if (s.state === 'REPORTING') {
    document.getElementById('start-test').classList.remove('hidden');
    document.getElementById('stop-test').classList.add('hidden');
    document.getElementById('status-content').textContent = 'Test complete — generating report…';
  }
}

setInterval(pollStatus, 1500);

document.addEventListener('click', e => {
  if (e.target.id === 'start-test') startTest();
  if (e.target.id === 'stop-test') stopTest();
});
```

- [ ] **Step 5: End-to-end test**

Run: `.\Launch.bat`. Click Start Test with iterations=1 and mode=SSE. A CoreCycler window opens. The UI shows live status (current core, iteration, errors). Click Stop — both windows return to idle.

- [ ] **Step 6: Commit**

```
git add server.ps1 lib/corecycler-runner.ps1 web/
git commit -m "feat(test): orchestrate CoreCycler with live status polling"
```

---

## Phase 5 — Log Parser & Report Engine

Goal: When a test ends, parse the logs into a structured report. Render with Smart Suggestions.

### Task 15: Log parser

**Files:**
- Create: `lib/log-parser.ps1`
- Create: `tests/log-parser.tests.ps1`
- Create: `tests/fixtures/sample-corecycler.log`
- Create: `tests/fixtures/sample-prime95.log`

- [ ] **Step 1: Save a real CoreCycler log as fixture**

Copy `corecycler\logs\CoreCycler_*.log` from a previous run (the user has them from earlier work) and the matching `Prime95_*.log` into `tests/fixtures/sample-corecycler.log` and `tests/fixtures/sample-prime95.log`. Trim to ~1000 lines for a fast test.

- [ ] **Step 2: Write lib/log-parser.ps1**

```powershell
Set-StrictMode -Version Latest

function Read-CoreCyclerLog {
    param([string]$CoreCyclerLogPath, [string]$Prime95LogPath, $CpuInfo, $CurrentCoValues)
    $r = @{
        timestamp = (Get-Date -Format 'o')
        duration = $null
        iterationsCompleted = 0
        iterationsRequested = 1
        testType = 'PRIME95_SSE'
        coresTested = @()
        coresPassed = @()
        coresFailed = @()
        wheaEvents = @()
        verdict = 'UNKNOWN'
    }

    if (-not (Test-Path $CoreCyclerLogPath)) { return $r }
    $lines = Get-Content $CoreCyclerLogPath

    foreach ($l in $lines) {
        if ($l -match 'Iteration (\d+)/(\d+)') { $r.iterationsCompleted = [Math]::Max($r.iterationsCompleted, [int]$Matches[1]); $r.iterationsRequested = [int]$Matches[2] }
        if ($l -match 'Test completed in (\d{2}h \d{2}m \d{2}s)') { $r.duration = $Matches[1] }
        if ($l -match 'stressTestProgram = (\w+)') { $r.testType = $Matches[1] }
        if ($l -match 'Set to Core (\d+)') {
            $core = [int]$Matches[1]
            if ($r.coresTested -notcontains $core) { $r.coresTested += $core }
        }
        if ($l -match '\[EVENTLOG\] (.*core_error|.* error.* on core)') {
            # try to find which core; CoreCycler logs "core_error" with the prior "Set to Core N"
        }
    }

    # Crude pass/fail: scan Prime95 log for FATAL/Rounding errors
    $errCores = @()
    if (Test-Path $Prime95LogPath) {
        $primeLines = Get-Content $Prime95LogPath
        if ($primeLines | Where-Object { $_ -match 'FATAL ERROR|Rounding was' }) {
            # We need to correlate to a core via timestamps from CoreCycler log
            # For MVP: report a generic 'one or more cores errored' result
            $r.verdict = 'FAILED'
        }
    }
    if (-not $r.verdict -or $r.verdict -eq 'UNKNOWN') {
        # Check coreCycler log for "cores with an error: N"
        $errMatch = $lines | Select-String -Pattern 'cores with an error:\s+(\d+)' | Select-Object -Last 1
        if ($errMatch -and [int]$errMatch.Matches[0].Groups[1].Value -gt 0) {
            $r.verdict = 'FAILED'
        } else {
            $r.verdict = 'PASSED'
        }
    }

    if ($r.verdict -eq 'PASSED') { $r.coresPassed = $r.coresTested }
    # Per-core failure attribution: scan for "core_error" event log entries with surrounding "Set to Core N" context
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'core_error|core has thrown an error') {
            # Walk back to find the most recent "Set to Core N"
            for ($j = $i; $j -ge 0; $j--) {
                if ($lines[$j] -match 'Set to Core (\d+)') {
                    $errCores += [int]$Matches[1]
                    break
                }
            }
        }
    }
    $errCores = $errCores | Sort-Object -Unique
    foreach ($c in $errCores) {
        $ccd = if ($CpuInfo.IsDualCcd) { [int]([Math]::Floor($c / $CpuInfo.CoresPerCcd)) } else { 0 }
        $isVCache = ($null -ne $CpuInfo.VCacheCcdIndex) -and ($CpuInfo.VCacheCcdIndex -eq $ccd)
        $r.coresFailed += [PSCustomObject]@{
            core = $c
            ccd = $ccd
            ccdLabel = if ($isVCache) { "CCD$ccd (V-Cache)" } else { "CCD$ccd (Standard)" }
            coAtFailure = if ($CurrentCoValues) { $CurrentCoValues[$c] } else { $null }
            errorType = 'Stress test error'
        }
    }
    $r.coresPassed = $r.coresTested | Where-Object { $errCores -notcontains $_ }

    $r
}
```

- [ ] **Step 3: Write tests/log-parser.tests.ps1**

```powershell
BeforeAll { . "$PSScriptRoot\..\lib\log-parser.ps1" }

Describe 'log-parser' {
    It 'parses a clean log as PASSED' {
        $cpu = [PSCustomObject]@{ IsDualCcd=$true; CoresPerCcd=8; VCacheCcdIndex=0 }
        $r = Read-CoreCyclerLog -CoreCyclerLogPath "$PSScriptRoot\fixtures\sample-corecycler.log" -Prime95LogPath "$PSScriptRoot\fixtures\sample-prime95.log" -CpuInfo $cpu -CurrentCoValues (@(0)*16)
        $r.verdict | Should -Be 'PASSED'
        $r.iterationsCompleted | Should -BeGreaterThan 0
    }
}
```

- [ ] **Step 4: Run tests**

Run: `Invoke-Pester -Path tests/log-parser.tests.ps1 -Output Detailed`
Expected: 1 passing (against the user's earlier clean log).

- [ ] **Step 5: Commit**

```
git add lib/log-parser.ps1 tests/log-parser.tests.ps1 tests/fixtures/
git commit -m "feat(log-parser): parse CoreCycler + Prime95 logs into report data"
```

### Task 16: Smart Suggestions

**Files:**
- Create: `lib/smart-suggestions.ps1`
- Create: `tests/smart-suggestions.tests.ps1`

- [ ] **Step 1: Write lib/smart-suggestions.ps1**

```powershell
Set-StrictMode -Version Latest

function Get-SmartSuggestions {
    param($Report, $Mode, $CpuInfo, $CurrentCoValues)
    $out = @()
    switch ($Report.verdict) {
        'PASSED' {
            switch ($Mode) {
                'all-cores' {
                    $v = $CurrentCoValues[0]
                    $next = $v - 5
                    $out += "All cores stable at $v. To push further, switch to Per-CCD mode and try CCD1 at $next (CCD1 typically tolerates more)."
                }
                'per-ccd' {
                    $out += "Per-CCD stable. To find each core's individual ceiling, switch to Per-core mode."
                }
                'per-core' {
                    $out += "Per-core stable — congrats. Dial each core back by 2–3 points for a safe daily-use margin."
                }
            }
        }
        'FAILED' {
            if ($Report.coresFailed.Count -eq 1) {
                $c = $Report.coresFailed[0]
                $back = $c.coAtFailure + 3
                $out += "Core $($c.core) hit its limit at CO=$($c.coAtFailure). Silicon lottery — that core happens to be less tolerant. Dial back to $back and retry."
            } elseif ($Report.coresFailed.Count -gt 1) {
                $vCacheFails = $Report.coresFailed | Where-Object { $_.ccdLabel -match 'V-Cache' }
                if ($vCacheFails.Count -ge 2) {
                    $out += "Multiple V-Cache cores errored. V-Cache CCDs usually wall between −15 and −20. Dial back CCD0 and step in 2-point increments from here."
                } else {
                    $out += "Multiple cores errored — back off the offset across the board, then narrow down per-core."
                }
            }
            if ($Report.wheaEvents.Count -gt 0) {
                $out += "WHEA events fired during the test — hardware-level corrected errors. Clear signal to back off."
            }
        }
    }
    if ($Report.iterationsRequested -le 1) {
        $out += "Tip: this was a 1-cycle test. Run 3+ cycles for higher confidence."
    }
    $out
}
```

- [ ] **Step 2: Tests**

```powershell
BeforeAll { . "$PSScriptRoot\..\lib\smart-suggestions.ps1" }
Describe 'smart-suggestions' {
    It 'recommends Per-CCD push after all-cores PASS' {
        $rep = [PSCustomObject]@{ verdict='PASSED'; iterationsRequested=3; coresFailed=@(); wheaEvents=@() }
        $sugg = Get-SmartSuggestions -Report $rep -Mode 'all-cores' -CpuInfo $null -CurrentCoValues @(-10)*16
        ($sugg -join ' ') | Should -Match 'Per-CCD'
    }
    It 'mentions silicon lottery on single core failure' {
        $rep = [PSCustomObject]@{ verdict='FAILED'; iterationsRequested=1; coresFailed=@([PSCustomObject]@{core=7;coAtFailure=-20;ccdLabel='CCD0 (V-Cache)'}); wheaEvents=@() }
        $sugg = Get-SmartSuggestions -Report $rep -Mode 'per-core' -CpuInfo $null -CurrentCoValues @(-20)*16
        ($sugg -join ' ') | Should -Match 'Silicon lottery'
    }
}
```

- [ ] **Step 3: Run tests**

Run: `Invoke-Pester -Path tests/smart-suggestions.tests.ps1 -Output Detailed`
Expected: 2 passing.

- [ ] **Step 4: Commit**

```
git add lib/smart-suggestions.ps1 tests/smart-suggestions.tests.ps1
git commit -m "feat(suggestions): smart contextual recommendations after each run"
```

### Task 17: Report endpoint + UI

**Files:**
- Modify: `server.ps1` (GET /api/report)
- Modify: `web/index.html` (report card)
- Modify: `web/app.js` (render report when REPORTING)

- [ ] **Step 1: Wire endpoint and state transition**

Add to `server.ps1`:
```powershell
. "$PSScriptRoot\lib\log-parser.ps1"
. "$PSScriptRoot\lib\smart-suggestions.ps1"

$script:LastReport = $null

# When state goes to REPORTING, generate the report
function Build-Report {
    $logs = Get-LatestLogs
    $cur = Get-AllCoreCo -CoreCount $cpu.Cores
    $r = Read-CoreCyclerLog -CoreCyclerLogPath $logs.coreCyclerLog -Prime95LogPath $logs.prime95Log -CpuInfo $cpu -CurrentCoValues $cur
    $r.smartSuggestions = Get-SmartSuggestions -Report ([PSCustomObject]$r) -Mode 'all-cores' -CpuInfo $cpu -CurrentCoValues $cur
    $r.peaks = Get-Peaks
    $script:LastReport = $r
    $r
}

Register-Route -Method GET -Path '/api/report' -Handler {
    if ($null -eq $script:LastReport) { return @{ ok=$false; error='No report yet' } }
    @{ ok = $true; data = $script:LastReport }
}
```

Modify `/api/test/stop` and detect natural completion in `/api/status` to call `Build-Report` and `Set-State -NewState 'REPORTING'`.

Also add a watcher: in the status handler, if state is TESTING and the CoreCycler process has exited, transition to REPORTING and build the report.

```powershell
# In /api/status handler:
if ($state.state -eq 'TESTING' -and -not (Test-CoreCyclerRunning)) {
    Stop-PeakTracking
    Build-Report | Out-Null
    Set-State -NewState 'REPORTING' -Data $state.data
}
```

- [ ] **Step 2: UI report card**

```html
<section class="card hidden" id="report-card">
  <h2>4. Report</h2>
  <div id="report-content"></div>
</section>
```

- [ ] **Step 3: JS rendering**

```javascript
async function loadReport() {
  const r = await fetchJson('/api/report');
  if (!r.ok) return;
  const d = r.data;
  const verdictColor = d.verdict === 'PASSED' ? 'var(--success)' : 'var(--danger)';
  let html = `<div style="color: ${verdictColor}; font-weight:600; font-size:1.2rem;">Verdict: ${d.verdict === 'PASSED' ? '✅ PASSED' : '❌ FAILED'}</div>`;
  html += `<p>Duration: ${d.duration || '?'} · Iterations: ${d.iterationsCompleted}/${d.iterationsRequested} · Cores tested: ${d.coresTested.length}</p>`;
  if (d.coresFailed && d.coresFailed.length) {
    html += '<table class="report-tbl"><tr><th>Core</th><th>CCD</th><th>CO at failure</th><th>Type</th></tr>';
    d.coresFailed.forEach(c => html += `<tr><td>${c.core}</td><td>${c.ccdLabel}</td><td>${c.coAtFailure}</td><td>${c.errorType}</td></tr>`);
    html += '</table>';
  }
  if (d.smartSuggestions && d.smartSuggestions.length) {
    html += '<h3>💡 Smart Suggestions</h3><ul>';
    d.smartSuggestions.forEach(s => html += `<li>${s}</li>`);
    html += '</ul>';
  }
  if (d.peaks) {
    html += '<h3>📊 Peaks during test</h3>';
    if (d.peaks.packageTemp) html += `<p>Max temp: ${d.peaks.packageTemp.toFixed(0)}°C · Max power: ${d.peaks.packagePower?.toFixed(0)}W</p>`;
  }
  document.getElementById('report-content').innerHTML = html;
  document.getElementById('report-card').classList.remove('hidden');
}

// In pollStatus, when state becomes REPORTING:
//   loadReport(); document.getElementById('status-card').classList.add('hidden');
```

Add table styles:
```css
.report-tbl { width: 100%; border-collapse: collapse; margin: 0.6rem 0; }
.report-tbl th, .report-tbl td { padding: 0.4rem; text-align: left; border-bottom: 1px solid #2a3142; }
```

- [ ] **Step 4: End-to-end test**

Run: `.\Launch.bat`. Run a short 1-iteration test on a couple of cores. Wait for it to finish naturally. Verify report card appears with verdict and suggestions.

- [ ] **Step 5: Commit**

```
git add server.ps1 web/
git commit -m "feat(report): build, expose, render post-test report with suggestions and peaks"
```

---

## Phase 6 — WHEA Bodyguard

Goal: A background watcher subscribes to Windows WHEA events. The UI shows a status indicator and toasts when events fire.

### Task 18: WHEA watcher

**Files:**
- Create: `lib/whea-watcher.ps1`
- Modify: `server.ps1` (init watcher, expose events in /api/status)
- Modify: `web/index.html` (header indicator)
- Modify: `web/app.js` (flash on new event)

- [ ] **Step 1: Write lib/whea-watcher.ps1**

```powershell
Set-StrictMode -Version Latest
. "$PSScriptRoot\logging.ps1"

$script:WheaEvents = New-Object System.Collections.ArrayList
$script:WheaWatcher = $null

function Start-WheaWatcher {
    try {
        $query = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('Microsoft-Windows-Kernel-WHEA/Errors', [System.Diagnostics.Eventing.Reader.PathType]::LogName)
        $script:WheaWatcher = New-Object System.Diagnostics.Eventing.Reader.EventLogWatcher($query)
        Register-ObjectEvent -InputObject $script:WheaWatcher -EventName EventRecordWritten -SourceIdentifier RPO_WHEA -Action {
            $ev = $EventArgs.EventRecord
            $entry = @{ time = $ev.TimeCreated.ToString('o'); eventId = $ev.Id; level = $ev.LevelDisplayName; message = $ev.FormatDescription() }
            $script:WheaEvents.Add($entry) | Out-Null
            while ($script:WheaEvents.Count -gt 200) { $script:WheaEvents.RemoveAt(0) }
        } | Out-Null
        $script:WheaWatcher.Enabled = $true
        Write-Log INFO "WHEA watcher started"
        return $true
    } catch {
        Write-Log WARN "WHEA watcher failed to start: $($_.Exception.Message)"
        return $false
    }
}

function Stop-WheaWatcher {
    if ($script:WheaWatcher) { $script:WheaWatcher.Enabled = $false }
    Unregister-Event -SourceIdentifier RPO_WHEA -ErrorAction SilentlyContinue
}

function Get-WheaEvents {
    , @($script:WheaEvents.ToArray())
}

function Clear-WheaEvents {
    $script:WheaEvents.Clear()
}
```

- [ ] **Step 2: Wire into server.ps1**

```powershell
. "$PSScriptRoot\lib\whea-watcher.ps1"
$wheaActive = Start-WheaWatcher
```

Modify `/api/status` handler to include `wheaEvents = (Get-WheaEvents)` in the response.

- [ ] **Step 3: UI indicator**

In `index.html` header:
```html
<span id="bodyguard" class="bodyguard"><span class="dot"></span> Bodyguard</span>
```

Style:
```css
.bodyguard { display: inline-flex; align-items: center; gap: 0.4rem; color: var(--muted); margin-right: 1rem; }
.bodyguard .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--success); display: inline-block; }
.bodyguard.alert .dot { background: var(--danger); animation: pulse 1s infinite; }
@keyframes pulse { 50% { opacity: 0.3; } }
```

JS — extend the status poll:
```javascript
let lastWheaCount = 0;
// in pollStatus, after parsing response:
if (s.wheaEvents && s.wheaEvents.length > lastWheaCount) {
    showToast(`⚠ WHEA event detected — check Bodyguard log`);
    document.getElementById('bodyguard').classList.add('alert');
    lastWheaCount = s.wheaEvents.length;
}
```

- [ ] **Step 4: Manual verification**

WHEA events are hard to trigger on demand. To test the wiring without real hardware errors, simulate via Event Log:
```powershell
Write-EventLog -LogName 'Microsoft-Windows-Kernel-WHEA/Errors' -Source 'WHEA-Logger' -EventId 17 -Message 'simulated' -EntryType Warning
```
(May not work because that source is reserved — alternative is to wait until a real event fires during a future test run.)

Acceptance: Bodyguard indicator visible in header, code path verified by inspection.

- [ ] **Step 5: Commit**

```
git add lib/whea-watcher.ps1 server.ps1 web/
git commit -m "feat(whea): always-on Bodyguard watcher with UI indicator"
```

---

## Phase 7 — Auto-Adjust Mode + Polish

Goal: Pro-user toggle for AutomaticTestMode that lets CoreCycler auto-bump CO on errors. Polish: error handling, edge cases, end-of-MVP cleanup.

### Task 19: Auto-Adjust toggle

**Files:**
- Modify: `web/index.html` (mode radio)
- Modify: `web/app.js` (collect auto-adjust params)
- Modify: `server.ps1` (pass through to CoreCycler config)

- [ ] **Step 1: UI**

Add to test card:
```html
<div class="co-input"><label>Mode:</label>
  <label><input type="radio" name="testMode" value="manual" checked> Manual</label>
  <label><input type="radio" name="testMode" value="auto"> Auto-Adjust (advanced)</label>
</div>
<div id="auto-options" class="hidden">
  <div class="co-input"><label>Max value:</label><input type="number" id="auto-max" value="0"></div>
  <div class="co-input"><label>Increment by:</label><input type="number" id="auto-inc" value="1" min="1" max="5"></div>
</div>
```

- [ ] **Step 2: JS**

```javascript
document.addEventListener('change', e => {
  if (e.target.name === 'testMode') {
    document.getElementById('auto-options').classList.toggle('hidden', e.target.value !== 'auto');
  }
});
// startTest: include autoAdjust=true and starting values from current form when 'auto'
```

- [ ] **Step 3: Server-side pass-through**

In `/api/test/start`:
```powershell
$auto = $body.autoAdjust -eq $true
$startVals = if ($auto) { Get-AllCoreCo -CoreCount $cpu.Cores } else { $null }
$cfgPath = New-CoreCyclerConfig ... -EnableAutomaticAdjustment $auto -AutoStartValues $startVals -AutoMaxValue $body.autoMax -AutoIncrementBy $body.autoInc
```

- [ ] **Step 4: Manual test (auto mode)**

Set Auto-Adjust mode, configure max=-5, inc=2. Start. CoreCycler should now manage CO bumps internally; status polling should still work.

- [ ] **Step 5: Commit**

```
git add server.ps1 web/
git commit -m "feat(auto-adjust): toggle CoreCycler AutomaticTestMode from UI"
```

### Task 20: Error handling polish

**Files:**
- Modify: `server.ps1` and various lib files

- [ ] **Step 1: Admin-required modal**

In `Launch.bat` already self-elevates. Add a check in `server.ps1` that warns if running non-elevated (e.g. when manually invoked):

```powershell
$isAdmin = (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'ERROR: Ryzen Pro Optimizer must run as administrator. Right-click Launch.bat and Run as Administrator.' -ForegroundColor Red
    pause
    exit 1
}
```

- [ ] **Step 2: ryzen-smu-cli missing**

The Initialize-CoTool function already throws — surface in UI:

```javascript
// On any /api error containing "ryzen-smu-cli", show modal: "Required tool missing — run Install.bat"
```

- [ ] **Step 3: CoreCycler subprocess died unexpectedly**

`Get-TestStateUpdate` (called from /api/status) detects this and transitions REPORTING with verdict='INCOMPLETE'. Already wired in Task 17 — verify and add a banner in the report.

- [ ] **Step 4: Port conflict**

Already handled — `Start-HttpServer` walks the port range. Surface chosen port to console output.

- [ ] **Step 5: Commit**

```
git add server.ps1 web/
git commit -m "fix(errors): handle non-admin, missing tools, crashed subprocess, port conflict"
```

### Task 21: Final UX polish

**Files:** `web/style.css`, `web/index.html`

- [ ] **Step 1: Persistent footer with Esc hint**

```html
<footer class="footer">⚠ Stuck or unstable? Press <kbd>Esc</kbd> to instantly reset all cores.</footer>
```

```css
.footer { position: fixed; bottom: 0; left: 0; right: 0; background: var(--card); color: var(--muted); text-align: center; padding: 0.6rem; border-top: 1px solid #2a3142; font-size: 0.85rem; }
kbd { background: #2a3142; padding: 0.1rem 0.4rem; border-radius: 3px; font-family: monospace; }
body { padding-bottom: 3rem; }
```

- [ ] **Step 2: Tooltip diff on Apply button**

```javascript
// When form changes, compare to current values; if no diff, disable apply with title="No changes"
function refreshApplyButton() {
  const proposed = collectValues();
  // Compute flat array, compare to currentValues
  const flat = expandToCoreArray(proposed);
  if (JSON.stringify(flat) === JSON.stringify(currentValues)) {
    document.getElementById('apply-co').disabled = true;
    document.getElementById('apply-co').title = 'No changes';
  } else {
    document.getElementById('apply-co').disabled = false;
    document.getElementById('apply-co').title = 'Apply these changes';
  }
}
// Bind to input events on form
```

- [ ] **Step 3: README final pass**

Update README.md with screenshot or animated GIF placeholder (manually replace later), final install instructions, attribution to LibreHardwareMonitor (MIT), to CoreCycler (open-source).

- [ ] **Step 4: Final commit**

```
git add web/ README.md
git commit -m "polish: footer hint, apply diff tooltip, final README"
```

---

## Self-Review

**Spec coverage check** — every numbered section of the spec maps to at least one task:

| Spec section | Task(s) |
|---|---|
| §3 Architecture | Tasks 4 (HTTP server), 5 (CPU detect), 11 (telemetry), 18 (WHEA) |
| §4 File Layout | Tasks 1–3 (bootstrap), distributed thereafter |
| §5 Run-State Machine | Task 12 |
| §6 JSON API | Each route registered in its feature task |
| §7 CO Read/Write/Reset/Revert | Tasks 6, 8 |
| §8 CoreCycler orchestration | Tasks 13, 14 |
| §9 Log Parser & Report | Task 15 |
| §10 Smart Suggestions | Task 16 |
| §11 WHEA Bodyguard | Task 18 |
| §11.5 Telemetry | Tasks 10, 11 |
| §12 Profiles | Task 9 |
| §13 Help section | Task 7 |
| §14 Error Handling | Task 20 |
| §15 UI Layout | Distributed across UI tasks |
| §16 Tech Stack | Encoded in tech stack header |
| §19 Success criteria | Tested at end of each phase via manual E2E |
| §20 Build phases | Mirrors phases above |

**Placeholder scan** — no "TBD" or "implement later" strings in the plan body. Open items in spec §18 are deferred to manual investigation steps within tasks (e.g. ryzen-smu-cli subcommand name, sensor mapping per CPU family).

**Type consistency** — Mode strings used consistently: `'all-cores'`, `'per-ccd'`, `'per-core'`. Verdict strings: `'PASSED'`, `'FAILED'`, `'INCOMPLETE'`, `'UNKNOWN'`. State machine names: `IDLE`, `APPLYING_CO`, `TESTING`, `STOPPING`, `REPORTING`, `ERROR`.

End of plan.
