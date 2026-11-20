# Auditoría:
#  - Cada operación genera un informe HTML (legible / imprimible) y otro JSON (máquinas / SIEM).
#  - Todas las operaciones se añaden a audit-log.jsonl, una línea por operación.
#    Cada línea incluye PrevHash = SHA-256 de la línea anterior: si alguien edita o borra una
#    línea intermedia, la cadena se rompe y Test-LifecycleAuditLog lo detecta.
#  - Las contraseñas NUNCA se escriben en el log ni en los informes.

function Get-LcOperator {
    try {
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        }
    }
    catch { Write-Verbose "WindowsIdentity no disponible: $($_.Exception.Message)" }
    return "$([System.Environment]::UserDomainName)\$([System.Environment]::UserName)"
}

function New-LcOperation {
    param([string]$Type, [System.Collections.IDictionary]$InputData, [string]$Ticket)
    return [ordered]@{
        OperationId = [guid]::NewGuid().ToString()
        Type        = $Type
        Mode        = $script:Lc.Mode
        Status      = 'Running'
        Operator    = (Get-LcOperator)
        Computer    = [System.Environment]::MachineName
        Ticket      = $Ticket
        StartedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
        FinishedAt  = $null
        Target      = [ordered]@{}
        Input       = $InputData
        Snapshot    = $null
        Steps       = New-Object System.Collections.ArrayList
        Aborted     = $false
    }
}

function Add-LcStep {
    <#
        Status: OK | Warning | Failed | Skipped | Pending
        Todo paso queda también en el stream Verbose (útil con -Verbose en consola).
    #>
    param(
        [System.Collections.IDictionary]$Operation,
        [string]$Name,
        [ValidateSet('OK', 'Warning', 'Failed', 'Skipped', 'Pending')][string]$Status,
        [string]$Detail = ''
    )
    $step = [ordered]@{ Time = (Get-Date).ToString('HH:mm:ss'); Name = $Name; Status = $Status; Detail = $Detail }
    [void]$Operation.Steps.Add($step)
    Write-Verbose ("[{0}] {1} {2}" -f $Status, $Name, $Detail)
}

function Get-LcOperationStatus {
    param([System.Collections.IDictionary]$Operation)
    if ($Operation.Status -eq 'Rejected') { return 'Rejected' }
    if ($Operation.Aborted) { return 'Failed' }
    $states = @($Operation.Steps | ForEach-Object { $_.Status })
    if ($states -contains 'Failed' -or $states -contains 'Warning' -or $states -contains 'Pending') { return 'Partial' }
    return 'Success'
}

function Get-LcSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
    }
    finally { $sha.Dispose() }
}

function Get-LcAuditLogPath {
    return (Join-Path $script:Lc.Config.Audit.Path 'audit-log.jsonl')
}

function Read-LcLogLines {
    # Lee el log completo y CIERRA el fichero antes de devolver nada.
    # (File.ReadLines + 'return' a mitad del foreach dejaba el fichero abierto: en Windows eso
    # bloqueaba el log y la siguiente operación no podía escribir en él.)
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
}

function Get-LcLastLogLine {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $last = $null
    foreach ($line in (Read-LcLogLines $Path)) {
        if ($line.Trim()) { $last = $line }
    }
    return $last
}

function Write-LcAuditLog {
    # Añade la operación al log encadenado. Devuelve el hash de la línea escrita.
    param([System.Collections.IDictionary]$Operation, [string]$ReportFile)

    $path = Get-LcAuditLogPath
    $prev = Get-LcLastLogLine $path
    $prevHash = if ($prev) { Get-LcSha256 $prev } else { 'GENESIS' }

    $entry = [ordered]@{
        PrevHash    = $prevHash
        OperationId = $Operation.OperationId
        Type        = $Operation.Type
        Status      = $Operation.Status
        Mode        = $Operation.Mode
        Operator    = $Operation.Operator
        Computer    = $Operation.Computer
        Ticket      = $Operation.Ticket
        StartedAt   = $Operation.StartedAt
        FinishedAt  = $Operation.FinishedAt
        Target      = $Operation.Target
        Steps       = @($Operation.Steps | ForEach-Object { [ordered]@{ Name = $_.Name; Status = $_.Status; Detail = $_.Detail } })
        Report      = $ReportFile
    }
    $line = $entry | ConvertTo-Json -Depth 8 -Compress
    [System.IO.File]::AppendAllText($path, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
    return (Get-LcSha256 $line)
}

function ConvertTo-LcHtmlText {
    param($Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-LcStatusLabel {
    param([string]$Status)
    switch ($Status) {
        'Success' { 'Completada' }
        'Partial' { 'Completada con avisos' }
        'Failed' { 'Fallida' }
        'Rejected' { 'Rechazada' }
        'OK' { 'OK' }
        'Warning' { 'Aviso' }
        'Pending' { 'Pendiente' }
        'Skipped' { 'Omitido' }
        default { $Status }
    }
}

function Get-LcTypeLabel {
    param([string]$Type)
    switch ($Type) {
        'Onboarding' { 'Alta de usuario' }
        'Offboarding' { 'Baja de usuario' }
        'CloudProvisioning' { 'Aprovisionamiento en Microsoft 365' }
        default { $Type }
    }
}

function Get-LcFieldLabel {
    param([string]$Key)
    $labels = @{
        SamAccountName = 'Usuario (sAMAccountName)'; UserPrincipalName = 'UPN'; DisplayName = 'Nombre'; Department = 'Departamento'
        Title = 'Puesto'; EmployeeId = 'Nº de empleado'; Manager = 'Responsable'; EndDate = 'Fin de contrato'; OU = 'OU'
        Groups = 'Grupos'; Licenses = 'Licencias'; Reason = 'Motivo'; TargetOU = 'OU de destino'; Enabled = 'Habilitada'; Description = 'Descripción'
    }
    if ($labels.ContainsKey($Key)) { return $labels[$Key] }
    return $Key
}

function ConvertTo-LcReportHtml {
    param([System.Collections.IDictionary]$Operation, [string]$LogHash)

    $h = { param($v) ConvertTo-LcHtmlText $v }
    $org = & $h $script:Lc.Config.Organization
    $title = & $h (Get-LcTypeLabel $Operation.Type)
    $status = $Operation.Status
    $statusClass = switch ($status) { 'Success' { 'ok' } 'Partial' { 'warn' } default { 'fail' } }

    $targetRows = foreach ($k in $Operation.Target.Keys) {
        $v = $Operation.Target[$k]
        if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { $v = (@($v) -join ', ') }
        "<tr><th>$(& $h (Get-LcFieldLabel $k))</th><td>$(& $h $v)</td></tr>"
    }

    $stepRows = foreach ($s in $Operation.Steps) {
        $cls = switch ($s.Status) { 'OK' { 'ok' } 'Warning' { 'warn' } 'Pending' { 'warn' } 'Skipped' { 'muted' } default { 'fail' } }
        "<tr><td class=""mono nowrap"">$(& $h $s.Time)</td><td>$(& $h $s.Name)</td><td><span class=""badge $cls"">$(& $h (Get-LcStatusLabel $s.Status))</span></td><td>$(& $h $s.Detail)</td></tr>"
    }

    $snapshotHtml = ''
    if ($Operation.Snapshot) {
        $snapRows = foreach ($k in $Operation.Snapshot.Keys) {
            $v = $Operation.Snapshot[$k]
            if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { $v = (@($v) -join ', ') }
            "<tr><th>$(& $h (Get-LcFieldLabel $k))</th><td>$(& $h $v)</td></tr>"
        }
        $snapshotHtml = "<h2>Estado previo (instantánea antes de la baja)</h2><table class=""kv"">$($snapRows -join '')</table>"
    }

    return @"
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title - $(& $h $Operation.Target.SamAccountName)</title>
<style>
  :root { --bg:#f6f7f9; --card:#fff; --text:#1d2330; --muted:#5d6678; --line:#e3e6ec; --ok:#1f7a4d; --okbg:#e3f4ea; --warn:#8a5a00; --warnbg:#fdf1d8; --fail:#b42318; --failbg:#fde8e6; }
  @media (prefers-color-scheme: dark) { :root { --bg:#12151b; --card:#1b1f27; --text:#e7e9ee; --muted:#9aa3b2; --line:#2b313c; --ok:#5fd39a; --okbg:#173326; --warn:#f2c260; --warnbg:#3a2e12; --fail:#ff8a7f; --failbg:#3d1a17; } }
  * { box-sizing: border-box; }
  body { margin:0; font:15px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; background:var(--bg); color:var(--text); }
  main { max-width: 960px; margin: 0 auto; padding: 32px 16px 48px; }
  header { display:flex; justify-content:space-between; align-items:flex-start; gap:16px; flex-wrap:wrap; }
  h1 { font-size: 24px; margin: 0 0 4px; } h2 { font-size: 16px; margin: 28px 0 10px; }
  .sub { color: var(--muted); margin: 0; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:10px; overflow:hidden; }
  table { width:100%; border-collapse:collapse; background:var(--card); border:1px solid var(--line); border-radius:10px; overflow:hidden; }
  th, td { text-align:left; padding:8px 12px; border-bottom:1px solid var(--line); vertical-align:top; overflow-wrap:anywhere; }
  tr:last-child th, tr:last-child td { border-bottom:0; }
  .kv th { width: 220px; color: var(--muted); font-weight: 500; }
  thead th { color: var(--muted); font-weight: 500; font-size: 13px; }
  .badge { display:inline-block; padding:2px 10px; border-radius:999px; font-size:13px; font-weight:600; white-space:nowrap; }
  .badge.ok { color:var(--ok); background:var(--okbg); } .badge.warn { color:var(--warn); background:var(--warnbg); }
  .badge.fail { color:var(--fail); background:var(--failbg); } .badge.muted { color:var(--muted); background:var(--line); }
  .status { font-size: 15px; padding: 6px 14px; }
  .nowrap { white-space: nowrap; }
  .mono { font-family: ui-monospace, "Cascadia Code", Consolas, monospace; font-size: 13px; }
  footer { margin-top: 28px; color: var(--muted); font-size: 13px; }
  @media print { body { background:#fff; } }
</style>
</head>
<body>
<main>
  <header>
    <div>
      <p class="sub">$org &middot; Informe de auditoría</p>
      <h1>$title</h1>
      <p class="sub">$(& $h $Operation.StartedAt)</p>
    </div>
    <span class="badge status $statusClass">$(& $h (Get-LcStatusLabel $status))</span>
  </header>

  <h2>Usuario</h2>
  <table class="kv">$($targetRows -join '')</table>

  $snapshotHtml

  <h2>Pasos ejecutados</h2>
  <table>
    <thead><tr><th>Hora</th><th>Paso</th><th>Estado</th><th>Detalle</th></tr></thead>
    <tbody>$($stepRows -join '')</tbody>
  </table>

  <h2>Trazabilidad</h2>
  <table class="kv">
    <tr><th>ID de operación</th><td class="mono">$(& $h $Operation.OperationId)</td></tr>
    <tr><th>Ticket</th><td>$(& $h $Operation.Ticket)</td></tr>
    <tr><th>Ejecutado por</th><td>$(& $h $Operation.Operator) en $(& $h $Operation.Computer)</td></tr>
    <tr><th>Modo</th><td>$(& $h $Operation.Mode)</td></tr>
    <tr><th>Inicio / fin</th><td>$(& $h $Operation.StartedAt) &rarr; $(& $h $Operation.FinishedAt)</td></tr>
    <tr><th>Hash en el log de auditoría</th><td class="mono">$(& $h $LogHash)</td></tr>
  </table>

  <footer>Generado automáticamente por UserLifecycle. Las contraseñas nunca se incluyen en los informes.</footer>
</main>
</body>
</html>
"@
}

function Complete-LcOperation {
    # Cierra la operación: calcula el estado, escribe el log encadenado y los informes.
    param([System.Collections.IDictionary]$Operation)

    $Operation.Status = Get-LcOperationStatus $Operation
    $Operation.FinishedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')

    $reportDir = Join-Path $script:Lc.Config.Audit.Path 'reports'
    if (-not (Test-Path -LiteralPath $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }

    $who = 'desconocido'
    if ($Operation.Target.SamAccountName) { $who = $Operation.Target.SamAccountName }
    $safeWho = ($who -replace '[^A-Za-z0-9\.\-_]', '_')
    $baseName = '{0}_{1}_{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Operation.Type, $safeWho
    $htmlFile = "$baseName.html"

    $logHash = Write-LcAuditLog -Operation $Operation -ReportFile $htmlFile

    $enc = New-Object System.Text.UTF8Encoding($false)
    $json = [ordered]@{}
    foreach ($k in $Operation.Keys) { if ($k -ne 'Aborted') { $json[$k] = $Operation[$k] } }
    $json.LogHash = $logHash
    [System.IO.File]::WriteAllText((Join-Path $reportDir "$baseName.json"), ($json | ConvertTo-Json -Depth 10), $enc)
    [System.IO.File]::WriteAllText((Join-Path $reportDir $htmlFile), (ConvertTo-LcReportHtml -Operation $Operation -LogHash $logHash), $enc)

    return [pscustomobject]@{
        Status     = $Operation.Status
        ReportFile = $htmlFile
        ReportPath = (Join-Path $reportDir $htmlFile)
        LogHash    = $logHash
    }
}
