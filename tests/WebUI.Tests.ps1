#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Security and API tests against the REAL local web server (started in a child process, Lab mode).
    Uses HttpClient directly so we can forge headers (Host, Origin, Content-Type) like an attacker would.
#>

BeforeAll {
    Add-Type -AssemblyName System.Net.Http
    $script:repo = Split-Path -Parent $PSScriptRoot
    $script:work = Join-Path ([System.IO.Path]::GetTempPath()) ('ulc-web-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:work | Out-Null

    $cfg = Get-Content (Join-Path $script:repo 'config/settings.example.json') -Raw | ConvertFrom-Json
    $cfg.Audit.Path = Join-Path $script:work 'audit'
    $cfg.Lab.DataPath = Join-Path $script:work 'lab.json'
    $cfgPath = Join-Path $script:work 'settings.json'
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $cfgPath -Encoding UTF8

    $script:port = Get-Random -Minimum 20000 -Maximum 45000
    $launcher = Join-Path $script:work 'launch.ps1'
    @"
Import-Module '$(Join-Path $script:repo 'src/UserLifecycle')'
`$null = Initialize-Lifecycle -ConfigPath '$cfgPath'
Start-LifecycleWebUI -Port $($script:port) -NoBrowser
"@ | Set-Content -Path $launcher -Encoding UTF8

    $exe = (Get-Process -Id $PID).Path
    $script:stdout = Join-Path $script:work 'stdout.txt'
    $startArgs = @{
        FilePath               = $exe
        ArgumentList           = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher)
        RedirectStandardOutput = $script:stdout
        RedirectStandardError  = (Join-Path $script:work 'stderr.txt')
        PassThru               = $true
    }
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { $startArgs.WindowStyle = 'Hidden' }
    $script:server = Start-Process @startArgs

    $script:token = $null
    $deadline = (Get-Date).AddSeconds(40)
    while (-not $script:token -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        if (Test-Path $script:stdout) {
            $m = Select-String -Path $script:stdout -Pattern '\?t=([a-f0-9]{64})' | Select-Object -First 1
            if ($m) { $script:token = $m.Matches[0].Groups[1].Value }
        }
    }
    if (-not $script:token) { throw "The web server did not start: $(Get-Content (Join-Path $script:work 'stderr.txt') -Raw)" }

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $script:http = New-Object System.Net.Http.HttpClient($handler)
    $script:base = "http://localhost:$($script:port)"

    function Send-Request {
        # $Body is untyped on purpose: [string] would turn $null into '' on Windows PowerShell 5.1 (and send a body with GET)
        param([string]$Method = 'GET', [string]$Path, [hashtable]$Headers = @{}, $Body, [string]$ContentType = 'application/json')
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new($Method), "$($script:base)$Path")
        foreach ($k in $Headers.Keys) {
            if ($k -eq 'Host') { $req.Headers.Host = $Headers[$k] } else { [void]$req.Headers.TryAddWithoutValidation($k, $Headers[$k]) }
        }
        if ($null -ne $Body) { $req.Content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, $ContentType) }
        $res = $script:http.SendAsync($req).GetAwaiter().GetResult()
        $text = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $headers = @{}
        foreach ($h in $res.Headers) { $headers[$h.Key] = ($h.Value -join ', ') }
        foreach ($h in $res.Content.Headers) { $headers[$h.Key] = ($h.Value -join ', ') }
        [pscustomobject]@{ Status = [int]$res.StatusCode; Body = $text; Headers = $headers }
    }
    function Invoke-Api([string]$Method, [string]$Path, $Data) {
        $body = if ($null -ne $Data) { $Data | ConvertTo-Json -Depth 5 } else { $null }
        Send-Request -Method $Method -Path $Path -Headers @{ 'X-Lifecycle-Token' = $script:token } -Body $body
    }
}

AfterAll {
    if ($script:http) { $script:http.Dispose() }
    if ($script:server -and -not $script:server.HasExited) { Stop-Process -Id $script:server.Id -Force }
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $script:work -ErrorAction SilentlyContinue
}

Describe 'Web UI: access control' {
    It 'denies the page without a token' {
        (Send-Request -Path '/').Status | Should -Be 401
    }

    It 'denies the page with a wrong token' {
        (Send-Request -Path "/?t=$('0' * 64)").Status | Should -Be 401
    }

    It 'exchanges a valid URL token for a hardened cookie and cleans the URL' {
        $r = Send-Request -Path "/?t=$($script:token)"
        $r.Status | Should -Be 303
        $r.Headers['Location'] | Should -Be '/'
        $r.Headers['Set-Cookie'] | Should -Match 'HttpOnly'
        $r.Headers['Set-Cookie'] | Should -Match 'SameSite=Strict'
    }

    It 'serves the page with the cookie and strict security headers' {
        $r = Send-Request -Path '/' -Headers @{ Cookie = "lc_auth=$($script:token)" }
        $r.Status | Should -Be 200
        $r.Body | Should -Match 'name="lc-token"'
        $r.Headers['Content-Security-Policy'] | Should -Match "default-src 'none'"
        $r.Headers['Content-Security-Policy'] | Should -Match "frame-ancestors 'none'"
        $r.Headers['X-Frame-Options'] | Should -Be 'DENY'
        $r.Headers['X-Content-Type-Options'] | Should -Be 'nosniff'
        $r.Headers['Referrer-Policy'] | Should -Be 'no-referrer'
        $r.Headers['Cache-Control'] | Should -Match 'no-store'
    }

    It 'rejects a foreign Host header (DNS rebinding)' {
        $r = Send-Request -Path "/?t=$($script:token)" -Headers @{ Host = "evil.example:$($script:port)" }
        $r.Status | Should -Not -Be 200
        $r.Status | Should -Not -Be 303
    }
}

Describe 'Web UI: API protections' {
    It 'requires the X-Lifecycle-Token header (a cookie alone is not enough)' {
        (Send-Request -Path '/api/meta' -Headers @{ Cookie = "lc_auth=$($script:token)" }).Status | Should -Be 401
    }

    It 'rejects cross-origin POSTs (CSRF)' {
        $r = Send-Request -Method POST -Path '/api/onboarding/preview' -Headers @{ 'X-Lifecycle-Token' = $script:token; Origin = 'https://evil.example' } -Body '{}'
        $r.Status | Should -Be 403
    }

    It 'rejects non-JSON bodies (HTML form CSRF)' {
        $r = Send-Request -Method POST -Path '/api/onboarding' -Headers @{ 'X-Lifecycle-Token' = $script:token } -Body 'givenName=x' -ContentType 'application/x-www-form-urlencoded'
        $r.Status | Should -Be 415
    }

    It 'rejects bodies over 64 KB' {
        $r = Invoke-Api POST '/api/onboarding/preview' @{ givenName = ('a' * 70000) }
        $r.Status | Should -Be 400
        $r.Body | Should -Match 'demasiado grande'
    }

    It 'rejects oversized chunked bodies (no Content-Length header)' {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$($script:base)/api/onboarding/preview")
        [void]$req.Headers.TryAddWithoutValidation('X-Lifecycle-Token', $script:token)
        $req.Headers.TransferEncodingChunked = $true
        $req.Content = New-Object System.Net.Http.StringContent(('{"givenName":"' + ('a' * 70000) + '"}'), [System.Text.Encoding]::UTF8, 'application/json')
        $req.Content.Headers.ContentLength = $null
        $res = $script:http.SendAsync($req).GetAwaiter().GetResult()
        [int]$res.StatusCode | Should -Be 400
        # The server never buffers more than 64 KB; it must say so explicitly (not just fail to parse)
        $res.Content.ReadAsStringAsync().GetAwaiter().GetResult() | Should -Match 'demasiado grande'
    }

    It 'never serves files outside the reports folder (path traversal)' {
        # Depending on the OS, http.sys / the managed listener may normalise or reject this URL before
        # it reaches our code (400/403/404). What matters: it is never served.
        $r = Send-Request -Path '/reports/..%2f..%2fsettings.json' -Headers @{ Cookie = "lc_auth=$($script:token)" }
        $r.Status | Should -BeIn @(400, 403, 404)
        $r.Body | Should -Not -Match '"Mode"'
    }

    It 'only serves generated .html report names' {
        # Reaches our own allow-list on every platform
        $r = Send-Request -Path '/reports/audit-log.jsonl' -Headers @{ Cookie = "lc_auth=$($script:token)" }
        $r.Status | Should -Be 400
    }

    It 'rejects offboarding when the typed confirmation does not match' {
        $r = Invoke-Api POST '/api/offboarding' @{ identity = 'aruiz'; confirm = 'someone-else' }
        $r.Status | Should -Be 400
    }
}

Describe 'Web UI: end-to-end through the API' {
    It 'returns metadata' {
        $meta = (Invoke-Api GET '/api/meta').Body | ConvertFrom-Json
        $meta.mode | Should -Be 'Lab'
        $meta.departments.name | Should -Contain 'Ventas'
    }

    It 'returns an empty JSON array (not 404) when a search has no results' {
        $r = Invoke-Api GET '/api/users?q=zzzz'
        $r.Status | Should -Be 200
        $r.Body | Should -Be '[]'
    }

    It 'previews, onboards and serves the report' {
        $form = @{ givenName = 'Juan'; surname = 'García López'; department = 'Ventas'; title = 'Comercial'; ticket = 'RRHH-9' }
        $plan = (Invoke-Api POST '/api/onboarding/preview' $form).Body | ConvertFrom-Json
        $plan.CanProceed | Should -BeTrue
        $plan.SamAccountName | Should -Be 'jgarcial'
        $plan.PSObject.Properties.Name | Should -Not -Contain 'ManagerDn'

        $r = (Invoke-Api POST '/api/onboarding' $form).Body | ConvertFrom-Json
        $r.Status | Should -Be 'Success'
        $r.InitialPassword.Length | Should -Be 16
        $r.PSObject.Properties.Name | Should -Not -Contain 'ReportPath'   # no local paths leaked to the browser

        $rep = Send-Request -Path "/reports/$($r.ReportFile)" -Headers @{ Cookie = "lc_auth=$($script:token)" }
        $rep.Status | Should -Be 200
        $rep.Body | Should -Match 'jgarcial'
        $rep.Body | Should -Not -Match ([regex]::Escape($r.InitialPassword))
    }

    It 'requires the cookie to open a report' {
        $last = ((Invoke-Api GET '/api/audit').Body | ConvertFrom-Json)[0]
        (Send-Request -Path "/reports/$($last.report)").Status | Should -Be 401
    }

    It 'offboards with a matching confirmation' {
        $r = (Invoke-Api POST '/api/offboarding' @{ identity = 'aruiz'; confirm = 'aruiz'; reason = 'Fin de contrato'; ticket = 'RRHH-10' }).Body | ConvertFrom-Json
        $r.Status | Should -Be 'Success'
    }

    It 'lists both operations in the audit log and the chain is valid' {
        $audit = (Invoke-Api GET '/api/audit').Body | ConvertFrom-Json
        $audit.type | Should -Contain 'Onboarding'
        $audit.type | Should -Contain 'Offboarding'
        ((Invoke-Api GET '/api/audit/verify').Body | ConvertFrom-Json).Valid | Should -BeTrue
    }
}
