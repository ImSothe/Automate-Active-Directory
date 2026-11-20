@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Confirmation/-WhatIf is implemented once, in the public commands (New-LifecycleUser,
        # Disable-LifecycleUser, Reset-LifecycleLab...). Private helpers are only called after that
        # decision has been made, so adding ShouldProcess to each of them would prompt twice.
        'PSUseShouldProcessForStateChangingFunctions'
        # Private helper names such as Get-LcSamCandidates / Set-LcSecurityHeaders read better in plural.
        'PSUseSingularNouns'
        # Write-Host is used on purpose for the interactive console banner and the smoke test output.
        'PSAvoidUsingWriteHost'
    )
}
