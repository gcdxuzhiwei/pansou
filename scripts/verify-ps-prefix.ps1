param(
    [string] $BaseUrl = "http://localhost:10486"
)

$ErrorActionPreference = "Stop"
$BaseUrl = $BaseUrl.TrimEnd("/")

$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$script:Client = [System.Net.Http.HttpClient]::new($handler)
$script:Client.Timeout = [TimeSpan]::FromSeconds(30)

function Get-TestResponse {
    param([Parameter(Mandatory)][string] $Path)

    $response = $script:Client.GetAsync("$BaseUrl$Path").GetAwaiter().GetResult()
    try {
        [pscustomobject]@{
            Status = [int] $response.StatusCode
            Location = if ($response.Headers.Location) {
                $response.Headers.Location.OriginalString
            } else {
                $null
            }
            Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
    } finally {
        $response.Dispose()
    }
}

function Assert-Response {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][int] $Status,
        [string] $Location = ""
    )

    $result = Get-TestResponse -Path $Path
    if ($result.Status -ne $Status) {
        throw "$Path expected HTTP $Status, got $($result.Status)"
    }
    if ($Location -and $result.Location -ne $Location) {
        throw "$Path expected Location '$Location', got '$($result.Location)'"
    }

    return $result.Body
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)][string] $Actual,
        [Parameter(Mandatory)][string] $Expected
    )

    if (-not $Actual.Contains($Expected)) {
        throw "Response did not contain '$Expected'"
    }
}

function Assert-FrontendAssets {
    param([Parameter(Mandatory)][string] $Html)

    $pattern = '(?:src|href)="(?<path>/ps/[^"]+\.(?:js|css|ico)(?:\?[^"]*)?)"'
    $paths = [regex]::Matches($Html, $pattern) |
        ForEach-Object { $_.Groups["path"].Value } |
        Sort-Object -Unique

    if (-not $paths) {
        throw "No /ps-prefixed frontend assets were found"
    }

    foreach ($path in $paths) {
        $body = Assert-Response -Path $path -Status 200
        if ($path -match '\.js(?:\?|$)') {
            foreach ($legacyBaseUrl in @('/api', '/qqpd', '/gying', '/panlian', '/weibo')) {
                if ($body.Contains("baseURL:`"$legacyBaseUrl`"")) {
                    throw "$path still contains unprefixed Axios baseURL '$legacyBaseUrl'"
                }
            }
        }
    }
}

function Assert-JsonValue {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][int] $Status,
        [Parameter(Mandatory)][string] $Property,
        [Parameter(Mandatory)][string] $Expected
    )

    $body = Assert-Response -Path $Path -Status $Status
    $json = $body | ConvertFrom-Json
    if ([string]$json.$Property -ne $Expected) {
        throw "$Path expected JSON $Property='$Expected', got '$($json.$Property)'"
    }
}

function Assert-Routed {
    param([Parameter(Mandatory)][string] $Path)

    $result = Get-TestResponse -Path $Path
    if ($result.Status -in 404, 502) {
        throw "$Path did not reach the application: HTTP $($result.Status)"
    }
}

try {
    [void](Assert-Response -Path "/" -Status 302 -Location "/ps/")
    [void](Assert-Response -Path "/ps" -Status 301 -Location "/ps/")

    $html = Assert-Response -Path "/ps/" -Status 200
    Assert-Contains -Actual $html -Expected "/ps/assets/"
    Assert-Contains -Actual $html -Expected "/ps/favicon.ico"
    Assert-FrontendAssets -Html $html

    Assert-JsonValue -Path "/ps/api/health" -Status 200 -Property "status" -Expected "ok"
    Assert-Routed -Path "/ps/api/search"
    Assert-Routed -Path "/ps/panlian/ps-prefix-probe"

    [void](Assert-Response -Path "/api/health" -Status 404)
    [void](Assert-Response -Path "/assets/legacy.js" -Status 404)
    [void](Assert-Response -Path "/panlian/ps-prefix-probe" -Status 404)

    Write-Host "PASS: /ps prefix contract verified at $BaseUrl"
} finally {
    $script:Client.Dispose()
    $handler.Dispose()
}
