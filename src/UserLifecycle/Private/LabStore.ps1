# Modo Lab: un "Active Directory + tenant de Microsoft 365" simulado en un fichero JSON.
# Permite probar el flujo completo (y grabar demos) sin controlador de dominio ni tenant.

$script:LabDomainSid = 'S-1-5-21-1004336348-1177238915-682003330'

function Get-LcLabDomainDn {
    $dn = $script:Lc.Config.Domain.UsersBaseOU
    if ($dn -match '(DC=.+)$') { return $Matches[1] }
    return 'DC=lab,DC=local'
}

function Read-LcLab {
    $path = $script:Lc.Config.Lab.DataPath
    if (-not (Test-Path -LiteralPath $path)) {
        Save-LcLab (New-LcLabSeed)
    }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $db = ConvertTo-LcHashtable ($raw | ConvertFrom-Json)
    foreach ($key in 'OUs', 'Groups', 'Users', 'Acls', 'Folders') { $db[$key] = @($db[$key] | Where-Object { $null -ne $_ }) }
    $db.Tenant.Skus = @($db.Tenant.Skus | Where-Object { $null -ne $_ })
    $db.Tenant.Users = @($db.Tenant.Users | Where-Object { $null -ne $_ })
    foreach ($g in $db.Groups) { $g.Members = @($g.Members | Where-Object { $_ }) }
    foreach ($u in $db.Tenant.Users) { $u.Licenses = @($u.Licenses | Where-Object { $_ }) }
    return $db
}

function Save-LcLab {
    param([System.Collections.IDictionary]$Db)
    $path = $script:Lc.Config.Lab.DataPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Db | ConvertTo-Json -Depth 12
    # Escritura atómica: fichero temporal + reemplazo
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function New-LcLabSid {
    param([System.Collections.IDictionary]$Db)
    $Db.NextRid = [int]$Db.NextRid + 1
    return "$($script:LabDomainSid)-$($Db.NextRid)"
}

function New-LcLabSeed {
    $cfg = $script:Lc.Config
    $domainDn = Get-LcLabDomainDn
    $groupsOu = "OU=Grupos,$domainDn"

    $db = [ordered]@{
        Description = 'Directorio simulado de UserLifecycle (modo Lab). Puedes borrarlo o usar Reset-LifecycleLab.'
        NextRid     = 1500
        OUs         = @()
        Groups      = @()
        Users       = @()
        Acls        = @()
        Folders     = @()
        Tenant      = [ordered]@{ Skus = @(); Users = @() }
    }

    # OUs
    $ous = @($cfg.Domain.UsersBaseOU, $cfg.Domain.ArchiveOU, $groupsOu) + @($cfg.Departments | ForEach-Object { $_.OU })
    $db.OUs = @($ous | Where-Object { $_ } | Select-Object -Unique)

    # Grupos referenciados en la configuración + grupos privilegiados reales (para demostrar el bloqueo)
    $names = @($cfg.BaseGroups) + @($cfg.Departments | ForEach-Object { $_.Groups }) + @($cfg.TitleRules | ForEach-Object { $_.Groups })
    $groups = @()
    foreach ($n in @($names | Where-Object { $_ } | Select-Object -Unique)) {
        $groups += , ([ordered]@{ Name = $n; DistinguishedName = "CN=$n,$groupsOu"; Sid = (New-LcLabSid $db); Privileged = $false; Members = @() })
    }
    $privileged = @(
        @{ Name = 'Domain Admins'; Sid = "$($script:LabDomainSid)-512" }
        @{ Name = 'Enterprise Admins'; Sid = "$($script:LabDomainSid)-519" }
        @{ Name = 'Administrators'; Sid = 'S-1-5-32-544' }
    )
    foreach ($p in $privileged) {
        $groups += , ([ordered]@{ Name = $p.Name; DistinguishedName = "CN=$($p.Name),CN=Users,$domainDn"; Sid = $p.Sid; Privileged = $true; Members = @() })
    }
    $db.Groups = $groups

    # Licencias del tenant
    $skuNames = @($cfg.Departments | ForEach-Object { $_.Licenses }) + @($cfg.TitleRules | ForEach-Object { $_.Licenses })
    $skus = @()
    foreach ($s in @($skuNames | Where-Object { $_ } | Select-Object -Unique)) {
        $cap = $cfg.Lab.SkuCapacity[$s]
        $enabled = 25; $consumed = 3
        if ($cap) { $enabled = [int]$cap.Enabled; $consumed = [int]$cap.Consumed }
        $skus += , ([ordered]@{ SkuPartNumber = $s; SkuId = [guid]::NewGuid().ToString(); Enabled = $enabled; Consumed = $consumed })
    }
    $db.Tenant.Skus = $skus

    # Usuarios de ejemplo (para ver colisiones de nombre y poder probar bajas)
    $depts = @($cfg.Departments)
    $samples = @(
        @{ Given = 'José'; Surname = 'García Pérez'; Sam = 'jgarcia'; Title = 'Comercial'; Dept = $depts[0] }
        @{ Given = 'Ana'; Surname = 'Ruiz Martín'; Sam = 'aruiz'; Title = 'Técnica de Marketing'; Dept = $depts[[Math]::Min(1, $depts.Count - 1)] }
        @{ Given = 'Luis'; Surname = 'Martínez Soto'; Sam = 'lmartinez'; Title = 'Jefe de Sistemas'; Dept = $depts[[Math]::Min(2, $depts.Count - 1)] }
    )
    foreach ($s in $samples) {
        $display = "$($s.Given) $($s.Surname)"
        $upn = "$($s.Sam)@$($cfg.Domain.UpnSuffix)"
        $db.Users += , ([ordered]@{
                SamAccountName        = $s.Sam
                UserPrincipalName     = $upn
                GivenName             = $s.Given
                Surname               = $s.Surname
                DisplayName           = $display
                DistinguishedName     = "CN=$display,$($s.Dept.OU)"
                Department            = $s.Dept.Name
                Title                 = $s.Title
                EmployeeId            = ''
                Mail                  = "$($s.Sam)@$($cfg.Domain.EmailDomain)"
                Enabled               = $true
                Description           = ''
                Manager               = ''
                Sid                   = (New-LcLabSid $db)
                AdminCount            = 0
                AccountExpirationDate = $null
                HomeDirectory         = ''
                Created               = (Get-Date).AddDays(-200).ToString('o')
            })
        foreach ($gName in (@($cfg.BaseGroups) + @($s.Dept.Groups))) {
            foreach ($g in $db.Groups) { if ($g.Name -eq $gName) { $g.Members = @($g.Members) + $s.Sam } }
        }
        $licenses = @()
        foreach ($skuName in $s.Dept.Licenses) {
            foreach ($sku in $db.Tenant.Skus) { if ($sku.SkuPartNumber -eq $skuName) { $licenses += $sku.SkuId } }
        }
        $db.Tenant.Users += , ([ordered]@{ Id = [guid]::NewGuid().ToString(); UserPrincipalName = $upn; UsageLocation = $cfg.Graph.UsageLocation; AccountEnabled = $true; Licenses = $licenses; SessionsRevokedAt = $null })
    }

    # Cuenta Administrator integrada (RID 500): el offboarding debe negarse a tocarla
    $db.Users += , ([ordered]@{
            SamAccountName = 'Administrator'; UserPrincipalName = "Administrator@$($cfg.Domain.UpnSuffix)"; GivenName = ''; Surname = ''
            DisplayName = 'Administrator'; DistinguishedName = "CN=Administrator,CN=Users,$domainDn"; Department = ''; Title = ''
            EmployeeId = ''; Mail = ''; Enabled = $true; Description = 'Cuenta integrada'; Manager = ''; Sid = "$($script:LabDomainSid)-500"
            AdminCount = 1; AccountExpirationDate = $null; HomeDirectory = ''; Created = (Get-Date).AddYears(-5).ToString('o')
        })
    foreach ($g in $db.Groups) { if ($g.Name -eq 'Domain Admins') { $g.Members = @('Administrator') } }

    return $db
}

function Get-LcLabUser {
    param([System.Collections.IDictionary]$Db, [string]$Sam)
    foreach ($u in $Db.Users) { if ($u.SamAccountName -eq $Sam) { return $u } }
    return $null
}

function Get-LcLabGroup {
    param([System.Collections.IDictionary]$Db, [string]$Name)
    foreach ($g in $Db.Groups) { if ($g.Name -eq $Name -or $g.DistinguishedName -eq $Name) { return $g } }
    return $null
}
