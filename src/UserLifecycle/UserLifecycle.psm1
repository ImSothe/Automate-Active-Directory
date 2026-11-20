#Requires -Version 5.1
<#
    UserLifecycle - Automatizador de altas y bajas de usuarios (Joiner / Leaver)
    Active Directory + carpetas compartidas + Microsoft Graph (Entra ID / Microsoft 365)
#>

Set-StrictMode -Version 1.0

# Estado del módulo: se rellena en Initialize-Lifecycle
$script:Lc = $null
$script:ModuleRoot = $PSScriptRoot

foreach ($folder in 'Private', 'Public') {
    $path = Join-Path $PSScriptRoot $folder
    foreach ($file in (Get-ChildItem -Path $path -Filter '*.ps1' -File | Sort-Object Name)) {
        . $file.FullName
    }
}

Export-ModuleMember -Function @(
    'Initialize-Lifecycle'
    'Get-LifecycleOnboardingPlan'
    'New-LifecycleUser'
    'Get-LifecycleOffboardingPlan'
    'Disable-LifecycleUser'
    'Invoke-LifecycleCloudProvisioning'
    'Find-LifecycleUser'
    'Get-LifecycleAuditLog'
    'Test-LifecycleAuditLog'
    'Reset-LifecycleLab'
    'Start-LifecycleWebUI'
)
