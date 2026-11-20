# Capa de acceso al directorio. Cada función tiene dos implementaciones:
#   - ActiveDirectory: módulo RSAT ActiveDirectory (New-ADUser, Add-ADGroupMember...)
#   - Lab:             directorio simulado en JSON (LabStore.ps1)
# El resto del módulo solo habla con estas funciones, así es fácil de testear y de ampliar.

# SIDs/RIDs de grupos privilegiados. Se comprueban por SID porque el nombre cambia con el idioma
# ("Domain Admins" = "Admins. del dominio" en un DC en español).
$script:PrivilegedBuiltinSids = @('S-1-5-32-544', 'S-1-5-32-548', 'S-1-5-32-549', 'S-1-5-32-550', 'S-1-5-32-551')
$script:PrivilegedDomainRids = @(500, 502, 512, 516, 518, 519, 520, 521, 526, 527)

function Test-LcPrivilegedSid {
    param([string]$Sid)
    if ([string]::IsNullOrEmpty($Sid)) { return $false }
    if ($script:PrivilegedBuiltinSids -contains $Sid) { return $true }
    if ($Sid -match '^S-1-5-21-\d+-\d+-\d+-(\d+)$') { return ($script:PrivilegedDomainRids -contains [int]$Matches[1]) }
    return $false
}

function Get-LcAdParams {
    $p = @{}
    if ($script:Lc.Config.Domain.Server) { $p.Server = $script:Lc.Config.Domain.Server }
    return $p
}

function ConvertTo-LcUserObject {
    # Objeto de usuario normalizado (igual para AD y Lab).
    param($Source, [string]$Kind)

    if ($Kind -eq 'AD') {
        $groups = @(foreach ($dn in @($Source.memberOf)) { if ($dn) { [pscustomobject]@{ Name = (Get-LcCnFromDn $dn); DistinguishedName = $dn } } })
        $adminCount = 0
        if ($Source.adminCount) { $adminCount = [int]$Source.adminCount }
        $expires = $null
        if ($Source.AccountExpirationDate) { $expires = ([datetime]$Source.AccountExpirationDate).ToString('yyyy-MM-dd') }
        return [pscustomobject]@{
            SamAccountName        = $Source.SamAccountName
            UserPrincipalName     = $Source.UserPrincipalName
            DisplayName           = $Source.DisplayName
            GivenName             = $Source.GivenName
            Surname               = $Source.Surname
            Department            = $Source.Department
            Title                 = $Source.Title
            EmployeeId            = $Source.EmployeeID
            Mail                  = $Source.mail
            Enabled               = [bool]$Source.Enabled
            DistinguishedName     = $Source.DistinguishedName
            OU                    = (Get-LcParentDn $Source.DistinguishedName)
            Sid                   = $Source.SID.Value
            AdminCount            = $adminCount
            Description           = $Source.Description
            Manager               = $Source.Manager
            AccountExpirationDate = $expires
            MemberOf              = $groups
        }
    }

    # Lab
    $db = $script:LcLabCache
    $groups = @(foreach ($g in $db.Groups) { if (@($g.Members) -contains $Source.SamAccountName) { [pscustomobject]@{ Name = $g.Name; DistinguishedName = $g.DistinguishedName } } })
    return [pscustomobject]@{
        SamAccountName        = $Source.SamAccountName
        UserPrincipalName     = $Source.UserPrincipalName
        DisplayName           = $Source.DisplayName
        GivenName             = $Source.GivenName
        Surname               = $Source.Surname
        Department            = $Source.Department
        Title                 = $Source.Title
        EmployeeId            = $Source.EmployeeId
        Mail                  = $Source.Mail
        Enabled               = [bool]$Source.Enabled
        DistinguishedName     = $Source.DistinguishedName
        OU                    = (Get-LcParentDn $Source.DistinguishedName)
        Sid                   = $Source.Sid
        AdminCount            = [int]$Source.AdminCount
        Description           = $Source.Description
        Manager               = $Source.Manager
        AccountExpirationDate = $Source.AccountExpirationDate
        MemberOf              = $groups
    }
}

$script:AdUserProperties = @('DisplayName', 'GivenName', 'Surname', 'Department', 'Title', 'EmployeeID', 'mail', 'memberOf', 'Description', 'Manager', 'adminCount', 'AccountExpirationDate', 'UserPrincipalName')

function Get-LcDirUser {
    param([Parameter(Mandatory)][string]$SamAccountName)

    if ($script:Lc.Mode -eq 'Lab') {
        $script:LcLabCache = Read-LcLab
        $u = Get-LcLabUser $script:LcLabCache $SamAccountName
        if (-not $u) { return $null }
        return ConvertTo-LcUserObject $u 'Lab'
    }

    $ad = Get-LcAdParams
    $filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$(ConvertTo-LcLdapValue $SamAccountName)))"
    $u = Get-ADUser -LDAPFilter $filter -Properties $script:AdUserProperties @ad
    if (-not $u) { return $null }
    return ConvertTo-LcUserObject $u 'AD'
}

function Find-LcDirUser {
    param([string]$Search, [int]$Max = 25)

    $Search = ($Search -replace '\s+', ' ').Trim()
    if ($script:Lc.Mode -eq 'Lab') {
        $script:LcLabCache = Read-LcLab
        $results = foreach ($u in $script:LcLabCache.Users) {
            if (-not $Search -or $u.SamAccountName -like "*$Search*" -or $u.DisplayName -like "*$Search*" -or $u.Mail -like "*$Search*" -or $u.EmployeeId -eq $Search) {
                ConvertTo-LcUserObject $u 'Lab'
            }
        }
        return @($results | Select-Object -First $Max)
    }

    $ad = Get-LcAdParams
    $v = ConvertTo-LcLdapValue $Search
    $filter = "(&(objectCategory=person)(objectClass=user)(|(sAMAccountName=*$v*)(displayName=*$v*)(mail=*$v*)(employeeID=$v)))"
    $users = Get-ADUser -LDAPFilter $filter -Properties $script:AdUserProperties -ResultSetSize $Max @ad
    return @(foreach ($u in $users) { ConvertTo-LcUserObject $u 'AD' })
}

function Test-LcDirAccountNameTaken {
    # ¿Existe ya alguien con ese sAMAccountName, UPN o correo/proxyAddress?
    param([string]$SamAccountName, [string]$UserPrincipalName, [string]$Mail)

    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        foreach ($u in $db.Users) {
            if ($u.SamAccountName -eq $SamAccountName -or $u.UserPrincipalName -eq $UserPrincipalName -or ($Mail -and $u.Mail -eq $Mail)) { return $true }
        }
        return $false
    }

    $ad = Get-LcAdParams
    $s = ConvertTo-LcLdapValue $SamAccountName
    $p = ConvertTo-LcLdapValue $UserPrincipalName
    $m = ConvertTo-LcLdapValue $Mail
    $filter = "(|(sAMAccountName=$s)(userPrincipalName=$p)(mail=$m)(proxyAddresses=smtp:$m))"
    $hit = Get-ADObject -LDAPFilter $filter -ResultSetSize 1 @ad
    return [bool]$hit
}

function Test-LcDirEmployeeIdTaken {
    param([string]$EmployeeId)
    if ([string]::IsNullOrWhiteSpace($EmployeeId)) { return $false }

    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        foreach ($u in $db.Users) { if ($u.EmployeeId -eq $EmployeeId) { return $true } }
        return $false
    }
    $ad = Get-LcAdParams
    $hit = Get-ADUser -LDAPFilter "(employeeID=$(ConvertTo-LcLdapValue $EmployeeId))" -ResultSetSize 1 @ad
    return [bool]$hit
}

function Test-LcDirOU {
    param([string]$DistinguishedName)

    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        return (@($db.OUs) -contains $DistinguishedName)
    }
    $ad = Get-LcAdParams
    try {
        $null = Get-ADOrganizationalUnit -Identity $DistinguishedName @ad
        return $true
    }
    catch { return $false }
}

function Get-LcDirGroup {
    # Devuelve @{ Name; DistinguishedName; Sid; Privileged } o $null si no existe.
    param([Parameter(Mandatory)][string]$Name)

    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        $g = Get-LcLabGroup $db $Name
        if (-not $g) { return $null }
        return [pscustomobject]@{ Name = $g.Name; DistinguishedName = $g.DistinguishedName; Sid = $g.Sid; Privileged = ([bool]$g.Privileged -or (Test-LcPrivilegedSid $g.Sid)) }
    }

    $ad = Get-LcAdParams
    $v = ConvertTo-LcLdapValue $Name
    $filter = "(|(sAMAccountName=$v)(cn=$v))"
    if ($Name -match '^CN=.+,DC=') { $filter = "(distinguishedName=$v)" }
    $found = @(Get-ADGroup -LDAPFilter $filter -Properties adminCount, objectSid @ad)
    if ($found.Count -eq 0) { return $null }
    if ($found.Count -gt 1) { throw "El nombre de grupo '$Name' es ambiguo ($($found.Count) coincidencias). Usa el sAMAccountName exacto." }
    $g = $found[0]
    $sid = $g.SID.Value
    # adminCount = 1 => el grupo está (o estuvo) protegido por AdminSDHolder: lo tratamos como privilegiado.
    $privileged = (Test-LcPrivilegedSid $sid) -or ([int]$g.adminCount -eq 1)
    return [pscustomobject]@{ Name = $g.Name; DistinguishedName = $g.DistinguishedName; Sid = $sid; Privileged = $privileged }
}

function New-LcDirUser {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Spec,
        [Parameter(Mandatory)][System.Security.SecureString]$Password
    )

    $cfg = $script:Lc.Config

    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        $cn = $Spec.DisplayName
        foreach ($u in $db.Users) {
            if ($u.DistinguishedName -eq "CN=$(ConvertTo-LcDnComponent $cn),$($Spec.OU)") { $cn = "$($Spec.DisplayName) ($($Spec.SamAccountName))" }
        }
        $expires = $null
        if ($Spec.EndDate) { $expires = ([datetime]$Spec.EndDate).ToString('yyyy-MM-dd') }
        $user = [ordered]@{
            SamAccountName        = $Spec.SamAccountName
            UserPrincipalName     = $Spec.UserPrincipalName
            GivenName             = $Spec.GivenName
            Surname               = $Spec.Surname
            DisplayName           = $Spec.DisplayName
            DistinguishedName     = "CN=$(ConvertTo-LcDnComponent $cn),$($Spec.OU)"
            Department            = $Spec.Department
            Title                 = $Spec.Title
            EmployeeId            = $Spec.EmployeeId
            Mail                  = $Spec.Mail
            Enabled               = $true
            Description           = $Spec.Description
            Manager               = $Spec.ManagerDn
            Sid                   = (New-LcLabSid $db)
            AdminCount            = 0
            AccountExpirationDate = $expires
            HomeDirectory         = $Spec.HomeDirectory
            Created               = (Get-Date).ToString('o')
        }
        $db.Users = @($db.Users) + $user
        Save-LcLab $db
        return Get-LcDirUser $Spec.SamAccountName
    }

    $ad = Get-LcAdParams

    # Si ya hay un objeto con el mismo CN en la OU, añadimos el sAMAccountName al CN
    $cn = $Spec.DisplayName
    $clash = Get-ADObject -LDAPFilter "(cn=$(ConvertTo-LcLdapValue $cn))" -SearchBase $Spec.OU -SearchScope OneLevel @ad
    if ($clash) { $cn = "$($Spec.DisplayName) ($($Spec.SamAccountName))" }

    $params = @{
        Name                  = $cn
        SamAccountName        = $Spec.SamAccountName
        UserPrincipalName     = $Spec.UserPrincipalName
        GivenName             = $Spec.GivenName
        Surname               = $Spec.Surname
        DisplayName           = $Spec.DisplayName
        EmailAddress          = $Spec.Mail
        Department            = $Spec.Department
        Title                 = $Spec.Title
        Company               = $cfg.Organization
        Path                  = $Spec.OU
        AccountPassword       = $Password
        Enabled               = $true
        ChangePasswordAtLogon = [bool]$cfg.Password.ChangeAtLogon
    }
    if ($Spec.EmployeeId) { $params.EmployeeID = $Spec.EmployeeId }
    if ($Spec.Description) { $params.Description = $Spec.Description }
    if ($Spec.ManagerDn) { $params.Manager = $Spec.ManagerDn }
    if ($Spec.HomeDirectory) { $params.HomeDirectory = $Spec.HomeDirectory; $params.HomeDrive = $cfg.HomeFolder.Drive }
    # AD expira la cuenta al INICIO del día indicado: sumamos 1 día para que la fecha fin sea inclusiva.
    if ($Spec.EndDate) { $params.AccountExpirationDate = ([datetime]$Spec.EndDate).Date.AddDays(1) }

    New-ADUser @params @ad
    return Get-LcDirUser $Spec.SamAccountName
}

function Add-LcDirGroupMember {
    param([string]$GroupName, [string]$SamAccountName)

    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        $g = Get-LcLabGroup $db $GroupName
        if (-not $g) { throw "El grupo '$GroupName' no existe." }
        if (@($g.Members) -notcontains $SamAccountName) { $g.Members = @($g.Members) + $SamAccountName }
        Save-LcLab $db
        return
    }
    $ad = Get-LcAdParams
    $group = Get-LcDirGroup $GroupName
    if (-not $group) { throw "El grupo '$GroupName' no existe." }
    $user = Get-LcDirUser $SamAccountName
    Add-ADGroupMember -Identity $group.DistinguishedName -Members $user.DistinguishedName @ad
}

function Remove-LcDirGroupMember {
    param([string]$GroupDistinguishedName, [string]$SamAccountName)

    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        $g = Get-LcLabGroup $db $GroupDistinguishedName
        if (-not $g) { throw "El grupo '$GroupDistinguishedName' no existe." }
        $g.Members = @($g.Members | Where-Object { $_ -ne $SamAccountName })
        Save-LcLab $db
        return
    }
    $ad = Get-LcAdParams
    $user = Get-LcDirUser $SamAccountName
    Remove-ADGroupMember -Identity $GroupDistinguishedName -Members $user.DistinguishedName -Confirm:$false @ad
}

function Disable-LcDirUser {
    param([string]$SamAccountName)
    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        (Get-LcLabUser $db $SamAccountName).Enabled = $false
        Save-LcLab $db
        return
    }
    $ad = Get-LcAdParams
    Disable-ADAccount -Identity (Get-LcDirUser $SamAccountName).DistinguishedName @ad
}

function Reset-LcDirPassword {
    param([string]$SamAccountName, [System.Security.SecureString]$Password)
    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        (Get-LcLabUser $db $SamAccountName).PasswordLastSet = (Get-Date).ToString('o')
        Save-LcLab $db
        return
    }
    $ad = Get-LcAdParams
    Set-ADAccountPassword -Identity (Get-LcDirUser $SamAccountName).DistinguishedName -Reset -NewPassword $Password @ad
}

function Set-LcDirDescription {
    param([string]$SamAccountName, [string]$Description)
    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        (Get-LcLabUser $db $SamAccountName).Description = $Description
        Save-LcLab $db
        return
    }
    $ad = Get-LcAdParams
    Set-ADUser -Identity (Get-LcDirUser $SamAccountName).DistinguishedName -Description $Description @ad
}

function Move-LcDirUser {
    # Mueve el usuario a otra OU. Devuelve el nuevo DN.
    param([string]$SamAccountName, [string]$TargetOU)

    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        $u = Get-LcLabUser $db $SamAccountName
        $rdn = ($u.DistinguishedName -split '(?<!\\),', 2)[0]
        $newDn = "$rdn,$TargetOU"
        foreach ($other in $db.Users) {
            if ($other.DistinguishedName -eq $newDn) { $newDn = "CN=$(ConvertTo-LcDnComponent "$($u.DisplayName) ($SamAccountName)"),$TargetOU" }
        }
        $u.DistinguishedName = $newDn
        Save-LcLab $db
        return $newDn
    }

    $ad = Get-LcAdParams
    $user = Get-LcDirUser $SamAccountName
    $cn = Get-LcCnFromDn $user.DistinguishedName
    $clash = Get-ADObject -LDAPFilter "(cn=$(ConvertTo-LcLdapValue $cn))" -SearchBase $TargetOU -SearchScope OneLevel @ad
    $identity = $user.DistinguishedName
    if ($clash) {
        $renamed = Rename-ADObject -Identity $identity -NewName "$cn ($SamAccountName)" -PassThru @ad
        $identity = $renamed.DistinguishedName
    }
    $moved = Move-ADObject -Identity $identity -TargetPath $TargetOU -PassThru @ad
    return $moved.DistinguishedName
}
