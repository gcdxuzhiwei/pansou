# PanSou `/ps` Path Prefix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make port 10486 expose the PanSou page, static assets, APIs, and plugin routes only below `/ps`, with `/` redirecting to `/ps/`.

**Architecture:** Add a dedicated Nginx gateway in front of the existing `pansou-web` container. The gateway owns host port 10486, strips `/ps` before forwarding to the internal application, rewrites root-relative frontend references, and rejects unprefixed legacy paths.

**Tech Stack:** Docker Compose, Nginx Alpine, PowerShell 7 endpoint verification

## Global Constraints

- Preserve all existing `docker-compose.yml` environment, volume, autoheal, and application settings.
- Keep the Go service's internal `/api` and plugin routes unchanged.
- Expose only `/ps/...` externally, except `/`, which redirects to `/ps/`.
- Do not rewrite API JSON or third-party URLs.
- Leave implementation changes uncommitted unless the user explicitly requests a commit, because `docker-compose.yml` already contains user-staged work.

---

## File Structure

- Create `deploy/nginx-ps.conf`: gateway routing, prefix stripping, response rewriting, caching, compression, and legacy-path rejection.
- Create `scripts/verify-ps-prefix.ps1`: repeatable HTTP contract test for redirects, assets, API routing, plugin routing, and legacy 404 behavior.
- Modify `docker-compose.yml`: move host port 10486 to the gateway and keep the application internal.

### Task 1: Add the external HTTP contract test

**Files:**
- Create: `scripts/verify-ps-prefix.ps1`

**Interfaces:**
- Consumes: a running deployment at parameter `BaseUrl`, defaulting to `http://localhost:10486`.
- Produces: exit code 0 when the `/ps` contract passes; a terminating PowerShell error naming the failed assertion otherwise.

- [ ] **Step 1: Write the failing endpoint verification script**

Implement a PowerShell 7 script using `System.Net.Http.HttpClientHandler` with `AllowAutoRedirect = $false`. It must assert:

```powershell
Assert-Response -Path "/" -Status 302 -Location "/ps/"
Assert-Response -Path "/ps" -Status 301 -Location "/ps/"
$html = Assert-Response -Path "/ps/" -Status 200
Assert-Contains $html '/ps/assets/'
Assert-Contains $html '/ps/favicon.ico'
Assert-FrontendAssets -Html $html
Assert-JsonValue -Path "/ps/api/health" -Status 200 -Property status -Expected "ok"
Assert-Routed -Path "/ps/api/search"
Assert-Routed -Path "/ps/panlian/ps-prefix-probe"
Assert-Response -Path "/api/health" -Status 404
Assert-Response -Path "/assets/legacy.js" -Status 404
Assert-Response -Path "/panlian/ps-prefix-probe" -Status 404
```

`Assert-Routed` accepts any application response except 404 or 502. `Assert-FrontendAssets` extracts `/ps/...` paths from HTML `src` and `href` attributes and requires every JS, CSS, and favicon request to return 200. The script must define the core helpers as follows:

```powershell
function Get-TestResponse([string] $Path) {
    $response = $script:Client.GetAsync("$BaseUrl$Path").GetAwaiter().GetResult()
    [pscustomobject]@{
        Status = [int] $response.StatusCode
        Location = if ($response.Headers.Location) { $response.Headers.Location.OriginalString } else { $null }
        Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
}

function Assert-Response([string] $Path, [int] $Status, [string] $Location = "") {
    $result = Get-TestResponse $Path
    if ($result.Status -ne $Status) { throw "$Path expected $Status, got $($result.Status)" }
    if ($Location -and $result.Location -ne $Location) { throw "$Path expected Location $Location, got $($result.Location)" }
    $result.Body
}

function Assert-Routed([string] $Path) {
    $result = Get-TestResponse $Path
    if ($result.Status -in 404, 502) { throw "$Path did not reach the application: $($result.Status)" }
}
```

`Assert-Contains`, `Assert-JsonValue`, and `Assert-FrontendAssets` throw on mismatch. The asset helper uses `[regex]::Matches($Html, '(?:src|href)="(?<path>/ps/[^\"]+\.(?:js|css|ico)(?:\?[^\"]*)?)"')`, de-duplicates captured paths, requires at least one asset, and calls `Assert-Response -Status 200` for each one.

- [ ] **Step 2: Run the script against the current deployment and verify RED**

Run:

```powershell
pwsh -NoProfile -File scripts/verify-ps-prefix.ps1
```

Expected: FAIL on the first assertion because the current `GET /` returns 200 rather than redirecting to `/ps/`.

### Task 2: Implement the prefix gateway

**Files:**
- Create: `deploy/nginx-ps.conf`
- Modify: `docker-compose.yml`
- Test: `scripts/verify-ps-prefix.ps1`

**Interfaces:**
- Consumes: upstream service name `pansou` on container port 80.
- Produces: gateway service on container port 80 and host port 10486.

- [ ] **Step 1: Verify the missing Nginx configuration fails**

Run:

```powershell
docker run --rm -v "${PWD}/deploy/nginx-ps.conf:/etc/nginx/conf.d/default.conf:ro" nginx:alpine nginx -t
```

Expected: FAIL because `deploy/nginx-ps.conf` does not exist.

- [ ] **Step 2: Create the minimal gateway configuration**

The server contains:

```nginx
location = / {
    return 302 /ps/;
}

location = /ps {
    return 301 /ps/;
}

location ^~ /ps/ {
    rewrite ^/ps(/.*)$ $1 break;
    proxy_pass http://pansou:80;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Prefix /ps;
    proxy_set_header Accept-Encoding "";
    proxy_redirect ~^(/.*)$ /ps$1;

    sub_filter_once off;
    sub_filter_types text/css application/javascript;
    sub_filter 'src="/' 'src="/ps/';
    sub_filter 'href="/' 'href="/ps/';
    sub_filter 'action="/' 'action="/ps/';
    sub_filter "src='/" "src='/ps/";
    sub_filter "href='/" "href='/ps/";
    sub_filter "action='/" "action='/ps/";
    sub_filter '"/api/' '"/ps/api/';
    sub_filter "'/api/" "'/ps/api/";
    sub_filter '`/api/' '`/ps/api/';
    sub_filter '"/api"' '"/ps/api"';
    sub_filter "'/api'" "'/ps/api'";
    sub_filter '"/qqpd/' '"/ps/qqpd/';
    sub_filter "'/qqpd/" "'/ps/qqpd/";
    sub_filter '"/gying/' '"/ps/gying/';
    sub_filter "'/gying/" "'/ps/gying/";
    sub_filter '"/weibo/' '"/ps/weibo/';
    sub_filter "'/weibo/" "'/ps/weibo/";
    sub_filter '"/panlian/' '"/ps/panlian/';
    sub_filter "'/panlian/" "'/ps/panlian/";
    # Each plugin above also has matching no-trailing-slash baseURL rewrites.
}

location / {
    return 404;
}
```

Also configure `client_max_body_size 50M`, gzip for text responses, and `proxy_connect_timeout 15s`, `proxy_send_timeout 30s`, `proxy_read_timeout 180s`, and `proxy_buffering off`. Add CSS rewrites for `url(/`, `url('/`, and `url("/`. The upstream cache and no-cache headers remain authoritative, and API JSON stays outside `sub_filter_types`.

- [ ] **Step 3: Update Compose without losing existing staged configuration**

Replace the `pansou` host port with:

```yaml
expose:
  - "80"
```

Add this service before `autoheal`:

```yaml
gateway:
  image: nginx:alpine
  container_name: pansou-gateway
  labels:
    - "autoheal=true"
  ports:
    - "10486:80"
  volumes:
    - ./deploy/nginx-ps.conf:/etc/nginx/conf.d/default.conf:ro
  depends_on:
    - pansou
  healthcheck:
    test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1/ps/api/health"]
    interval: 30s
    timeout: 10s
    retries: 3
    start_period: 40s
  restart: unless-stopped
```

- [ ] **Step 4: Verify static configuration GREEN**

Run:

```powershell
docker compose config --quiet
docker run --rm --add-host pansou:127.0.0.1 -v "${PWD}/deploy/nginx-ps.conf:/etc/nginx/conf.d/default.conf:ro" nginx:alpine nginx -t
```

Expected: both commands exit 0; Nginx prints `syntax is ok` and `test is successful`.

### Task 3: Deploy and verify the full request flow

**Files:**
- Modify if a prefix-specific test exposes a defect: `deploy/nginx-ps.conf`
- Test: `scripts/verify-ps-prefix.ps1`

**Interfaces:**
- Consumes: completed Compose and Nginx configuration.
- Produces: verified deployment at `http://localhost:10486/ps/`.

- [ ] **Step 1: Recreate affected services**

Run:

```powershell
docker compose up -d --force-recreate pansou gateway autoheal
docker compose ps
```

Expected: `pansou-app`, `pansou-gateway`, and `pansou-autoheal` run; only the gateway publishes 10486.

- [ ] **Step 2: Run the HTTP contract test**

Run:

```powershell
pwsh -NoProfile -File scripts/verify-ps-prefix.ps1
```

Expected: PASS for redirects, page resources, API and plugin routing, and legacy-path rejection.

- [ ] **Step 3: Run regression checks**

Run:

```powershell
go test ./...
docker compose config --quiet
docker compose ps
```

Expected: Go tests pass, Compose validation exits 0, and all services remain running or healthy.

- [ ] **Step 4: Inspect the final change boundary**

Run:

```powershell
git status --short
git diff --check
git diff -- docker-compose.yml deploy/nginx-ps.conf scripts/verify-ps-prefix.ps1
```

Expected: only requested implementation files change; the pre-existing staged Compose work stays staged and no unrelated file changes.
