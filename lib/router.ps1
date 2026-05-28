# ============================================================================
#  router.ps1 - Parameterised HTTP route table
# ============================================================================
#  Used by  : http-server.ps1 (resolves an incoming request to a handler)
#  Populated by: server.ps1 (calls Register-Route for each endpoint)
#
#  How paths work: "/api/profiles/{name}" registers a route where
#  {name} is captured and passed to the handler as $params.name. The
#  pattern segment matches one URL segment (no slashes). Anything more
#  exotic - regexy paths, query-string parsing - is intentionally NOT
#  here: the simpler the router, the fewer surprises in the request log.
# ============================================================================
Set-StrictMode -Version Latest

# Route table: keys "METHOD /path" => @{ Handler = scriptblock; PathPattern = regex; ParamNames = string[] }
$script:Routes = @{}

function Register-Route {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$Handler
    )
    # Build a regex pattern from the path, capturing {paramName} segments
    $paramNames = @()
    $pattern = $Path
    $paramRegex = [regex]'\{([^}]+)\}'
    foreach ($m in $paramRegex.Matches($Path)) {
        $paramNames += $m.Groups[1].Value
    }
    $pattern = '^' + ($paramRegex.Replace($pattern, '([^/]+)')) + '$'

    $script:Routes["$Method $Path"] = @{
        Handler = $Handler
        Method = $Method
        Path = $Path
        PathPattern = $pattern
        ParamNames = $paramNames
    }
}

function Resolve-Route {
    param([string]$Method, [string]$Path)

    foreach ($key in $script:Routes.Keys) {
        $route = $script:Routes[$key]
        if ($route.Method -ne $Method) { continue }
        if ($Path -match $route.PathPattern) {
            $params = @{}
            for ($i = 0; $i -lt $route.ParamNames.Count; $i++) {
                $params[$route.ParamNames[$i]] = [uri]::UnescapeDataString($Matches[$i + 1])
            }
            return @{ Handler = $route.Handler; Params = $params }
        }
    }
    return $null
}

function Clear-Routes { $script:Routes = @{} }
function Get-RegisteredRoutes { $script:Routes.Keys | Sort-Object }
