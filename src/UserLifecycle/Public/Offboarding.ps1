function New-LcOffboardingPlan {
    param([string]$Identity)

    $cfg = $script:Lc.Config
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $Identity = ([string]$Identity).Trim()

    $plan = [ordered]@{
        SamAccountName    = $Identity
        UserPrincipalName = $null
        DisplayName       = $null
        Department        = $null
        Title             = $null
        Enabled           = $null
        CurrentOU         = $null
        TargetOU          = $cfg.Domain.ArchiveOU
        GroupsToRemove    = @()
        SharesToRevoke    = @()
        CloudUserId       = $null
        LicensesToRemove  = @()
        Mode              = $script:Lc.Mode
        Errors            = $errors
        Warnings          = $warnings
        CanProceed        = $false
    }

    if (-not (Test-LcSamAccountName $Identity)) {
        $errors.Add("Nombre de usuario no válido: '$Identity'.")
        $plan.Errors = @($errors); $plan.Warnings = @($warnings)
        return $plan
    }

    $user = Get-LcDirUser $Identity
    if (-not $user) {
        $errors.Add("No existe el usuario '$Identity'.")
        $plan.Errors = @($errors); $plan.Warnings = @($warnings)
        return $plan
    }

    $plan.SamAccountName = $user.SamAccountName
    $plan.UserPrincipalName = $user.UserPrincipalName
    $plan.DisplayName = $user.DisplayName
    $plan.Department = $user.Department
    $plan.Title = $user.Title
    $plan.Enabled = $user.Enabled
    $plan.CurrentOU = $user.OU
    $plan.GroupsToRemove = @($user.MemberOf)

    # Cuentas que nunca deben pasar por una baja automatizada
    $rid = 0
    if ($user.Sid -match '-(\d+)$') { $rid = [int]$Matches[1] }
    if ($rid -eq 500 -or $rid -eq 502) { $errors.Add("BLOQUEADO: '$($user.SamAccountName)' es una cuenta integrada del dominio (RID $rid).") }
    $me = [System.Environment]::UserName
    if ($user.SamAccountName -eq $me) { $errors.Add('BLOQUEADO: no puedes darte de baja a ti mismo con esta herramienta.') }
    if ($user.AdminCount -eq 1) { $warnings.Add('La cuenta tiene adminCount=1 (tiene o tuvo privilegios). Revisa también sus cuentas administrativas, credenciales de servicio y accesos PAM.') }
    foreach ($g in $user.MemberOf) {
        $dirGroup = Get-LcDirGroup $g.DistinguishedName
        if ($dirGroup -and $dirGroup.Privileged) { $warnings.Add("Es miembro del grupo privilegiado '$($g.Name)': se le quitará, revisa qué más administraba.") }
    }
    if (-not $user.Enabled -and $user.OU -eq $cfg.Domain.ArchiveOU) {
        $warnings.Add('La cuenta ya está deshabilitada y en la OU de bajas. Se volverán a aplicar los pasos (operación idempotente).')
    }

    if ($cfg.Offboarding.RemoveShareAccess) { $plan.SharesToRevoke = @(Get-LcAllConfiguredShares) }

    if (Test-LcCloudEnabled) {
        try {
            $cloud = Get-LcCloudUser $user.UserPrincipalName
            if ($cloud) {
                $plan.CloudUserId = $cloud.Id
                $skus = Get-LcCloudSkus
                $plan.LicensesToRemove = @(foreach ($id in $cloud.Licenses) {
                        $match = $skus | Where-Object { $_.SkuId -eq $id } | Select-Object -First 1
                        if ($match) { $match.SkuPartNumber } else { $id }
                    })
            }
            else { $warnings.Add('El usuario no existe en Entra ID: se omiten los pasos de Microsoft 365.') }
        }
        catch { $warnings.Add("No se pudo consultar Entra ID: $($_.Exception.Message)") }
    }

    $plan.Errors = @($errors)
    $plan.Warnings = @($warnings)
    $plan.CanProceed = ($errors.Count -eq 0)
    return $plan
}

function Get-LifecycleOffboardingPlan {
    <#
    .SYNOPSIS
        Muestra qué haría una baja SIN cambiar nada (grupos a quitar, licencias, OU destino, avisos).
    .EXAMPLE
        Get-LifecycleOffboardingPlan -Identity aruiz
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('SamAccountName', 'Usuario')][string]$Identity)
    begin { Assert-LcInitialized }
    process { [pscustomobject](New-LcOffboardingPlan $Identity) }
}

function Disable-LifecycleUser {
    <#
    .SYNOPSIS
        BAJA: deshabilita la cuenta, cambia la contraseña, revoca sesiones de Microsoft 365, quita
        grupos, permisos de carpetas y licencias, y mueve el usuario a la OU de bajas.
    .DESCRIPTION
        Antes de tocar nada guarda una instantánea (grupos, OU, licencias) en el informe de auditoría,
        para poder justificar o revertir la baja. La cuenta NO se borra: se conserva para retención.
        Pide confirmación por defecto (ConfirmImpact High). Usa -Confirm:$false en automatizaciones.
    .EXAMPLE
        Disable-LifecycleUser -Identity aruiz -Reason 'Fin de contrato' -Ticket 'RRHH-2001'
    .EXAMPLE
        Import-Csv .\examples\bajas.csv | Disable-LifecycleUser -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('SamAccountName', 'Usuario')][string]$Identity,
        [Parameter(ValueFromPipelineByPropertyName)][Alias('Motivo')][string]$Reason,
        [Parameter(ValueFromPipelineByPropertyName)][string]$Ticket
    )
    begin { Assert-LcInitialized }
    process {
        $cfg = $script:Lc.Config
        $Reason = (([string]$Reason) -replace '[\r\n\t]+', ' ').Trim()
        if ($Reason.Length -gt 200) { $Reason = $Reason.Substring(0, 200) }
        $Ticket = ([string]$Ticket).Trim()
        $plan = New-LcOffboardingPlan $Identity
        if ($Ticket -and -not (Test-LcSimpleId $Ticket 32)) {
            $plan.Errors = @($plan.Errors) + "Ticket no válido: '$Ticket'."
            $plan.CanProceed = $false
        }
        $inputData = [ordered]@{ Identity = $Identity; Reason = $Reason }

        if (-not $plan.CanProceed) {
            if ($WhatIfPreference) { return [pscustomobject]$plan }
            $op = New-LcOperation -Type 'Offboarding' -InputData $inputData -Ticket $Ticket
            $op.Status = 'Rejected'
            $op.Target = [ordered]@{ SamAccountName = $plan.SamAccountName; DisplayName = $plan.DisplayName }
            foreach ($e in $plan.Errors) { Add-LcStep $op 'Validación previa' 'Failed' $e }
            $done = Complete-LcOperation $op
            Write-Error -Message ("Baja rechazada para '{0}': {1}" -f $Identity, ($plan.Errors -join ' | ')) -Category InvalidData
            return [pscustomobject]@{ Status = 'Rejected'; SamAccountName = $plan.SamAccountName; DisplayName = $plan.DisplayName; Errors = $plan.Errors; Steps = @($op.Steps); ReportFile = $done.ReportFile; ReportPath = $done.ReportPath; OperationId = $op.OperationId }
        }

        $summary = "Dar de baja a '$($plan.SamAccountName)' ($($plan.DisplayName)): deshabilitar, quitar $(@($plan.GroupsToRemove).Count) grupos y $(@($plan.LicensesToRemove).Count) licencias, mover a $($plan.TargetOU)"
        if (-not $PSCmdlet.ShouldProcess($plan.SamAccountName, $summary)) { return [pscustomobject]$plan }

        $sam = $plan.SamAccountName
        $user = Get-LcDirUser $sam
        $op = New-LcOperation -Type 'Offboarding' -InputData $inputData -Ticket $Ticket
        $op.Target = [ordered]@{
            SamAccountName    = $sam
            UserPrincipalName = $plan.UserPrincipalName
            DisplayName       = $plan.DisplayName
            Department        = $plan.Department
            Title             = $plan.Title
            Reason            = $Reason
            TargetOU          = $plan.TargetOU
        }
        $op.Snapshot = [ordered]@{
            Enabled     = $user.Enabled
            OU          = $user.OU
            Groups      = @($user.MemberOf | ForEach-Object { $_.Name })
            Licenses    = @($plan.LicensesToRemove)
            Description = $user.Description
            Manager     = $user.Manager
        }
        foreach ($w in $plan.Warnings) { Add-LcStep $op 'Nota del plan' 'OK' $w }

        # 1) Cortar el acceso on-premises
        try { Disable-LcDirUser $sam; Add-LcStep $op 'Deshabilitar cuenta en Active Directory' 'OK' }
        catch { Add-LcStep $op 'Deshabilitar cuenta en Active Directory' 'Failed' $_.Exception.Message }

        try {
            Reset-LcDirPassword -SamAccountName $sam -Password (ConvertTo-LcSecureString (New-LcPassword 32))
            Add-LcStep $op 'Cambiar contraseña' 'OK' 'Nueva contraseña aleatoria de 32 caracteres (no se guarda ni se muestra).'
        }
        catch { Add-LcStep $op 'Cambiar contraseña' 'Failed' $_.Exception.Message }

        # 2) Cortar el acceso en la nube lo antes posible
        if (Test-LcCloudEnabled) {
            try {
                if (Invoke-LcDeltaSync) { Add-LcStep $op 'Lanzar sincronización delta (Entra Connect)' 'OK' 'Propaga la cuenta deshabilitada a Entra ID.' }
            }
            catch { Add-LcStep $op 'Lanzar sincronización delta (Entra Connect)' 'Warning' $_.Exception.Message }

            if ($plan.CloudUserId -and $cfg.Graph.RevokeSessionsOnOffboarding) {
                try {
                    Revoke-LcCloudSession -UserId $plan.CloudUserId
                    Add-LcStep $op 'Revocar sesiones de Microsoft 365' 'OK' 'Tokens de actualización invalidados (revokeSignInSessions).'
                }
                catch { Add-LcStep $op 'Revocar sesiones de Microsoft 365' 'Failed' $_.Exception.Message }
            }
        }

        # 3) Quitar accesos
        foreach ($g in $plan.GroupsToRemove) {
            try {
                Remove-LcDirGroupMember -GroupDistinguishedName $g.DistinguishedName -SamAccountName $sam
                Add-LcStep $op "Quitar del grupo $($g.Name)" 'OK'
            }
            catch { Add-LcStep $op "Quitar del grupo $($g.Name)" 'Failed' $_.Exception.Message }
        }

        foreach ($path in $plan.SharesToRevoke) {
            try {
                $removed = Revoke-LcFolderAccess -Path $path -Sid $user.Sid
                if ($removed -gt 0) { Add-LcStep $op "Quitar permisos NTFS en $path" 'OK' "$removed entrada(s) eliminada(s)" }
            }
            catch { Add-LcStep $op "Quitar permisos NTFS en $path" 'Warning' $_.Exception.Message }
        }
        if ($cfg.HomeFolder.Enabled) {
            $homePath = $cfg.HomeFolder.Root.TrimEnd('\', '/') + '\' + $sam
            Add-LcStep $op 'Carpeta personal' 'Skipped' "Se conserva $homePath para revisión y retención de datos."
        }

        if ((Test-LcCloudEnabled) -and $plan.CloudUserId -and $cfg.Graph.RemoveLicensesOnOffboarding) {
            if (@($plan.LicensesToRemove).Count -eq 0) {
                Add-LcStep $op 'Liberar licencias de Microsoft 365' 'Skipped' 'No tenía licencias asignadas directamente.'
            }
            else {
                try {
                    $cloud = Get-LcCloudUser $plan.UserPrincipalName
                    Remove-LcCloudLicense -UserId $plan.CloudUserId -SkuIds @($cloud.Licenses)
                    Add-LcStep $op 'Liberar licencias de Microsoft 365' 'OK' (@($plan.LicensesToRemove) -join ', ')
                }
                catch { Add-LcStep $op 'Liberar licencias de Microsoft 365' 'Failed' $_.Exception.Message }
            }
        }

        # 4) Marcar y archivar
        $parts = @("$($cfg.Offboarding.DescriptionPrefix) $(Get-Date -Format 'yyyy-MM-dd')")
        if ($Ticket) { $parts += $Ticket }
        if ($Reason) { $parts += $Reason }
        $parts += "por $(Get-LcOperator)"
        $description = $parts -join ' | '
        if ($description.Length -gt 1024) { $description = $description.Substring(0, 1024) }
        try { Set-LcDirDescription -SamAccountName $sam -Description $description; Add-LcStep $op 'Anotar la baja en la descripción' 'OK' $description }
        catch { Add-LcStep $op 'Anotar la baja en la descripción' 'Failed' $_.Exception.Message }

        if ($plan.CurrentOU -ne $plan.TargetOU) {
            try {
                $newDn = Move-LcDirUser -SamAccountName $sam -TargetOU $plan.TargetOU
                Add-LcStep $op 'Mover a la OU de bajas' 'OK' $newDn
            }
            catch { Add-LcStep $op 'Mover a la OU de bajas' 'Failed' $_.Exception.Message }
        }
        else { Add-LcStep $op 'Mover a la OU de bajas' 'Skipped' 'Ya estaba en la OU de bajas.' }

        $done = Complete-LcOperation $op
        if ($done.Status -ne 'Success') { Write-Warning "Baja de '$sam' completada con avisos. Revisa el informe: $($done.ReportPath)" }

        [pscustomobject]@{
            Status         = $done.Status
            SamAccountName = $sam
            DisplayName    = $plan.DisplayName
            Errors         = @()
            Warnings       = $plan.Warnings
            Steps          = @($op.Steps)
            ReportFile     = $done.ReportFile
            ReportPath     = $done.ReportPath
            OperationId    = $op.OperationId
        }
    }
}
