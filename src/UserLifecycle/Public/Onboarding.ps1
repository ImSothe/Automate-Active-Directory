function Get-LcGroupsFor {
    # Grupos = base + departamento + reglas por puesto (sin duplicados, en ese orden).
    param([System.Collections.IDictionary]$DepartmentConfig, [string]$Title)
    $all = @($script:Lc.Config.BaseGroups) + @($DepartmentConfig.Groups) + @(Get-LcTitleRules $Title | ForEach-Object { $_.Groups })
    $seen = @{}
    @(foreach ($g in $all) {
            if ($g -and -not $seen.ContainsKey($g.ToLowerInvariant())) { $seen[$g.ToLowerInvariant()] = $true; $g }
        })
}

function Get-LcLicensesFor {
    # La primera regla de puesto que defina Licenses sustituye a las del departamento (p. ej. becarios).
    param([System.Collections.IDictionary]$DepartmentConfig, [string]$Title)
    foreach ($r in (Get-LcTitleRules $Title)) {
        if ($null -ne $r.Licenses) { return @($r.Licenses | Where-Object { $_ }) }
    }
    return @($DepartmentConfig.Licenses)
}

function New-LcOnboardingPlan {
    param(
        [string]$GivenName, [string]$Surname, [string]$Department, [string]$Title,
        [string]$EmployeeId, [string]$Manager, [string]$EndDate, [string]$Ticket
    )

    $cfg = $script:Lc.Config
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $GivenName = Format-LcPersonName $GivenName
    $Surname = Format-LcPersonName $Surname
    $Title = ($Title -replace '\s+', ' ').Trim()
    $EmployeeId = ([string]$EmployeeId).Trim()
    $Manager = ([string]$Manager).Trim()
    $Ticket = ([string]$Ticket).Trim()

    # 1) Validación de formato (antes de consultar el directorio)
    if (-not (Test-LcPersonName $GivenName)) { $errors.Add("Nombre no válido: '$GivenName'. Solo letras, espacios, guiones, puntos y apóstrofos.") }
    if (-not (Test-LcPersonName $Surname)) { $errors.Add("Apellidos no válidos: '$Surname'. Solo letras, espacios, guiones, puntos y apóstrofos.") }
    if (-not (Test-LcTitle $Title)) { $errors.Add("Puesto no válido: '$Title'.") }
    if ($EmployeeId -and -not (Test-LcSimpleId $EmployeeId 16)) { $errors.Add("Nº de empleado no válido: '$EmployeeId' (letras, números y guiones, máx. 16).") }
    if ($Ticket -and -not (Test-LcSimpleId $Ticket 32)) { $errors.Add("Ticket no válido: '$Ticket'.") }
    if ($Manager -and -not (Test-LcSamAccountName $Manager)) { $errors.Add("Responsable no válido: '$Manager' (indica su nombre de usuario, p. ej. lmartinez).") }

    $endDateValue = $null
    try {
        $endDateValue = ConvertTo-LcDate $EndDate
        if ($endDateValue -and $endDateValue -lt (Get-Date).Date) { $errors.Add('La fecha de fin de contrato ya ha pasado.') }
    }
    catch { $errors.Add($_.Exception.Message) }

    $dept = Get-LcDepartment $Department
    if (-not $dept) {
        $errors.Add("Departamento desconocido: '$Department'. Válidos: $((@($cfg.Departments | ForEach-Object { $_.Name })) -join ', ').")
    }

    $plan = [ordered]@{
        GivenName         = $GivenName
        Surname           = $Surname
        DisplayName       = "$GivenName $Surname"
        Department        = $Department
        Title             = $Title
        EmployeeId        = $EmployeeId
        Manager           = $Manager
        ManagerDn         = $null
        EndDate           = $(if ($endDateValue) { $endDateValue.ToString('yyyy-MM-dd') } else { $null })
        Ticket            = $Ticket
        SamAccountName    = $null
        UserPrincipalName = $null
        Mail              = $null
        OU                = $null
        Groups            = @()
        HomeFolder        = $null
        Shares            = @()
        Licenses          = @()
        UsageLocation     = $(if ($cfg.Graph.Enabled) { $cfg.Graph.UsageLocation } else { $null })
        Mode              = $script:Lc.Mode
        Errors            = $errors
        Warnings          = $warnings
        CanProceed        = $false
    }

    if ($errors.Count -gt 0) {
        $plan.Errors = @($errors); $plan.Warnings = @($warnings)
        return $plan
    }

    # 2) Resolución contra el directorio
    $plan.OU = $dept.OU
    $plan.Groups = @(Get-LcGroupsFor $dept $Title)
    $plan.Licenses = @(Get-LcLicensesFor $dept $Title)
    $plan.Shares = @(foreach ($s in $dept.Shares) { [pscustomobject]@{ Path = $s.Path; Rights = $s.Rights } })

    # Nombre de cuenta único (sAMAccountName + UPN + correo, y también en Entra ID si Graph está activo)
    $checkCloud = (Test-LcCloudEnabled) -and $script:Lc.Mode -ne 'Lab'
    foreach ($candidate in (Get-LcSamCandidates -GivenName $GivenName -Surname $Surname -Pattern $cfg.Naming.Pattern -MaxLength ([int]$cfg.Naming.MaxLength))) {
        $upn = "$candidate@$($cfg.Domain.UpnSuffix)"
        $mail = "$candidate@$($cfg.Domain.EmailDomain)"
        if (Test-LcDirAccountNameTaken -SamAccountName $candidate -UserPrincipalName $upn -Mail $mail) { continue }
        if ($checkCloud) {
            try { if (Get-LcCloudUser $upn) { continue } }
            catch { $warnings.Add("No se pudo comprobar el UPN en Entra ID: $($_.Exception.Message)") }
        }
        $plan.SamAccountName = $candidate
        $plan.UserPrincipalName = $upn
        $plan.Mail = $mail
        break
    }
    if (-not $plan.SamAccountName) { $errors.Add('No se ha encontrado un nombre de cuenta libre.') }
    $firstCandidate = @(Get-LcSamCandidates -GivenName $GivenName -Surname $Surname -Pattern $cfg.Naming.Pattern -MaxLength ([int]$cfg.Naming.MaxLength))[0]
    if ($plan.SamAccountName -and $plan.SamAccountName -ne $firstCandidate) {
        $warnings.Add("'$firstCandidate' ya existe: se usará '$($plan.SamAccountName)'.")
    }

    if (-not (Test-LcDirOU $dept.OU)) { $errors.Add("La OU del departamento no existe: $($dept.OU)") }

    foreach ($gName in $plan.Groups) {
        $g = Get-LcDirGroup $gName
        if (-not $g) { $errors.Add("El grupo '$gName' no existe en el directorio."); continue }
        if ($g.Privileged) {
            # Control de seguridad: esta herramienta jamás concede privilegios de administración.
            $errors.Add("BLOQUEADO: '$gName' es un grupo privilegiado (SID/adminCount). Los accesos privilegiados no se conceden desde el onboarding.")
        }
    }

    if ($Manager) {
        $m = Get-LcDirUser $Manager
        if (-not $m) { $errors.Add("No existe el responsable '$Manager'.") }
        elseif (-not $m.Enabled) { $errors.Add("El responsable '$Manager' está deshabilitado.") }
        else { $plan.ManagerDn = $m.DistinguishedName }
    }

    if (Test-LcDirEmployeeIdTaken $EmployeeId) { $errors.Add("Ya existe un usuario con el nº de empleado '$EmployeeId'.") }

    if ($cfg.HomeFolder.Enabled -and $plan.SamAccountName) {
        $plan.HomeFolder = [pscustomobject]@{ Path = ($cfg.HomeFolder.Root.TrimEnd('\', '/') + '\' + $plan.SamAccountName); Drive = $cfg.HomeFolder.Drive; Rights = $cfg.HomeFolder.Rights }
        if (Test-LcFolderExists $plan.HomeFolder.Path) { $warnings.Add("La carpeta personal $($plan.HomeFolder.Path) ya existe: se reutilizará.") }
    }
    foreach ($s in $plan.Shares) {
        if (-not (Test-LcFolderExists $s.Path)) { $warnings.Add("No se puede acceder a la carpeta compartida $($s.Path).") }
    }

    # Licencias: comprobar que existen y que quedan unidades libres
    if ((Test-LcCloudEnabled) -and $plan.Licenses.Count -gt 0) {
        try {
            $skus = Get-LcCloudSkus
            foreach ($lic in $plan.Licenses) {
                $sku = $skus | Where-Object { $_.SkuPartNumber -eq $lic } | Select-Object -First 1
                if (-not $sku) { $warnings.Add("La licencia '$lic' no existe en el tenant.") }
                elseif ($sku.Available -le 0) { $warnings.Add("No quedan licencias '$lic' libres ($($sku.Consumed)/$($sku.Enabled) en uso). El alta se hará, pero esa licencia quedará pendiente.") }
            }
        }
        catch { $warnings.Add("No se pudo consultar el inventario de licencias: $($_.Exception.Message)") }
    }

    $plan.Errors = @($errors)
    $plan.Warnings = @($warnings)
    $plan.CanProceed = ($errors.Count -eq 0)
    return $plan
}

function Get-LifecycleOnboardingPlan {
    <#
    .SYNOPSIS
        Calcula qué haría un alta SIN cambiar nada (cuenta, OU, grupos, carpetas, licencias, avisos).
    .EXAMPLE
        Get-LifecycleOnboardingPlan -GivenName 'Juan' -Surname 'García López' -Department Ventas -Title 'Comercial'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('Nombre', 'FirstName')][string]$GivenName,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('Apellidos', 'LastName')][string]$Surname,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('Departamento')][string]$Department,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('Puesto', 'JobTitle')][string]$Title,
        [Parameter(ValueFromPipelineByPropertyName)][Alias('NumeroEmpleado')][string]$EmployeeId,
        [Parameter(ValueFromPipelineByPropertyName)][Alias('Responsable')][string]$Manager,
        [Parameter(ValueFromPipelineByPropertyName)][Alias('FechaFin')][string]$EndDate,
        [Parameter(ValueFromPipelineByPropertyName)][string]$Ticket
    )
    begin { Assert-LcInitialized }
    process {
        $plan = New-LcOnboardingPlan -GivenName $GivenName -Surname $Surname -Department $Department -Title $Title -EmployeeId $EmployeeId -Manager $Manager -EndDate $EndDate -Ticket $Ticket
        [pscustomobject]$plan
    }
}

function Invoke-LcCloudOnboardingSteps {
    # Pasos de Microsoft 365 compartidos por el alta y por Invoke-LifecycleCloudProvisioning.
    param([System.Collections.IDictionary]$Operation, [string]$UserPrincipalName, [string[]]$Licenses, [int]$WaitSeconds = -1)

    $g = $script:Lc.Config.Graph
    try {
        if (Invoke-LcDeltaSync) { Add-LcStep $Operation 'Lanzar sincronización delta (Entra Connect)' 'OK' $g.DeltaSyncServer }
    }
    catch { Add-LcStep $Operation 'Lanzar sincronización delta (Entra Connect)' 'Warning' $_.Exception.Message }

    $wait = if ($WaitSeconds -ge 0) { $WaitSeconds } else { [int]$g.SyncWaitSeconds }
    try { $cloudUser = Wait-LcCloudUser -UserPrincipalName $UserPrincipalName -TimeoutSeconds $wait -PollSeconds ([int]$g.SyncPollSeconds) }
    catch {
        Add-LcStep $Operation 'Conectar con Microsoft Graph' 'Failed' $_.Exception.Message
        return
    }
    if (-not $cloudUser) {
        Add-LcStep $Operation 'Sincronización con Entra ID' 'Pending' "El usuario aún no aparece en Entra ID (esperado $wait s). Reintenta más tarde con: Invoke-LifecycleCloudProvisioning -Identity $($UserPrincipalName.Split('@')[0])"
        return
    }
    Add-LcStep $Operation 'Usuario visible en Entra ID' 'OK' "Id $($cloudUser.Id)"

    if ($cloudUser.UsageLocation -ne $g.UsageLocation) {
        try {
            Set-LcCloudUsageLocation -UserId $cloudUser.Id -UsageLocation $g.UsageLocation
            Add-LcStep $Operation 'Ubicación de uso (usageLocation)' 'OK' $g.UsageLocation
        }
        catch {
            Add-LcStep $Operation 'Ubicación de uso (usageLocation)' 'Failed' $_.Exception.Message
            return
        }
    }

    if (@($Licenses).Count -eq 0) {
        Add-LcStep $Operation 'Licencias de Microsoft 365' 'Skipped' 'No hay licencias configuradas para este departamento/puesto.'
        return
    }

    try { $skus = Get-LcCloudSkus }
    catch {
        Add-LcStep $Operation 'Inventario de licencias' 'Failed' $_.Exception.Message
        return
    }
    foreach ($lic in $Licenses) {
        $stepName = "Asignar licencia $lic"
        $sku = $skus | Where-Object { $_.SkuPartNumber -eq $lic } | Select-Object -First 1
        if (-not $sku) { Add-LcStep $Operation $stepName 'Failed' 'El SKU no existe en el tenant.'; continue }
        if (@($cloudUser.Licenses) -contains $sku.SkuId) { Add-LcStep $Operation $stepName 'OK' 'Ya estaba asignada.'; continue }
        if ($sku.Available -le 0) {
            Add-LcStep $Operation $stepName 'Warning' "Sin unidades libres ($($sku.Consumed)/$($sku.Enabled)). Libera o compra licencias y reintenta."
            continue
        }
        try {
            Add-LcCloudLicense -UserId $cloudUser.Id -SkuId $sku.SkuId
            Add-LcStep $Operation $stepName 'OK' "Quedan $($sku.Available - 1) libres."
        }
        catch { Add-LcStep $Operation $stepName 'Failed' $_.Exception.Message }
    }
}

function New-LifecycleUser {
    <#
    .SYNOPSIS
        ALTA: crea el usuario en AD, lo mete en su OU y grupos, le da acceso a carpetas,
        le asigna licencias de Microsoft 365 y genera un informe de auditoría.
    .DESCRIPTION
        Antes de cambiar nada se calcula y valida un plan completo (Get-LifecycleOnboardingPlan).
        Si el plan tiene errores (grupo privilegiado, OU inexistente, responsable desconocido...),
        no se crea nada y el intento queda registrado como 'Rejected' en el log de auditoría.

        Devuelve la contraseña inicial como SecureString (InitialPassword). Para verla una vez:
          [System.Net.NetworkCredential]::new('', $r.InitialPassword).Password
    .EXAMPLE
        New-LifecycleUser -GivenName 'Juan' -Surname 'García López' -Department Ventas -Title 'Comercial' -Ticket 'RRHH-1234'
    .EXAMPLE
        Import-Csv .\examples\altas.csv | New-LifecycleUser -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('Nombre', 'FirstName')][string]$GivenName,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('Apellidos', 'LastName')][string]$Surname,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('Departamento')][string]$Department,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('Puesto', 'JobTitle')][string]$Title,
        [Parameter(ValueFromPipelineByPropertyName)][Alias('NumeroEmpleado')][string]$EmployeeId,
        [Parameter(ValueFromPipelineByPropertyName)][Alias('Responsable')][string]$Manager,
        [Parameter(ValueFromPipelineByPropertyName)][Alias('FechaFin')][string]$EndDate,
        [Parameter(ValueFromPipelineByPropertyName)][string]$Ticket,
        # Segundos a esperar a que Entra Connect sincronice el usuario (-1 = valor de la configuración)
        [int]$CloudWaitSeconds = -1
    )
    begin { Assert-LcInitialized }
    process {
        $cfg = $script:Lc.Config
        $plan = New-LcOnboardingPlan -GivenName $GivenName -Surname $Surname -Department $Department -Title $Title -EmployeeId $EmployeeId -Manager $Manager -EndDate $EndDate -Ticket $Ticket
        $inputData = [ordered]@{ GivenName = $GivenName; Surname = $Surname; Department = $Department; Title = $Title; EmployeeId = $EmployeeId; Manager = $Manager; EndDate = $EndDate }

        if (-not $plan.CanProceed) {
            if ($WhatIfPreference) { return [pscustomobject]$plan }
            $op = New-LcOperation -Type 'Onboarding' -InputData $inputData -Ticket $plan.Ticket
            $op.Status = 'Rejected'
            $op.Target = [ordered]@{ SamAccountName = $plan.SamAccountName; DisplayName = $plan.DisplayName; Department = $Department; Title = $plan.Title }
            foreach ($e in $plan.Errors) { Add-LcStep $op 'Validación previa' 'Failed' $e }
            $done = Complete-LcOperation $op
            Write-Error -Message ("Alta rechazada para '{0}': {1}" -f $plan.DisplayName, ($plan.Errors -join ' | ')) -Category InvalidData
            return [pscustomobject]@{
                Status = 'Rejected'; SamAccountName = $null; UserPrincipalName = $null; DisplayName = $plan.DisplayName
                InitialPassword = $null; Errors = $plan.Errors; Warnings = $plan.Warnings; Steps = @($op.Steps); ReportFile = $done.ReportFile; ReportPath = $done.ReportPath; OperationId = $op.OperationId
            }
        }

        $summary = "Crear '$($plan.SamAccountName)' ($($plan.DisplayName)) en $($plan.OU); grupos: $($plan.Groups -join ', '); licencias: $($plan.Licenses -join ', ')"
        if (-not $PSCmdlet.ShouldProcess($plan.UserPrincipalName, $summary)) {
            return [pscustomobject]$plan
        }

        $op = New-LcOperation -Type 'Onboarding' -InputData $inputData -Ticket $plan.Ticket
        $op.Target = [ordered]@{
            SamAccountName    = $plan.SamAccountName
            UserPrincipalName = $plan.UserPrincipalName
            DisplayName       = $plan.DisplayName
            Department        = $plan.Department
            Title             = $plan.Title
            EmployeeId        = $plan.EmployeeId
            Manager           = $plan.Manager
            EndDate           = $plan.EndDate
            OU                = $plan.OU
            Groups            = $plan.Groups
            Licenses          = $plan.Licenses
        }
        foreach ($w in $plan.Warnings) { Add-LcStep $op 'Nota del plan' 'OK' $w }

        $secure = ConvertTo-LcSecureString (New-LcPassword ([int]$cfg.Password.Length))
        $description = "Alta $(Get-Date -Format 'yyyy-MM-dd')"
        if ($plan.Ticket) { $description += " | $($plan.Ticket)" }
        $spec = @{
            SamAccountName    = $plan.SamAccountName
            UserPrincipalName = $plan.UserPrincipalName
            GivenName         = $plan.GivenName
            Surname           = $plan.Surname
            DisplayName       = $plan.DisplayName
            Mail              = $plan.Mail
            Department        = $plan.Department
            Title             = $plan.Title
            EmployeeId        = $plan.EmployeeId
            ManagerDn         = $plan.ManagerDn
            EndDate           = $plan.EndDate
            OU                = $plan.OU
            Description       = $description
            HomeDirectory     = $(if ($plan.HomeFolder) { $plan.HomeFolder.Path } else { $null })
        }

        $user = $null
        try {
            $user = New-LcDirUser -Spec $spec -Password $secure
            $detail = $user.DistinguishedName
            if ($plan.EndDate) { $detail += " (caduca tras $($plan.EndDate))" }
            Add-LcStep $op 'Crear cuenta en Active Directory' 'OK' $detail
        }
        catch {
            Add-LcStep $op 'Crear cuenta en Active Directory' 'Failed' $_.Exception.Message
            $op.Aborted = $true
        }

        if (-not $op.Aborted) {
            foreach ($gName in $plan.Groups) {
                try {
                    Add-LcDirGroupMember -GroupName $gName -SamAccountName $user.SamAccountName
                    Add-LcStep $op "Añadir al grupo $gName" 'OK'
                }
                catch { Add-LcStep $op "Añadir al grupo $gName" 'Failed' $_.Exception.Message }
            }

            if ($plan.HomeFolder) {
                try {
                    $created = New-LcHomeFolder -Path $plan.HomeFolder.Path -Sid $user.Sid -Rights $plan.HomeFolder.Rights -Label "$($cfg.Domain.NetBIOSName)\$($user.SamAccountName)"
                    $msg = if ($created) { 'Creada' } else { 'Ya existía' }
                    Add-LcStep $op 'Carpeta personal' 'OK' "$msg $($plan.HomeFolder.Path) ($($plan.HomeFolder.Rights)) como $($plan.HomeFolder.Drive)"
                }
                catch { Add-LcStep $op 'Carpeta personal' 'Failed' $_.Exception.Message }
            }

            foreach ($s in $plan.Shares) {
                try {
                    Grant-LcFolderAccess -Path $s.Path -Sid $user.Sid -Rights $s.Rights -Label "$($cfg.Domain.NetBIOSName)\$($user.SamAccountName)"
                    Add-LcStep $op "Permiso NTFS en $($s.Path)" 'OK' $s.Rights
                }
                catch { Add-LcStep $op "Permiso NTFS en $($s.Path)" 'Failed' $_.Exception.Message }
            }

            if (Test-LcCloudEnabled) {
                Invoke-LcCloudOnboardingSteps -Operation $op -UserPrincipalName $plan.UserPrincipalName -Licenses $plan.Licenses -WaitSeconds $CloudWaitSeconds
            }
        }

        $done = Complete-LcOperation $op
        if ($op.Aborted) {
            Write-Error -Message "El alta de '$($plan.DisplayName)' ha fallado. Informe: $($done.ReportPath)"
            $secure = $null
        }
        elseif ($done.Status -eq 'Partial') {
            Write-Warning "Alta de '$($plan.SamAccountName)' completada con avisos. Revisa el informe: $($done.ReportPath)"
        }

        [pscustomobject]@{
            Status            = $done.Status
            SamAccountName    = $plan.SamAccountName
            UserPrincipalName = $plan.UserPrincipalName
            DisplayName       = $plan.DisplayName
            InitialPassword   = $secure
            Errors            = @()
            Warnings          = $plan.Warnings
            Steps             = @($op.Steps)
            ReportFile        = $done.ReportFile
            ReportPath        = $done.ReportPath
            OperationId       = $op.OperationId
        }
    }
}

function Invoke-LifecycleCloudProvisioning {
    <#
    .SYNOPSIS
        Reintenta la parte de Microsoft 365 de un alta (usageLocation + licencias), p. ej. cuando
        Entra Connect todavía no había sincronizado al usuario o faltaban licencias libres.
    .EXAMPLE
        Invoke-LifecycleCloudProvisioning -Identity jgarcial -CloudWaitSeconds 300
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('SamAccountName')][string]$Identity,
        [string]$Ticket,
        [int]$CloudWaitSeconds = -1
    )
    begin { Assert-LcInitialized }
    process {
        if (-not (Test-LcCloudEnabled)) { throw 'Graph no está habilitado en la configuración (Graph.Enabled = false).' }
        $user = Get-LcDirUser $Identity
        if (-not $user) { throw "No existe el usuario '$Identity'." }
        $dept = Get-LcDepartment $user.Department
        if (-not $dept) { throw "El departamento '$($user.Department)' del usuario no está en la configuración." }
        $licenses = @(Get-LcLicensesFor $dept $user.Title)
        if (-not $PSCmdlet.ShouldProcess($user.UserPrincipalName, "Asignar licencias: $($licenses -join ', ')")) { return }

        $op = New-LcOperation -Type 'CloudProvisioning' -InputData ([ordered]@{ Identity = $Identity }) -Ticket $Ticket
        $op.Target = [ordered]@{ SamAccountName = $user.SamAccountName; UserPrincipalName = $user.UserPrincipalName; DisplayName = $user.DisplayName; Department = $user.Department; Title = $user.Title; Licenses = $licenses }
        Invoke-LcCloudOnboardingSteps -Operation $op -UserPrincipalName $user.UserPrincipalName -Licenses $licenses -WaitSeconds $CloudWaitSeconds
        $done = Complete-LcOperation $op
        [pscustomobject]@{ Status = $done.Status; SamAccountName = $user.SamAccountName; Steps = @($op.Steps); ReportFile = $done.ReportFile; ReportPath = $done.ReportPath; OperationId = $op.OperationId }
    }
}
