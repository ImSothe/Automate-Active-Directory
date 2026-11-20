# Carga, normalización y validación de la configuración JSON.
# Compatible con Windows PowerShell 5.1 (sin ConvertFrom-Json -AsHashtable).

function ConvertTo-LcHashtable {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-LcHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-LcHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $list = @(foreach ($item in $InputObject) { ConvertTo-LcHashtable $item })
        return , $list
    }
    return $InputObject
}

function Merge-LcHashtable {
    # Mezcla profunda: los valores de $Override sustituyen a los de $Base.
    param([System.Collections.IDictionary]$Base, [System.Collections.IDictionary]$Override)

    $result = [ordered]@{}
    foreach ($k in $Base.Keys) { $result[$k] = $Base[$k] }
    if ($null -eq $Override) { return $result }
    foreach ($k in $Override.Keys) {
        if ($result.Contains($k) -and $result[$k] -is [System.Collections.IDictionary] -and $Override[$k] -is [System.Collections.IDictionary]) {
            $result[$k] = Merge-LcHashtable $result[$k] $Override[$k]
        }
        else {
            $result[$k] = $Override[$k]
        }
    }
    return $result
}

function Get-LcDefaultConfig {
    [ordered]@{
        Mode         = 'Lab'
        Organization = 'Mi Empresa'
        Domain       = [ordered]@{
            NetBIOSName = ''
            DnsRoot     = ''
            UpnSuffix   = ''
            EmailDomain = ''
            Server      = ''
            UsersBaseOU = ''
            ArchiveOU   = ''
        }
        Naming       = [ordered]@{ Pattern = 'FirstInitialLastName'; MaxLength = 20 }
        Password     = [ordered]@{ Length = 16; ChangeAtLogon = $true }
        HomeFolder   = [ordered]@{ Enabled = $false; Root = ''; Drive = 'H:'; Rights = 'Modify' }
        BaseGroups   = @()
        Departments  = @()
        TitleRules   = @()
        Offboarding  = [ordered]@{ DescriptionPrefix = 'BAJA'; RemoveShareAccess = $true }
        Graph        = [ordered]@{
            Enabled                     = $false
            Auth                        = 'Interactive'
            TenantId                    = ''
            ClientId                    = ''
            CertificateThumbprint       = ''
            UsageLocation               = 'ES'
            SyncWaitSeconds             = 120
            SyncPollSeconds             = 15
            DeltaSyncServer             = ''
            RevokeSessionsOnOffboarding = $true
            RemoveLicensesOnOffboarding = $true
        }
        Audit        = [ordered]@{ Path = '../data/audit' }
        Lab          = [ordered]@{ DataPath = '../data/lab-directory.json'; SkuCapacity = [ordered]@{} }
    }
}

function Resolve-LcPath {
    # Rutas relativas => relativas a la carpeta del fichero de configuración.
    param([string]$Path, [string]$BaseDirectory)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

function Read-LcConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "No se encuentra el fichero de configuración: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    try { $parsed = $raw | ConvertFrom-Json } catch { throw "El fichero de configuración no es JSON válido ($Path): $($_.Exception.Message)" }

    $cfg = Merge-LcHashtable (Get-LcDefaultConfig) (ConvertTo-LcHashtable $parsed)

    # Normalizar listas y entradas anidadas
    $cfg.BaseGroups = @($cfg.BaseGroups | Where-Object { $_ })
    $departments = @()
    foreach ($d in @($cfg.Departments)) {
        $departments += , (Merge-LcHashtable ([ordered]@{ Name = ''; OU = ''; Groups = @(); Shares = @(); Licenses = @() }) $d)
    }
    foreach ($d in $departments) {
        $d.Groups = @($d.Groups | Where-Object { $_ })
        $d.Licenses = @($d.Licenses | Where-Object { $_ })
        $d.Shares = @(foreach ($s in @($d.Shares)) { if ($s) { Merge-LcHashtable ([ordered]@{ Path = ''; Rights = 'Modify' }) $s } })
    }
    $cfg.Departments = $departments

    $rules = @()
    foreach ($r in @($cfg.TitleRules)) {
        $rules += , (Merge-LcHashtable ([ordered]@{ Match = ''; Groups = @(); Licenses = $null }) $r)
    }
    foreach ($r in $rules) { $r.Groups = @($r.Groups | Where-Object { $_ }) }
    $cfg.TitleRules = $rules

    $baseDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    $cfg.Audit.Path = Resolve-LcPath $cfg.Audit.Path $baseDir
    $cfg.Lab.DataPath = Resolve-LcPath $cfg.Lab.DataPath $baseDir
    if ([string]::IsNullOrWhiteSpace($cfg.Domain.EmailDomain)) { $cfg.Domain.EmailDomain = $cfg.Domain.UpnSuffix }

    $problems = @(Test-LcConfig $cfg)
    if ($problems.Count -gt 0) {
        throw ("Configuración inválida ({0}):`n - {1}" -f $Path, ($problems -join "`n - "))
    }
    return $cfg
}

function Test-LcConfig {
    # Devuelve una lista de problemas (vacía si todo es correcto).
    param([System.Collections.IDictionary]$Config)

    $validRights = [Enum]::GetNames([System.Security.AccessControl.FileSystemRights])

    if ($Config.Mode -notin 'Lab', 'ActiveDirectory') { "Mode debe ser 'Lab' o 'ActiveDirectory' (valor: '$($Config.Mode)')." }
    foreach ($key in 'UpnSuffix', 'UsersBaseOU', 'ArchiveOU', 'NetBIOSName') {
        if ([string]::IsNullOrWhiteSpace($Config.Domain[$key])) { "Domain.$key es obligatorio." }
    }
    if ($Config.Naming.Pattern -notin 'FirstInitialLastName', 'FirstDotLast') { "Naming.Pattern debe ser 'FirstInitialLastName' o 'FirstDotLast'." }
    if ([int]$Config.Naming.MaxLength -lt 8 -or [int]$Config.Naming.MaxLength -gt 20) { 'Naming.MaxLength debe estar entre 8 y 20 (límite de sAMAccountName).' }
    if ([int]$Config.Password.Length -lt 12 -or [int]$Config.Password.Length -gt 128) { 'Password.Length debe estar entre 12 y 128.' }

    if ($Config.HomeFolder.Enabled) {
        if ([string]::IsNullOrWhiteSpace($Config.HomeFolder.Root)) { 'HomeFolder.Root es obligatorio si HomeFolder.Enabled = true.' }
        if ($Config.HomeFolder.Rights -notin $validRights) { "HomeFolder.Rights '$($Config.HomeFolder.Rights)' no es un permiso NTFS válido." }
    }

    if (@($Config.Departments).Count -eq 0) { 'Debe existir al menos un departamento en Departments.' }
    $seen = @{}
    foreach ($d in $Config.Departments) {
        if ([string]::IsNullOrWhiteSpace($d.Name)) { 'Hay un departamento sin Name.'; continue }
        if ($seen.ContainsKey($d.Name)) { "Departamento duplicado: '$($d.Name)'." }
        $seen[$d.Name] = $true
        if ([string]::IsNullOrWhiteSpace($d.OU)) { "El departamento '$($d.Name)' no tiene OU." }
        foreach ($s in $d.Shares) {
            if ([string]::IsNullOrWhiteSpace($s.Path)) { "El departamento '$($d.Name)' tiene una carpeta compartida sin Path." }
            if ($s.Rights -notin $validRights) { "Permiso NTFS no válido '$($s.Rights)' en '$($d.Name)'. Valores: Read, ReadAndExecute, Modify, FullControl..." }
        }
    }
    foreach ($r in $Config.TitleRules) {
        if ([string]::IsNullOrWhiteSpace($r.Match)) { 'Hay una regla en TitleRules sin Match.' }
    }

    if ($Config.Graph.Enabled) {
        if ($Config.Graph.Auth -notin 'Interactive', 'Certificate') { "Graph.Auth debe ser 'Interactive' o 'Certificate'." }
        if ($Config.Mode -eq 'ActiveDirectory' -and $Config.Graph.Auth -eq 'Certificate') {
            foreach ($key in 'TenantId', 'ClientId', 'CertificateThumbprint') {
                if ([string]::IsNullOrWhiteSpace($Config.Graph[$key])) { "Graph.$key es obligatorio con Auth = 'Certificate'." }
            }
        }
        if ($Config.Graph.UsageLocation -notmatch '^[A-Z]{2}$') { 'Graph.UsageLocation debe ser un código de país ISO de 2 letras (p. ej. ES).' }
    }
}

function Get-LcDepartment {
    param([string]$Name)
    foreach ($d in $script:Lc.Config.Departments) {
        if ($d.Name -eq $Name) { return $d }
    }
    return $null
}

function Get-LcTitleRules {
    # Reglas cuyo patrón (comodines -like, sin distinguir mayúsculas) coincide con el puesto.
    param([string]$Title)
    @(foreach ($r in $script:Lc.Config.TitleRules) {
            if ($Title -like $r.Match) { $r }
        })
}

function Get-LcAllConfiguredShares {
    $paths = @{}
    foreach ($d in $script:Lc.Config.Departments) {
        foreach ($s in $d.Shares) { $paths[$s.Path.ToLowerInvariant()] = $s.Path }
    }
    return @($paths.Values)
}
