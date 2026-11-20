# Normalización de nombres, generación de sAMAccountName, contraseñas y validaciones de entrada.

# Partículas habituales en apellidos (de la Fuente, del Río, van der Berg...)
$script:SurnameParticles = @('de', 'del', 'la', 'las', 'los', 'y', 'i', 'da', 'das', 'do', 'dos', 'di', 'van', 'von', 'der', 'den', 'le')

function ConvertTo-LcAscii {
    <#
        "José Ñúñez-Peña" -> "josenunezpena". Quita tildes/diéresis/ñ y todo lo que no sea [a-z0-9].
        Los caracteres especiales se escriben como códigos para que el fichero sea ASCII puro.
    #>
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $map = @{
        ([string][char]0x00DF) = 'ss'  # ß
        ([string][char]0x00F8) = 'o'   # ø
        ([string][char]0x00E6) = 'ae'  # æ
        ([string][char]0x0153) = 'oe'  # œ
        ([string][char]0x0142) = 'l'   # ł
        ([string][char]0x0111) = 'd'   # đ
        ([string][char]0x00FE) = 'th'  # þ
    }
    $decomposed = $Text.ToLowerInvariant().Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $decomposed.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($category -eq [System.Globalization.UnicodeCategory]::NonSpacingMark) { continue }
        $s = [string]$ch
        if ($map.ContainsKey($s)) { $s = $map[$s] }
        [void]$sb.Append($s)
    }
    return ($sb.ToString() -replace '[^a-z0-9]', '')
}

function Split-LcSurname {
    <#
        Agrupa partículas con la palabra siguiente:
        "Fernández de la Vega" -> @("Fernández", "de la Vega")
        "de la Fuente García"  -> @("de la Fuente", "García")
    #>
    param([string]$Surname)

    $words = @($Surname -split '\s+' | Where-Object { $_ })
    $parts = @()
    $pending = @()
    foreach ($w in $words) {
        if ($script:SurnameParticles -contains $w.ToLowerInvariant()) {
            $pending += $w
            continue
        }
        $parts += (($pending + $w) -join ' ')
        $pending = @()
    }
    if ($pending.Count -gt 0) {
        if ($parts.Count -gt 0) { $parts[$parts.Count - 1] = $parts[$parts.Count - 1] + ' ' + ($pending -join ' ') }
        else { $parts += ($pending -join ' ') }
    }
    return $parts
}

function Format-LcPersonName {
    <#
        Limpia espacios. Si el texto viene todo en MAYÚSCULAS o todo en minúsculas, lo pasa a
        formato título dejando las partículas en minúscula: "JUAN DE LA FUENTE" -> "Juan de la Fuente".
    #>
    param([string]$Name)

    $clean = ($Name -replace '\s+', ' ').Trim()
    if ($clean -cne $clean.ToUpperInvariant() -and $clean -cne $clean.ToLowerInvariant()) { return $clean }

    $textInfo = [System.Globalization.CultureInfo]::GetCultureInfo('es-ES').TextInfo
    $i = 0
    $words = foreach ($w in ($clean -split ' ')) {
        $lower = $w.ToLowerInvariant()
        if ($i -gt 0 -and $script:SurnameParticles -contains $lower) { $lower }
        else { $textInfo.ToTitleCase($lower) }
        $i++
    }
    return ($words -join ' ')
}

function Get-LcSamCandidates {
    <#
        Genera candidatos de sAMAccountName en orden de preferencia.
        FirstInitialLastName: jgarcia, jgarcial, jmgarcia, jgarcia2, jgarcia3...
        FirstDotLast:         jose.garcia, jose.garcialopez, jose.garcia2...
    #>
    param(
        [string]$GivenName,
        [string]$Surname,
        [string]$Pattern = 'FirstInitialLastName',
        [int]$MaxLength = 20
    )

    $givenWords = @($GivenName -split '\s+' | Where-Object { $_ } | ForEach-Object { ConvertTo-LcAscii $_ } | Where-Object { $_ })
    $surnames = @(Split-LcSurname $Surname | ForEach-Object { ConvertTo-LcAscii $_ } | Where-Object { $_ })
    if ($givenWords.Count -eq 0 -or $surnames.Count -eq 0) {
        throw 'No se puede generar un nombre de cuenta: nombre o apellidos vacíos tras normalizar.'
    }

    $first = $givenWords[0]
    $s1 = $surnames[0]
    $s2 = if ($surnames.Count -gt 1) { $surnames[1] } else { '' }

    $bases = New-Object System.Collections.Generic.List[string]
    if ($Pattern -eq 'FirstDotLast') {
        $bases.Add("$first.$s1")
        if ($s2) { $bases.Add("$first.$s1$s2") }
    }
    else {
        $bases.Add("$($first[0])$s1")
        if ($s2) { $bases.Add("$($first[0])$s1$($s2[0])") }
        if ($givenWords.Count -gt 1) { $bases.Add("$($first[0])$($givenWords[1][0])$s1") }
    }

    $seen = @{}
    foreach ($b in $bases) {
        $candidate = $b.Substring(0, [Math]::Min($b.Length, $MaxLength)).TrimEnd('.')
        if (-not $seen.ContainsKey($candidate)) { $seen[$candidate] = $true; $candidate }
    }
    $root = $bases[0]
    for ($n = 2; $n -le 99; $n++) {
        $suffix = [string]$n
        $cut = [Math]::Min($root.Length, $MaxLength - $suffix.Length)
        $candidate = $root.Substring(0, $cut).TrimEnd('.') + $suffix
        if (-not $seen.ContainsKey($candidate)) { $seen[$candidate] = $true; $candidate }
    }
}

function Get-LcRandomIndex {
    # Entero uniforme en [0, $Max) usando RNG criptográfico (rechazo para evitar sesgo de módulo).
    param([System.Security.Cryptography.RandomNumberGenerator]$Rng, [int]$Max)
    $bytes = New-Object byte[] 4
    $limit = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$Max)
    do {
        $Rng.GetBytes($bytes)
        $value = [BitConverter]::ToUInt32($bytes, 0)
    } while ($value -ge $limit)
    return [int]($value % [uint32]$Max)
}

function New-LcPassword {
    <#
        Contraseña aleatoria con RNG criptográfico. Garantiza mayúscula, minúscula, dígito y símbolo.
        Evita caracteres ambiguos (0/O, 1/l/I) para poder dictarla por teléfono, y $ ` que dan guerra en shells.
    #>
    param([int]$Length = 16)

    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#%*-_=+?')
    $all = -join $sets
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $chars = New-Object System.Collections.Generic.List[char]
        foreach ($set in $sets) { $chars.Add($set[(Get-LcRandomIndex $rng $set.Length)]) }
        while ($chars.Count -lt $Length) { $chars.Add($all[(Get-LcRandomIndex $rng $all.Length)]) }
        # Fisher-Yates
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = Get-LcRandomIndex $rng ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        return (-join $chars)
    }
    finally { $rng.Dispose() }
}

function ConvertTo-LcSecureString {
    param([string]$PlainText)
    $ss = New-Object System.Security.SecureString
    foreach ($c in $PlainText.ToCharArray()) { $ss.AppendChar($c) }
    $ss.MakeReadOnly()
    return $ss
}

function ConvertFrom-LcSecureString {
    param([System.Security.SecureString]$SecureString)
    return (New-Object System.Net.NetworkCredential('', $SecureString)).Password
}

function ConvertTo-LcLdapValue {
    # Escapado RFC 4515 para valores dentro de filtros LDAP (evita inyección LDAP).
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Value.ToCharArray()) {
        switch ($c) {
            '\' { [void]$sb.Append('\5c') }
            '*' { [void]$sb.Append('\2a') }
            '(' { [void]$sb.Append('\28') }
            ')' { [void]$sb.Append('\29') }
            ([char]0) { [void]$sb.Append('\00') }
            default { [void]$sb.Append($c) }
        }
    }
    return $sb.ToString()
}

function Get-LcCnFromDn {
    # "CN=García\, José,OU=Ventas,DC=..." -> "García, José"
    param([string]$DistinguishedName)
    if ($DistinguishedName -match '^CN=((?:\\.|[^,\\])+),') {
        return ($Matches[1] -replace '\\(.)', '$1')
    }
    return $DistinguishedName
}

function Get-LcParentDn {
    param([string]$DistinguishedName)
    if ($DistinguishedName -match '^(?:CN|OU)=(?:\\.|[^,\\])+,(.+)$') { return $Matches[1] }
    return ''
}

function ConvertTo-LcDnComponent {
    # Escapa un valor para usarlo como RDN (CN=...) dentro de un DN.
    param([string]$Value)
    $escaped = $Value -replace '([,\\#+<>;"=])', '\$1'
    if ($escaped.StartsWith(' ')) { $escaped = '\' + $escaped }
    if ($escaped.EndsWith(' ')) { $escaped = $escaped.Substring(0, $escaped.Length - 1) + '\ ' }
    return $escaped
}

# --- Validación de entrada (defensa en profundidad: también protege AD, LDAP y los informes HTML) ---

function Test-LcPersonName {
    param([string]$Value)
    return ($Value -match '^[\p{L}][\p{L}\p{M} ''\-\.]{0,63}$')
}

function Test-LcTitle {
    param([string]$Value)
    return ($Value -match '^[\p{L}\p{M}\p{N}][\p{L}\p{M}\p{N} ''\-\.,/&()]{1,63}$')
}

function Test-LcSimpleId {
    # Nº de empleado / ticket
    param([string]$Value, [int]$MaxLength = 32)
    return ($Value -match ('^[A-Za-z0-9][A-Za-z0-9\-_#\./]{0,' + ($MaxLength - 1) + '}$'))
}

function Test-LcSamAccountName {
    param([string]$Value)
    return ($Value -match '^[A-Za-z0-9][A-Za-z0-9\.\-_]{0,19}$')
}

function ConvertTo-LcDate {
    # Acepta 'yyyy-MM-dd' o 'dd/MM/yyyy'. Devuelve $null si está vacío; lanza si no es válida.
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $formats = [string[]]@('yyyy-MM-dd', 'dd/MM/yyyy', 'd/M/yyyy')
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($Value.Trim(), $formats, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed.Date
    }
    throw "Fecha no válida: '$Value' (usa AAAA-MM-DD o DD/MM/AAAA)."
}
