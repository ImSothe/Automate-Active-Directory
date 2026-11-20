function Initialize-Lifecycle {
    <#
    .SYNOPSIS
        Carga la configuración y prepara el módulo (modo Lab o ActiveDirectory).
    .DESCRIPTION
        Orden de búsqueda del fichero de configuración si no se indica -ConfigPath:
          1. Variable de entorno USERLIFECYCLE_CONFIG
          2. <repo>/config/settings.json
          3. <repo>/config/settings.example.json (modo Lab de demostración)
        El resto de funciones llaman a Initialize-Lifecycle automáticamente si no se ha hecho.
    .EXAMPLE
        Initialize-Lifecycle -ConfigPath .\config\settings.json
    #>
    [CmdletBinding()]
    param([string]$ConfigPath)

    if (-not $ConfigPath) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $script:ModuleRoot)
        $candidates = @($env:USERLIFECYCLE_CONFIG, (Join-Path $repoRoot 'config/settings.json'), (Join-Path $repoRoot 'config/settings.example.json'))
        $ConfigPath = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        if (-not $ConfigPath) { throw 'No se ha encontrado ninguna configuración. Copia config/settings.example.json a config/settings.json.' }
        if ($ConfigPath -like '*settings.example.json') {
            Write-Warning "Usando la configuración de ejemplo ($ConfigPath). Copia el fichero a config/settings.json para adaptarlo."
        }
    }

    $resolved = (Resolve-Path -LiteralPath $ConfigPath).Path
    $cfg = Read-LcConfig -Path $resolved

    $script:Lc = @{
        Config         = $cfg
        ConfigPath     = $resolved
        Mode           = $cfg.Mode
        CloudConnected = $false
    }

    if ($cfg.Mode -eq 'ActiveDirectory') {
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
            $script:Lc = $null
            throw 'Modo ActiveDirectory: falta el módulo RSAT ActiveDirectory (Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0).'
        }
        Import-Module ActiveDirectory -ErrorAction Stop -Verbose:$false
    }

    if (-not (Test-Path -LiteralPath $cfg.Audit.Path)) { New-Item -ItemType Directory -Path $cfg.Audit.Path -Force | Out-Null }
    if ($cfg.Mode -eq 'Lab') { $null = Read-LcLab }

    [pscustomobject]@{
        Mode         = $cfg.Mode
        Organization = $cfg.Organization
        ConfigPath   = $resolved
        AuditPath    = $cfg.Audit.Path
        GraphEnabled = [bool]$cfg.Graph.Enabled
        Departments  = @($cfg.Departments | ForEach-Object { $_.Name })
    }
}

function Assert-LcInitialized {
    if (-not $script:Lc) { $null = Initialize-Lifecycle }
}
