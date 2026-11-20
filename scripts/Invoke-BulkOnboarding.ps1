<#
    Bulk onboarding from a CSV (columns: Nombre, Apellidos, Departamento, Puesto, Responsable,
    NumeroEmpleado, FechaFin, Ticket - English names GivenName, Surname... also work).

        .\scripts\Invoke-BulkOnboarding.ps1 -CsvPath .\examples\altas.csv -WhatIf   # dry run
        .\scripts\Invoke-BulkOnboarding.ps1 -CsvPath .\examples\altas.csv

    Initial passwords are shown ONCE on screen and never written to disk.
#>
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$CsvPath, [string]$ConfigPath)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\UserLifecycle') -Force
if ($ConfigPath) { $null = Initialize-Lifecycle -ConfigPath $ConfigPath } else { $null = Initialize-Lifecycle }

$rows = Import-Csv -LiteralPath $CsvPath -Encoding UTF8
$results = $rows | New-LifecycleUser -Confirm:$false -ErrorAction Continue -WhatIf:$WhatIfPreference

if ($WhatIfPreference) {
    $results | Select-Object DisplayName, SamAccountName, OU, CanProceed, @{ n = 'Errors'; e = { $_.Errors -join ' | ' } } | Format-Table -AutoSize
    return
}

$results | ForEach-Object {
    [pscustomobject]@{
        Status          = $_.Status
        User            = $_.SamAccountName
        Name            = $_.DisplayName
        InitialPassword = $(if ($_.InitialPassword) { (New-Object System.Net.NetworkCredential('', $_.InitialPassword)).Password } else { '' })
        Report          = $_.ReportFile
    }
} | Format-Table -AutoSize
Write-Warning 'Hand the passwords over through a secure channel and clear this console (Clear-Host).'
