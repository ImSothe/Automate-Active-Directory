function Start-LifecycleWebUI {
    <#
    .SYNOPSIS
        Arranca la interfaz web local (http://localhost:8787) para hacer altas y bajas desde el navegador.
    .DESCRIPTION
        Medidas de seguridad, porque una web que crea usuarios en AD es un objetivo jugoso:
          - Solo escucha en localhost. Se rechaza cualquier cabecera Host distinta (anti DNS rebinding).
          - Token aleatorio de 256 bits por arranque: hay que abrir la URL que muestra la consola.
            Tras el primer acceso se guarda en una cookie HttpOnly + SameSite=Strict y se limpia la URL.
          - La API exige además la cabecera X-Lifecycle-Token (anti CSRF: otra web no puede enviarla
            sin pasar un preflight CORS que este servidor nunca aprueba) y Content-Type JSON.
          - CSP estricta, X-Frame-Options DENY, no-store, no-referrer. Cuerpo máximo 64 KB.
          - El servidor atiende peticiones de una en una y se para con Ctrl+C.
    .EXAMPLE
        Start-LifecycleWebUI
    .EXAMPLE
        Start-LifecycleWebUI -Port 9000 -NoBrowser
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1024, 65535)][int]$Port = 8787,
        [switch]$NoBrowser
    )

    Assert-LcInitialized

    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes); $rng.Dispose()
    $token = -join ($bytes | ForEach-Object { $_.ToString('x2') })

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    try { $listener.Start() }
    catch { throw "No se pudo abrir el puerto $Port en localhost: $($_.Exception.Message)" }

    $url = "http://localhost:$Port/?t=$token"
    Write-Host ''
    Write-Host '  UserLifecycle - interfaz web' -ForegroundColor Cyan
    Write-Host "  Modo: $($script:Lc.Mode)   Organización: $($script:Lc.Config.Organization)"
    Write-Host "  Abre esta URL (lleva el token de esta sesión: no la compartas):"
    Write-Host "  $url" -ForegroundColor Green
    Write-Host '  Ctrl+C para parar.'
    Write-Host ''

    if (-not $NoBrowser -and [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        try { Start-Process $url } catch { }
    }

    $state = @{ Token = $token; Port = $Port }
    try {
        while ($listener.IsListening) {
            $pending = $listener.GetContextAsync()
            while (-not $pending.AsyncWaitHandle.WaitOne(250)) { }
            $context = $pending.GetAwaiter().GetResult()
            try {
                Invoke-LcWebRequest -Context $context -State $state
            }
            catch {
                Write-Warning "Error atendiendo $($context.Request.HttpMethod) $($context.Request.Url.AbsolutePath): $($_.Exception.Message)"
                try { Send-LcWebJson -Context $context -StatusCode 500 -Data @{ error = $_.Exception.Message } } catch { }
            }
        }
    }
    finally {
        $listener.Stop()
        $listener.Close()
        Write-Host 'Servidor detenido.'
    }
}

# ----------------------------------------------------------------------------------------------
# Utilidades HTTP
# ----------------------------------------------------------------------------------------------

function Test-LcTokenEqual {
    # Comparación en tiempo constante (no filtra cuántos caracteres coinciden).
    param([string]$A, [string]$B)
    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B) -or $A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ([int][char]$A[$i] -bxor [int][char]$B[$i]) }
    return ($diff -eq 0)
}

function Set-LcSecurityHeaders {
    param($Response, [string]$Csp)
    if (-not $Csp) { $Csp = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'" }
    $Response.Headers['Content-Security-Policy'] = $Csp
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.Headers['X-Frame-Options'] = 'DENY'
    $Response.Headers['Referrer-Policy'] = 'no-referrer'
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.Headers['Cross-Origin-Opener-Policy'] = 'same-origin'
    $Response.Headers['Cross-Origin-Resource-Policy'] = 'same-origin'
}

function Send-LcWebBytes {
    param($Context, [int]$StatusCode, [byte[]]$Body, [string]$ContentType, [string]$Csp)
    $res = $Context.Response
    $res.StatusCode = $StatusCode
    Set-LcSecurityHeaders -Response $res -Csp $Csp
    $res.ContentType = $ContentType
    $res.ContentLength64 = $Body.Length
    $res.OutputStream.Write($Body, 0, $Body.Length)
    $res.OutputStream.Close()
}

function Send-LcWebText {
    param($Context, [int]$StatusCode = 200, [string]$Text, [string]$ContentType = 'text/html; charset=utf-8', [string]$Csp)
    Send-LcWebBytes -Context $Context -StatusCode $StatusCode -Body ([System.Text.Encoding]::UTF8.GetBytes($Text)) -ContentType $ContentType -Csp $Csp
}

function Send-LcWebJson {
    param($Context, [int]$StatusCode = 200, $Data)
    $json = ConvertTo-Json -InputObject $Data -Depth 10 -Compress
    Send-LcWebText -Context $Context -StatusCode $StatusCode -Text $json -ContentType 'application/json; charset=utf-8'
}

function Read-LcWebJsonBody {
    param($Context)
    $req = $Context.Request
    if ($req.ContentLength64 -gt 65536) { throw [System.IO.InvalidDataException]'Cuerpo demasiado grande.' }
    $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
    try {
        $buffer = New-Object char[] 65537
        $read = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($read -gt 65536) { throw [System.IO.InvalidDataException]'Cuerpo demasiado grande.' }
        $text = New-Object string($buffer, 0, $read)
    }
    finally { $reader.Dispose() }
    if (-not $text.Trim()) { return [pscustomobject]@{} }
    try { return ($text | ConvertFrom-Json) }
    catch { throw [System.IO.InvalidDataException]'JSON no válido.' }
}

function Get-LcBodyValue {
    param($Body, [string]$Name, [int]$MaxLength = 256)
    $p = $Body.PSObject.Properties[$Name]
    if (-not $p -or $null -eq $p.Value) { return '' }
    $v = [string]$p.Value
    if ($v.Length -gt $MaxLength) { throw [System.IO.InvalidDataException]"El campo '$Name' es demasiado largo." }
    return $v.Trim()
}

function ConvertTo-LcWebResult {
    # Prepara el resultado de una operación para JSON (la contraseña solo viaja en esta respuesta).
    param($Result)
    $o = [ordered]@{}
    foreach ($p in $Result.PSObject.Properties) {
        if ($p.Name -eq 'InitialPassword') {
            $o.InitialPassword = $(if ($p.Value) { ConvertFrom-LcSecureString $p.Value } else { $null })
        }
        elseif ($p.Name -ne 'ReportPath') { $o[$p.Name] = $p.Value }
    }
    return $o
}

# ----------------------------------------------------------------------------------------------
# Router
# ----------------------------------------------------------------------------------------------

function Invoke-LcWebRequest {
    param($Context, [hashtable]$State)

    $req = $Context.Request
    $res = $Context.Response
    $method = $req.HttpMethod
    $path = $req.Url.AbsolutePath

    # Anti DNS-rebinding: solo aceptamos Host = localhost:puerto / 127.0.0.1:puerto
    $hostHeader = [string]$req.Headers['Host']
    if ($hostHeader -notin @("localhost:$($State.Port)", "127.0.0.1:$($State.Port)")) {
        Send-LcWebText -Context $Context -StatusCode 421 -Text 'Host no permitido' -ContentType 'text/plain; charset=utf-8'
        return
    }

    $cookie = $req.Cookies['lc_auth']
    $cookieOk = $cookie -and (Test-LcTokenEqual $cookie.Value $State.Token)
    $webRoot = Join-Path $script:ModuleRoot 'Web'

    # --- Páginas y estáticos ---------------------------------------------------------------
    if ($method -eq 'GET' -and $path -eq '/') {
        $t = $req.QueryString['t']
        if ($t -and (Test-LcTokenEqual $t $State.Token)) {
            # Intercambia el token de la URL por una cookie y limpia la barra de direcciones
            $res.AppendHeader('Set-Cookie', "lc_auth=$($State.Token); Path=/; HttpOnly; SameSite=Strict")
            $res.AppendHeader('Location', '/')
            Send-LcWebText -Context $Context -StatusCode 303 -Text '' -ContentType 'text/plain'
            return
        }
        if (-not $cookieOk) {
            $msg = '<!doctype html><meta charset="utf-8"><title>Acceso denegado</title><body style="font-family:system-ui;padding:40px;max-width:560px;margin:auto"><h1>Acceso denegado</h1><p>Abre la URL con el token que aparece en la consola de PowerShell donde lanzaste <code>Start-LifecycleWebUI</code>.</p><p>Cada arranque genera un token nuevo.</p></body>'
            Send-LcWebText -Context $Context -StatusCode 401 -Text $msg -Csp "default-src 'none'; style-src 'unsafe-inline'"
            return
        }
        $html = [System.IO.File]::ReadAllText((Join-Path $webRoot 'index.html'), [System.Text.Encoding]::UTF8)
        $html = $html.Replace('{{TOKEN}}', $State.Token)
        Send-LcWebText -Context $Context -Text $html
        return
    }

    if ($method -eq 'GET' -and $path -in '/app.js', '/app.css', '/favicon.svg') {
        $file = Join-Path $webRoot $path.TrimStart('/')
        $type = switch -Wildcard ($path) { '*.js' { 'text/javascript; charset=utf-8' } '*.css' { 'text/css; charset=utf-8' } default { 'image/svg+xml' } }
        Send-LcWebBytes -Context $Context -StatusCode 200 -Body ([System.IO.File]::ReadAllBytes($file)) -ContentType $type
        return
    }

    if ($method -eq 'GET' -and $path -like '/reports/*') {
        if (-not $cookieOk) { Send-LcWebText -Context $Context -StatusCode 401 -Text 'No autorizado' -ContentType 'text/plain; charset=utf-8'; return }
        $name = $path.Substring('/reports/'.Length)
        # Anti path traversal: solo nombres simples generados por la herramienta
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_\-\.]{0,150}\.html$' -or $name.Contains('..')) {
            Send-LcWebText -Context $Context -StatusCode 400 -Text 'Nombre de informe no válido' -ContentType 'text/plain; charset=utf-8'; return
        }
        $file = Join-Path (Join-Path $script:Lc.Config.Audit.Path 'reports') $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Send-LcWebText -Context $Context -StatusCode 404 -Text 'Informe no encontrado' -ContentType 'text/plain; charset=utf-8'; return }
        Send-LcWebBytes -Context $Context -StatusCode 200 -Body ([System.IO.File]::ReadAllBytes($file)) -ContentType 'text/html; charset=utf-8' -Csp "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"
        return
    }

    if (-not $path.StartsWith('/api/')) {
        Send-LcWebText -Context $Context -StatusCode 404 -Text 'No encontrado' -ContentType 'text/plain; charset=utf-8'
        return
    }

    # --- API: token en cabecera + JSON + mismo origen ----------------------------------------
    if (-not (Test-LcTokenEqual ([string]$req.Headers['X-Lifecycle-Token']) $State.Token)) {
        Send-LcWebJson -Context $Context -StatusCode 401 -Data @{ error = 'Token no válido.' }
        return
    }
    if ($method -eq 'POST') {
        $origin = [string]$req.Headers['Origin']
        if ($origin -and $origin -notin @("http://localhost:$($State.Port)", "http://127.0.0.1:$($State.Port)")) {
            Send-LcWebJson -Context $Context -StatusCode 403 -Data @{ error = 'Origen no permitido.' }
            return
        }
        if (-not ([string]$req.ContentType).StartsWith('application/json')) {
            Send-LcWebJson -Context $Context -StatusCode 415 -Data @{ error = 'Se esperaba application/json.' }
            return
        }
    }

    try {
        $data = Invoke-LcApi -Method $method -Path $path -Context $Context
        if ($null -eq $data) { Send-LcWebJson -Context $Context -StatusCode 404 -Data @{ error = 'Ruta no encontrada.' }; return }
        Send-LcWebJson -Context $Context -Data $data
    }
    catch [System.IO.InvalidDataException] {
        Send-LcWebJson -Context $Context -StatusCode 400 -Data @{ error = $_.Exception.Message }
    }
}

function Invoke-LcApi {
    param([string]$Method, [string]$Path, $Context)

    $cfg = $script:Lc.Config
    $route = "$Method $Path"

    switch ($route) {
        'GET /api/meta' {
            return [ordered]@{
                organization = $cfg.Organization
                mode         = $script:Lc.Mode
                graphEnabled = [bool]$cfg.Graph.Enabled
                upnSuffix    = $cfg.Domain.UpnSuffix
                archiveOU    = $cfg.Domain.ArchiveOU
                departments  = @($cfg.Departments | ForEach-Object { [ordered]@{ name = $_.Name; ou = $_.OU } })
                titleRules   = @($cfg.TitleRules | ForEach-Object { $_.Match })
                operator     = (Get-LcOperator)
            }
        }

        'POST /api/onboarding/preview' {
            $b = Read-LcWebJsonBody $Context
            $plan = New-LcOnboardingPlan -GivenName (Get-LcBodyValue $b 'givenName' 64) -Surname (Get-LcBodyValue $b 'surname' 64) `
                -Department (Get-LcBodyValue $b 'department' 64) -Title (Get-LcBodyValue $b 'title' 64) -EmployeeId (Get-LcBodyValue $b 'employeeId' 16) `
                -Manager (Get-LcBodyValue $b 'manager' 20) -EndDate (Get-LcBodyValue $b 'endDate' 10) -Ticket (Get-LcBodyValue $b 'ticket' 32)
            $plan.Remove('ManagerDn')
            return $plan
        }

        'POST /api/onboarding' {
            $b = Read-LcWebJsonBody $Context
            $errs = $null
            $r = New-LifecycleUser -GivenName (Get-LcBodyValue $b 'givenName' 64) -Surname (Get-LcBodyValue $b 'surname' 64) `
                -Department (Get-LcBodyValue $b 'department' 64) -Title (Get-LcBodyValue $b 'title' 64) -EmployeeId (Get-LcBodyValue $b 'employeeId' 16) `
                -Manager (Get-LcBodyValue $b 'manager' 20) -EndDate (Get-LcBodyValue $b 'endDate' 10) -Ticket (Get-LcBodyValue $b 'ticket' 32) `
                -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable errs -WarningAction SilentlyContinue
            return (ConvertTo-LcWebResult $r)
        }

        'GET /api/users' {
            $q = [string]$Context.Request.QueryString['q']
            if ($q.Length -gt 64) { throw [System.IO.InvalidDataException]'Búsqueda demasiado larga.' }
            return ,@(Find-LcDirUser -Search $q -Max 25 | ForEach-Object {
                    [ordered]@{ sam = $_.SamAccountName; name = $_.DisplayName; department = $_.Department; title = $_.Title; enabled = $_.Enabled; ou = $_.OU; upn = $_.UserPrincipalName }
                })
        }

        'POST /api/offboarding/preview' {
            $b = Read-LcWebJsonBody $Context
            return (New-LcOffboardingPlan (Get-LcBodyValue $b 'identity' 20))
        }

        'POST /api/offboarding' {
            $b = Read-LcWebJsonBody $Context
            $identity = Get-LcBodyValue $b 'identity' 20
            # Confirmación explícita: el cliente debe reenviar el nombre de usuario tecleado
            if ((Get-LcBodyValue $b 'confirm' 20) -cne $identity) { throw [System.IO.InvalidDataException]'La confirmación no coincide con el usuario.' }
            $errs = $null
            $r = Disable-LifecycleUser -Identity $identity -Reason (Get-LcBodyValue $b 'reason' 200) -Ticket (Get-LcBodyValue $b 'ticket' 32) `
                -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable errs -WarningAction SilentlyContinue
            return (ConvertTo-LcWebResult $r)
        }

        'POST /api/cloud-provision' {
            $b = Read-LcWebJsonBody $Context
            $r = Invoke-LifecycleCloudProvisioning -Identity (Get-LcBodyValue $b 'identity' 20) -Ticket (Get-LcBodyValue $b 'ticket' 32) -Confirm:$false
            return (ConvertTo-LcWebResult $r)
        }

        'GET /api/audit' {
            return ,@(Get-LifecycleAuditLog -Last 30 | ForEach-Object {
                    [ordered]@{ startedAt = $_.StartedAt; type = $_.Type; status = $_.Status; operator = $_.Operator; ticket = $_.Ticket; sam = $_.Target.SamAccountName; name = $_.Target.DisplayName; report = $_.Report; mode = $_.Mode }
                })
        }

        'GET /api/audit/verify' { return (Test-LifecycleAuditLog) }

        'GET /api/licenses' {
            if (-not $cfg.Graph.Enabled) { return ,@() }
            return ,@(Get-LcCloudSkus)
        }
    }
    return $null
}
