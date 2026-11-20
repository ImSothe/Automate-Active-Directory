@{
    RootModule           = 'UserLifecycle.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '5d0f3c1e-8a4b-4f6e-9b1a-2f7c6d9e4a10'
    Author               = 'Sothe'
    Description          = 'Automatiza altas y bajas de usuarios: Active Directory, grupos, carpetas compartidas, licencias de Microsoft 365 (Graph) y auditoría.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
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
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('ActiveDirectory', 'EntraID', 'MicrosoftGraph', 'Onboarding', 'Offboarding', 'IAM', 'AZ-104')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
