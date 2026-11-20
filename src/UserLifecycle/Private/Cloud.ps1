# Microsoft Graph (Entra ID / Microsoft 365).
# Se usa Invoke-MgGraphRequest (solo requiere el módulo Microsoft.Graph.Authentication) para que las
# llamadas REST sean explícitas: es exactamente lo que verías en Graph Explorer o en la documentación.
#
# Permisos de aplicación necesarios (mínimo privilegio):
#   User.ReadWrite.All              -> usageLocation, revokeSignInSessions
#   LicenseAssignment.ReadWrite.All -> assignLicense
#   Organization.Read.All           -> subscribedSkus (inventario de licencias)

$script:GraphScopes = @('User.ReadWrite.All', 'LicenseAssignment.ReadWrite.All', 'Organization.Read.All')

function Test-LcCloudEnabled {
    return [bool]$script:Lc.Config.Graph.Enabled
}

function Connect-LcCloud {
    if ($script:Lc.Mode -eq 'Lab' -or $script:Lc.CloudConnected) { return }

    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        Import-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue
    }
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        throw 'Falta el módulo Microsoft.Graph.Authentication. Instálalo con: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }

    $g = $script:Lc.Config.Graph
    $ctx = Get-MgContext
    if (-not $ctx) {
        if ($g.Auth -eq 'Certificate') {
            Connect-MgGraph -TenantId $g.TenantId -ClientId $g.ClientId -CertificateThumbprint $g.CertificateThumbprint -NoWelcome -ErrorAction Stop
        }
        else {
            $params = @{ Scopes = $script:GraphScopes; NoWelcome = $true; ErrorAction = 'Stop' }
            if ($g.TenantId -and $g.TenantId -notmatch '^0{8}-') { $params.TenantId = $g.TenantId }
            Connect-MgGraph @params
        }
    }
    $script:Lc.CloudConnected = $true
}

function Invoke-LcGraph {
    param([string]$Method = 'GET', [string]$Uri, $Body)
    Connect-LcCloud
    $params = @{ Method = $Method; Uri = $Uri; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
        $params.ContentType = 'application/json'
    }
    return Invoke-MgGraphRequest @params
}

function Get-LcCloudUser {
    # Devuelve @{ Id; UserPrincipalName; UsageLocation; AccountEnabled; Licenses(skuIds) } o $null.
    param([Parameter(Mandatory)][string]$UserPrincipalName)

    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        foreach ($u in $db.Tenant.Users) {
            if ($u.UserPrincipalName -eq $UserPrincipalName) {
                return [pscustomobject]@{ Id = $u.Id; UserPrincipalName = $u.UserPrincipalName; UsageLocation = $u.UsageLocation; AccountEnabled = $u.AccountEnabled; Licenses = @($u.Licenses) }
            }
        }
        return $null
    }

    # Se usa $filter (y no /users/{upn}) para recibir una lista vacía en vez de un 404.
    $odataUpn = $UserPrincipalName.Replace("'", "''")
    $filter = [uri]::EscapeDataString("userPrincipalName eq '$odataUpn'")
    $uri = '/v1.0/users?$filter=' + $filter + '&$select=id,userPrincipalName,usageLocation,accountEnabled,assignedLicenses'
    $r = Invoke-LcGraph -Uri $uri
    $u = @($r.value) | Select-Object -First 1
    if (-not $u) { return $null }
    return [pscustomobject]@{
        Id                = $u.id
        UserPrincipalName = $u.userPrincipalName
        UsageLocation     = $u.usageLocation
        AccountEnabled    = $u.accountEnabled
        Licenses          = @(foreach ($l in @($u.assignedLicenses)) { $l.skuId })
    }
}

function Invoke-LcDeltaSync {
    # Lanza un ciclo delta de Entra Connect para no esperar los ~30 min del ciclo programado.
    $server = $script:Lc.Config.Graph.DeltaSyncServer
    if ($script:Lc.Mode -eq 'Lab' -or [string]::IsNullOrWhiteSpace($server)) { return $false }
    Invoke-Command -ComputerName $server -ErrorAction Stop -ScriptBlock {
        Import-Module ADSync
        Start-ADSyncSyncCycle -PolicyType Delta | Out-Null
    }
    return $true
}

function Wait-LcCloudUser {
    # Espera a que Entra Connect sincronice el usuario. Devuelve el usuario cloud o $null si se agota el tiempo.
    param([string]$UserPrincipalName, [int]$TimeoutSeconds, [int]$PollSeconds = 15)

    if ($script:Lc.Mode -eq 'Lab') {
        # Simulación de la sincronización: el usuario aparece en el tenant al instante.
        $db = Read-LcLab
        $existing = $null
        foreach ($u in $db.Tenant.Users) { if ($u.UserPrincipalName -eq $UserPrincipalName) { $existing = $u } }
        if (-not $existing) {
            $onPrem = $null
            foreach ($u in $db.Users) { if ($u.UserPrincipalName -eq $UserPrincipalName) { $onPrem = $u } }
            if (-not $onPrem) { return $null }
            $db.Tenant.Users = @($db.Tenant.Users) + ([ordered]@{ Id = [guid]::NewGuid().ToString(); UserPrincipalName = $UserPrincipalName; UsageLocation = $null; AccountEnabled = $true; Licenses = @(); SessionsRevokedAt = $null })
            Save-LcLab $db
        }
        return Get-LcCloudUser $UserPrincipalName
    }

    $deadline = (Get-Date).AddSeconds([Math]::Max(0, $TimeoutSeconds))
    do {
        $u = Get-LcCloudUser $UserPrincipalName
        if ($u) { return $u }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds ([Math]::Max(5, $PollSeconds))
    } while ($true)
    return $null
}

function Set-LcCloudUsageLocation {
    # Obligatorio antes de asignar licencias (requisito legal de Microsoft por país).
    param([string]$UserId, [string]$UsageLocation)
    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        foreach ($u in $db.Tenant.Users) { if ($u.Id -eq $UserId) { $u.UsageLocation = $UsageLocation } }
        Save-LcLab $db
        return
    }
    $null = Invoke-LcGraph -Method PATCH -Uri "/v1.0/users/$UserId" -Body @{ usageLocation = $UsageLocation }
}

function Get-LcCloudSkus {
    # Inventario de licencias: SkuPartNumber, SkuId, Enabled, Consumed, Available
    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        return @(foreach ($s in $db.Tenant.Skus) {
                [pscustomobject]@{ SkuPartNumber = $s.SkuPartNumber; SkuId = $s.SkuId; Enabled = [int]$s.Enabled; Consumed = [int]$s.Consumed; Available = ([int]$s.Enabled - [int]$s.Consumed) }
            })
    }
    $r = Invoke-LcGraph -Uri '/v1.0/subscribedSkus?$select=skuId,skuPartNumber,prepaidUnits,consumedUnits'
    return @(foreach ($s in @($r.value)) {
            $enabled = [int]$s.prepaidUnits.enabled
            [pscustomobject]@{ SkuPartNumber = $s.skuPartNumber; SkuId = $s.skuId; Enabled = $enabled; Consumed = [int]$s.consumedUnits; Available = ($enabled - [int]$s.consumedUnits) }
        })
}

function Add-LcCloudLicense {
    param([string]$UserId, [string]$SkuId)
    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        $sku = $null
        foreach ($s in $db.Tenant.Skus) { if ($s.SkuId -eq $SkuId) { $sku = $s } }
        foreach ($u in $db.Tenant.Users) {
            if ($u.Id -ne $UserId) { continue }
            if (-not $u.UsageLocation) { throw 'License assignment failed because the user has an invalid usage location.' }
            if (@($u.Licenses) -contains $SkuId) { return }
            if ([int]$sku.Consumed -ge [int]$sku.Enabled) { throw "Subscription for SKU '$($sku.SkuPartNumber)' has no available licenses." }
            $u.Licenses = @($u.Licenses) + $SkuId
            $sku.Consumed = [int]$sku.Consumed + 1
        }
        Save-LcLab $db
        return
    }
    $body = @{ addLicenses = @(@{ skuId = $SkuId; disabledPlans = @() }); removeLicenses = @() }
    $null = Invoke-LcGraph -Method POST -Uri "/v1.0/users/$UserId/assignLicense" -Body $body
}

function Remove-LcCloudLicense {
    param([string]$UserId, [string[]]$SkuIds)
    if (@($SkuIds).Count -eq 0) { return }
    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        foreach ($u in $db.Tenant.Users) {
            if ($u.Id -ne $UserId) { continue }
            foreach ($skuId in $SkuIds) {
                if (@($u.Licenses) -contains $skuId) {
                    $u.Licenses = @($u.Licenses | Where-Object { $_ -ne $skuId })
                    foreach ($s in $db.Tenant.Skus) { if ($s.SkuId -eq $skuId) { $s.Consumed = [Math]::Max(0, [int]$s.Consumed - 1) } }
                }
            }
        }
        Save-LcLab $db
        return
    }
    $body = @{ addLicenses = @(); removeLicenses = @($SkuIds) }
    $null = Invoke-LcGraph -Method POST -Uri "/v1.0/users/$UserId/assignLicense" -Body $body
}

function Revoke-LcCloudSession {
    # Invalida los refresh tokens y las cookies de sesión: el usuario tiene que volver a autenticarse.
    param([string]$UserId)
    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        foreach ($u in $db.Tenant.Users) { if ($u.Id -eq $UserId) { $u.SessionsRevokedAt = (Get-Date).ToString('o') } }
        Save-LcLab $db
        return
    }
    $null = Invoke-LcGraph -Method POST -Uri "/v1.0/users/$UserId/revokeSignInSessions"
}
