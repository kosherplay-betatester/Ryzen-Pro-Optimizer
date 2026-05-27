Set-StrictMode -Version Latest

. "$PSScriptRoot\logging.ps1"
. "$PSScriptRoot\router.ps1"

$script:ListenerPort = 0

function Start-HttpServer {
    param(
        [int]$StartPort = 8765,
        [int]$MaxPort = 8775
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
    Write-Host ""
    Write-Host "  Ryzen Pro Optimizer server listening at " -NoNewline
    Write-Host "http://127.0.0.1:$port/" -ForegroundColor Cyan
    Write-Host "  Press Ctrl+C to stop the server."
    Write-Host ""
    $script:ListenerPort = $port

    return $listener
}

function Get-ListenerPort { $script:ListenerPort }

function Send-JsonResponse {
    param($Context, [int]$Status = 200, $Data)
    $body = $Data | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    try {
        $Context.Response.ContentLength64 = $bytes.Length
        $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } finally {
        try { $Context.Response.OutputStream.Close() } catch {}
    }
}

function Send-FileResponse {
    param($Context, [string]$Path)
    if (-not (Test-Path $Path) -or (Get-Item $Path).PSIsContainer) {
        $Context.Response.StatusCode = 404
        try { $Context.Response.OutputStream.Close() } catch {}
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
        '.ico'  { 'image/x-icon' }
        default { 'application/octet-stream' }
    }
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $mime
    try {
        $Context.Response.ContentLength64 = $bytes.Length
        $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } finally {
        try { $Context.Response.OutputStream.Close() } catch {}
    }
}

function Read-JsonBody {
    param($Context)
    if (-not $Context.Request.HasEntityBody) { return $null }
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
            # API routes: anything starting with /api
            if ($rawUrl.StartsWith('/api')) {
                $route = Resolve-Route -Method $method -Path $rawUrl
                if (-not $route) {
                    Send-JsonResponse -Context $context -Status 404 -Data @{ ok=$false; error="Unknown route $method $rawUrl" }
                    continue
                }
                $result = & $route.Handler $context $route.Params
                if ($null -eq $result) { continue }  # Handler wrote its own response
                Send-JsonResponse -Context $context -Data $result
                continue
            }

            # Static files from web root
            $relPath = if ($rawUrl -eq '/') { 'index.html' } else { $rawUrl.TrimStart('/') }
            # Prevent path traversal
            if ($relPath -match '\.\.') {
                $context.Response.StatusCode = 403
                $context.Response.OutputStream.Close()
                continue
            }
            $filePath = Join-Path $WebRoot $relPath
            Send-FileResponse -Context $context -Path $filePath
        } catch {
            Write-Log ERROR "Handler error: $($_.Exception.Message)"
            try { Send-JsonResponse -Context $context -Status 500 -Data @{ ok=$false; error=$_.Exception.Message } } catch {}
        }
    }
}
