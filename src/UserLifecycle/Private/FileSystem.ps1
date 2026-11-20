# Carpetas personales y permisos NTFS en carpetas compartidas.
# Los permisos se conceden por SID (no por nombre): un usuario recién creado puede no haberse
# replicado aún al DC que consulta el servidor de ficheros, y la traducción por nombre fallaría.

function Get-LcFolderAcl {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return $item.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
    }
    return [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.DirectoryInfo]$item, [System.Security.AccessControl.AccessControlSections]::Access)
}

function Set-LcFolderAcl {
    # Solo escribe la DACL (no el propietario), evitando el típico error de Set-Acl en rutas UNC.
    param([string]$Path, $Acl)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $item.SetAccessControl($Acl)
        return
    }
    [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]$item, $Acl)
}

function Grant-LcFolderAccess {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][string]$Rights,
        [string]$Label
    )

    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        $db.Acls = @($db.Acls | Where-Object { -not ($_.Path -eq $Path -and $_.Sid -eq $Sid) }) + ([ordered]@{ Path = $Path; Sid = $Sid; Identity = $Label; Rights = $Rights })
        Save-LcLab $db
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) { throw "La carpeta '$Path' no existe o no es accesible." }
    $acl = Get-LcFolderAcl $Path
    $identity = New-Object System.Security.Principal.SecurityIdentifier($Sid)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $identity,
        [System.Security.AccessControl.FileSystemRights]$Rights,
        ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'),
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
    Set-LcFolderAcl $Path $acl
}

function Revoke-LcFolderAccess {
    # Quita todas las ACE explícitas del SID. Devuelve el número de ACE eliminadas.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sid)

    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        $before = @($db.Acls).Count
        $db.Acls = @($db.Acls | Where-Object { -not ($_.Path -eq $Path -and $_.Sid -eq $Sid) })
        $removed = $before - @($db.Acls).Count
        if ($removed -gt 0) { Save-LcLab $db }
        return $removed
    }

    if (-not (Test-Path -LiteralPath $Path)) { throw "La carpeta '$Path' no existe o no es accesible." }
    $acl = Get-LcFolderAcl $Path
    $identity = New-Object System.Security.Principal.SecurityIdentifier($Sid)
    $explicit = @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq $Sid })
    if ($explicit.Count -eq 0) { return 0 }
    $acl.PurgeAccessRules($identity)
    Set-LcFolderAcl $Path $acl
    return $explicit.Count
}

function Test-LcFolderExists {
    param([string]$Path)
    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        if (@($db.Folders) -contains $Path) { return $true }
        # En Lab, las carpetas compartidas de la configuración "existen"
        return (@(Get-LcAllConfiguredShares) -contains $Path)
    }
    return (Test-Path -LiteralPath $Path)
}

function New-LcHomeFolder {
    # Crea la carpeta personal (si no existe) y da permisos al usuario. Devuelve $true si la creó.
    param([string]$Path, [string]$Sid, [string]$Rights, [string]$Label)

    $created = $false
    if ($script:Lc.Mode -eq 'Lab') {
        $db = Read-LcLab
        if (@($db.Folders) -notcontains $Path) {
            $db.Folders = @($db.Folders) + $Path
            Save-LcLab $db
            $created = $true
        }
    }
    elseif (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
        $created = $true
    }
    Grant-LcFolderAccess -Path $Path -Sid $Sid -Rights $Rights -Label $Label
    return $created
}
