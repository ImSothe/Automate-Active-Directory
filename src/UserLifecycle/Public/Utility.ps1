function Find-LifecycleUser {
    <#
    .SYNOPSIS
        Busca usuarios por nombre, sAMAccountName, correo o nº de empleado.
    .EXAMPLE
        Find-LifecycleUser garcia
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Search = '', [ValidateRange(1, 200)][int]$Max = 25)

    Assert-LcInitialized
    if ($Search.Length -gt 64) { throw 'Texto de búsqueda demasiado largo.' }
    Find-LcDirUser -Search $Search -Max $Max |
        Select-Object SamAccountName, DisplayName, Department, Title, Enabled, UserPrincipalName, OU, Description
}

function Get-LifecycleAuditLog {
    <#
    .SYNOPSIS
        Lee el log de auditoría (una entrada por operación), de la más reciente a la más antigua.
    .EXAMPLE
        Get-LifecycleAuditLog -Last 10 | Format-Table StartedAt, Type, Status, Operator, @{n='Usuario';e={$_.Target.SamAccountName}}
    #>
    [CmdletBinding()]
    param(
        [int]$Last = 50,
        [ValidateSet('Onboarding', 'Offboarding', 'CloudProvisioning')][string]$Type,
        [string]$SamAccountName
    )

    Assert-LcInitialized
    $path = Get-LcAuditLogPath
    if (-not (Test-Path -LiteralPath $path)) { return }
    $entries = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($line in (Read-LcLogLines $path)) {
        $n++
        if (-not $line.Trim()) { continue }
        try { $e = $line | ConvertFrom-Json } catch { Write-Warning "Línea $n del log no es JSON válido."; continue }
        if ($Type -and $e.Type -ne $Type) { continue }
        if ($SamAccountName -and $e.Target.SamAccountName -ne $SamAccountName) { continue }
        $e | Add-Member -NotePropertyName Line -NotePropertyValue $n
        [void]$entries.Add($e)
    }
    $count = $entries.Count
    $from = [Math]::Max(0, $count - $Last)
    for ($i = $count - 1; $i -ge $from; $i--) { $entries[$i] }
}

function Test-LifecycleAuditLog {
    <#
    .SYNOPSIS
        Verifica la cadena de hashes del log de auditoría. Detecta líneas editadas, borradas o insertadas.
    .DESCRIPTION
        Cada entrada guarda el SHA-256 de la línea anterior (PrevHash). Si alguien modifica una línea,
        la siguiente deja de cuadrar. Para proteger también la última línea, guarda el LastHash
        devuelto en un sitio externo (ticket, SIEM, correo) o reenvía el log a un SIEM.
    #>
    [CmdletBinding()]
    param()

    Assert-LcInitialized
    $path = Get-LcAuditLogPath
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Valid = $true; Entries = 0; BrokenAtLine = $null; LastHash = $null; Message = 'El log está vacío.' }
    }
    $expected = 'GENESIS'
    $n = 0; $entries = 0
    foreach ($line in (Read-LcLogLines $path)) {
        $n++
        if (-not $line.Trim()) { continue }
        $prevHash = $null
        try { $prevHash = ($line | ConvertFrom-Json).PrevHash } catch { $prevHash = $null }  # línea no JSON => cadena rota
        if ($prevHash -ne $expected) {
            return [pscustomobject]@{ Valid = $false; Entries = $entries; BrokenAtLine = $n; LastHash = $null; Message = "Cadena rota en la línea $n`: el log ha sido modificado (o la línea anterior se editó/borró)." }
        }
        $expected = Get-LcSha256 $line
        $entries++
    }
    [pscustomobject]@{ Valid = $true; Entries = $entries; BrokenAtLine = $null; LastHash = $expected; Message = "Log íntegro: $entries entradas verificadas." }
}

function Reset-LifecycleLab {
    <#
    .SYNOPSIS
        Restaura el directorio simulado del modo Lab a su estado inicial (solo modo Lab).
    .EXAMPLE
        Reset-LifecycleLab -IncludeAudit -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([switch]$IncludeAudit)

    Assert-LcInitialized
    if ($script:Lc.Mode -ne 'Lab') { throw 'Reset-LifecycleLab solo funciona en modo Lab.' }
    if (-not $PSCmdlet.ShouldProcess($script:Lc.Config.Lab.DataPath, 'Restaurar el laboratorio')) { return }
    Save-LcLab (New-LcLabSeed)
    if ($IncludeAudit) {
        $auditPath = $script:Lc.Config.Audit.Path
        Get-ChildItem -LiteralPath $auditPath -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force
    }
    Write-Verbose 'Laboratorio restaurado.'
}
