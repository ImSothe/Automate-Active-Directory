<#
    Launches the local web UI.
        .\scripts\Start-UI.ps1                       # uses config/settings.json (or the Lab example)
        .\scripts\Start-UI.ps1 -ConfigPath C:\cfg\settings.json -Port 9000
#>
[CmdletBinding()]
param([string]$ConfigPath, [int]$Port = 8787, [switch]$NoBrowser)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\UserLifecycle') -Force
if ($ConfigPath) { $null = Initialize-Lifecycle -ConfigPath $ConfigPath } else { $null = Initialize-Lifecycle }
Start-LifecycleWebUI -Port $Port -NoBrowser:$NoBrowser
