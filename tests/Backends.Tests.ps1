#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Tests for the real backends (Active Directory and Microsoft Graph) WITHOUT a domain or tenant.
    The RSAT / Graph cmdlets are replaced by stubs + Pester mocks, so we can assert exactly which
    calls the module makes and with which parameters.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stubs of RSAT/Graph cmdlets: parameters exist only so Pester mocks can filter on them.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Stub signatures mirror the real AD cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Stub signatures mirror the real AD cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Stubs only declare -WhatIf/-Confirm like the real cmdlets; they never change anything.')]
param()

BeforeAll {
    $script:repo = Split-Path -Parent $PSScriptRoot
    $script:work = Join-Path ([System.IO.Path]::GetTempPath()) ('ulc-backend-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:work | Out-Null

    # --- Stubs: same names/parameters as the real cmdlets (only the ones the module uses) -----
    function global:Get-ADUser { param($Identity, $LDAPFilter, $Properties, $ResultSetSize, $Server) }
    function global:Get-ADObject { param($LDAPFilter, $SearchBase, $SearchScope, $ResultSetSize, $Server) }
    function global:Get-ADGroup { param($Identity, $LDAPFilter, $Properties, $Server) }
    function global:Get-ADOrganizationalUnit { param($Identity, $Server) }
    function global:New-ADUser {
        param($Name, $SamAccountName, $UserPrincipalName, $GivenName, $Surname, $DisplayName, $EmailAddress, $Department,
            $Title, $Company, $Path, $AccountPassword, $Enabled, $ChangePasswordAtLogon, $EmployeeID, $Description,
            $Manager, $HomeDirectory, $HomeDrive, $AccountExpirationDate, $Server)
    }
    function global:Add-ADGroupMember { param($Identity, $Members, $Server) }
    function global:Remove-ADGroupMember { [CmdletBinding(SupportsShouldProcess)] param($Identity, $Members, $Server) }
    function global:Disable-ADAccount { param($Identity, $Server) }
    function global:Set-ADAccountPassword { param($Identity, [switch]$Reset, $NewPassword, $Server) }
    function global:Set-ADUser { param($Identity, $Description, $Server) }
    function global:Move-ADObject { param($Identity, $TargetPath, [switch]$PassThru, $Server) }
    function global:Rename-ADObject { param($Identity, $NewName, [switch]$PassThru, $Server) }
    function global:Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $ErrorAction) }

    Import-Module (Join-Path $script:repo 'src/UserLifecycle') -Force

    # Config in ActiveDirectory mode (loaded directly: Initialize-Lifecycle would require RSAT)
    $cfg = Get-Content (Join-Path $script:repo 'config/settings.example.json') -Raw | ConvertFrom-Json
    $cfg.Mode = 'ActiveDirectory'
    $cfg.Graph.Enabled = $false
    $cfg.HomeFolder.Enabled = $false
    $cfg.Audit.Path = Join-Path $script:work 'audit'
    $cfg.Lab.DataPath = Join-Path $script:work 'lab.json'
    $script:cfgPath = Join-Path $script:work 'settings-ad.json'
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $script:cfgPath -Encoding UTF8
    New-Item -ItemType Directory -Path $cfg.Audit.Path | Out-Null

    InModuleScope UserLifecycle -Parameters @{ P = $script:cfgPath } {
        $script:Lc = @{ Config = (Read-LcConfig -Path $P); ConfigPath = $P; Mode = 'ActiveDirectory'; CloudConnected = $true }
    }

    # Fake AD objects
    $script:DomainSid = 'S-1-5-21-111-222-333'
    function New-FakeAdUser([string]$Sam, [string]$Ou = 'OU=Marketing,OU=Usuarios,DC=contoso,DC=local', [string[]]$MemberOf = @(), [int]$Rid = 1200) {
        [pscustomobject]@{
            SamAccountName = $Sam; UserPrincipalName = "$Sam@contoso.com"; DisplayName = "User $Sam"; GivenName = 'User'; Surname = $Sam
            Department = 'Marketing'; Title = 'Técnica'; EmployeeID = $null; mail = "$Sam@contoso.com"; Enabled = $true
            DistinguishedName = "CN=User $Sam,$Ou"; SID = [pscustomobject]@{ Value = "$($script:DomainSid)-$Rid" }
            adminCount = $null; Description = ''; Manager = $null; AccountExpirationDate = $null; memberOf = $MemberOf
        }
    }
    function New-FakeAdGroup([string]$Name, [int]$Rid = 3000, $AdminCount = $null) {
        [pscustomobject]@{ Name = $Name; DistinguishedName = "CN=$Name,OU=Grupos,DC=contoso,DC=local"; SID = [pscustomobject]@{ Value = "$($script:DomainSid)-$Rid" }; adminCount = $AdminCount }
    }
}

AfterAll {
    Remove-Module UserLifecycle -Force -ErrorAction SilentlyContinue
    foreach ($f in 'Get-ADUser', 'Get-ADObject', 'Get-ADGroup', 'Get-ADOrganizationalUnit', 'New-ADUser', 'Add-ADGroupMember', 'Remove-ADGroupMember',
        'Disable-ADAccount', 'Set-ADAccountPassword', 'Set-ADUser', 'Move-ADObject', 'Rename-ADObject', 'Invoke-MgGraphRequest') {
        Remove-Item "function:global:$f" -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force $script:work -ErrorAction SilentlyContinue
}

Describe 'Active Directory backend: privileged group detection' {
    It 'flags <Name> as privileged=<Expected>' -TestCases @(
        @{ Name = 'Admins. del dominio'; Rid = 512; AdminCount = $null; Expected = $true }   # Domain Admins in a Spanish DC
        @{ Name = 'Administradores de empresas'; Rid = 519; AdminCount = $null; Expected = $true }
        @{ Name = 'GG-Helpdesk-Tier0'; Rid = 4100; AdminCount = 1; Expected = $true }        # protected by AdminSDHolder
        @{ Name = 'GG-Ventas'; Rid = 4200; AdminCount = $null; Expected = $false }
    ) {
        $g = New-FakeAdGroup -Name $Name -Rid $Rid -AdminCount $AdminCount
        Mock Get-ADGroup -ModuleName UserLifecycle { $g }
        $result = InModuleScope UserLifecycle -Parameters @{ N = $Name } { Get-LcDirGroup $N }
        $result.Privileged | Should -Be $Expected
    }

    It 'treats BUILTIN\Administrators (S-1-5-32-544) as privileged' {
        InModuleScope UserLifecycle { Test-LcPrivilegedSid 'S-1-5-32-544' | Should -BeTrue }
    }

    It 'searches groups by DN when given a distinguished name' {
        Mock Get-ADGroup -ModuleName UserLifecycle { New-FakeAdGroup 'GG-Ventas' }
        InModuleScope UserLifecycle { $null = Get-LcDirGroup 'CN=GG-Ventas,OU=Grupos,DC=contoso,DC=local' }
        Should -Invoke Get-ADGroup -ModuleName UserLifecycle -Times 1 -ParameterFilter { $LDAPFilter -like '(distinguishedName=CN=GG-Ventas*' }
    }
}

Describe 'Active Directory backend: LDAP injection' {
    It 'escapes user input in search filters' {
        Mock Get-ADUser -ModuleName UserLifecycle { }
        InModuleScope UserLifecycle { $null = Find-LcDirUser -Search '*)(adminCount=1' }
        Should -Invoke Get-ADUser -ModuleName UserLifecycle -Times 1 -ParameterFilter {
            $LDAPFilter -like '*\2a\29\28adminCount=1*' -and $LDAPFilter -notlike '*(adminCount=1)*'
        }
    }
}

Describe 'Active Directory backend: user creation' {
    BeforeEach {
        Mock New-ADUser -ModuleName UserLifecycle { }
        Mock Get-ADObject -ModuleName UserLifecycle { }
        Mock Get-ADUser -ModuleName UserLifecycle { New-FakeAdUser 'jgarcial' 'OU=Ventas,OU=Usuarios,DC=contoso,DC=local' }
        $script:spec = @{
            SamAccountName = 'jgarcial'; UserPrincipalName = 'jgarcial@contoso.com'; GivenName = 'Juan'; Surname = 'García López'
            DisplayName = 'Juan García López'; Mail = 'jgarcial@contoso.com'; Department = 'Ventas'; Title = 'Comercial'
            EmployeeId = 'E-1'; ManagerDn = 'CN=Boss,OU=Ventas,OU=Usuarios,DC=contoso,DC=local'; EndDate = '2027-06-30'
            OU = 'OU=Ventas,OU=Usuarios,DC=contoso,DC=local'; Description = 'Alta'; HomeDirectory = $null
        }
    }

    It 'calls New-ADUser with the planned attributes' {
        InModuleScope UserLifecycle -Parameters @{ S = $script:spec } {
            $null = New-LcDirUser -Spec $S -Password (ConvertTo-LcSecureString 'x')
        }
        Should -Invoke New-ADUser -ModuleName UserLifecycle -Times 1 -ParameterFilter {
            $Path -eq 'OU=Ventas,OU=Usuarios,DC=contoso,DC=local' -and $SamAccountName -eq 'jgarcial' -and
            $UserPrincipalName -eq 'jgarcial@contoso.com' -and $Name -eq 'Juan García López' -and
            $ChangePasswordAtLogon -eq $true -and $Enabled -eq $true -and $EmployeeID -eq 'E-1' -and
            $Manager -like 'CN=Boss,*' -and $Company -eq 'Contoso Iberia' -and $AccountPassword -is [securestring]
        }
    }

    It 'makes the contract end date inclusive (AD expires at the start of the given day)' {
        InModuleScope UserLifecycle -Parameters @{ S = $script:spec } {
            $null = New-LcDirUser -Spec $S -Password (ConvertTo-LcSecureString 'x')
        }
        Should -Invoke New-ADUser -ModuleName UserLifecycle -Times 1 -ParameterFilter { $AccountExpirationDate -eq [datetime]'2027-07-01' }
    }

    It 'appends the account name to the CN when the OU already has someone with the same name' {
        Mock Get-ADObject -ModuleName UserLifecycle { [pscustomobject]@{ Name = 'Juan García López' } }
        InModuleScope UserLifecycle -Parameters @{ S = $script:spec } {
            $null = New-LcDirUser -Spec $S -Password (ConvertTo-LcSecureString 'x')
        }
        Should -Invoke New-ADUser -ModuleName UserLifecycle -Times 1 -ParameterFilter { $Name -eq 'Juan García López (jgarcial)' }
    }
}

Describe 'Active Directory backend: onboarding plan' {
    BeforeEach {
        Mock Get-ADObject -ModuleName UserLifecycle { }               # account names are free
        Mock Get-ADUser -ModuleName UserLifecycle { }                 # no duplicated employee ID
        Mock Get-ADOrganizationalUnit -ModuleName UserLifecycle { [pscustomobject]@{ Name = 'Ventas' } }
    }

    It 'blocks the plan if a configured group turns out to be privileged in AD' {
        Mock Get-ADGroup -ModuleName UserLifecycle {
            if ($LDAPFilter -like '*GG-CRM*') { New-FakeAdGroup 'GG-CRM' -Rid 4300 -AdminCount 1 } else { New-FakeAdGroup 'GG-x' }
        }
        $plan = InModuleScope UserLifecycle { New-LcOnboardingPlan -GivenName 'Juan' -Surname 'Pérez' -Department 'Ventas' -Title 'Comercial' }
        $plan.CanProceed | Should -BeFalse
        ($plan.Errors -join ' ') | Should -Match 'BLOQUEADO.*GG-CRM'
    }

    It 'fails the plan when the department OU does not exist' {
        Mock Get-ADGroup -ModuleName UserLifecycle { New-FakeAdGroup 'GG-x' }
        Mock Get-ADOrganizationalUnit -ModuleName UserLifecycle { throw 'Directory object not found' }
        $plan = InModuleScope UserLifecycle { New-LcOnboardingPlan -GivenName 'Juan' -Surname 'Pérez' -Department 'Ventas' -Title 'Comercial' }
        $plan.CanProceed | Should -BeFalse
        ($plan.Errors -join ' ') | Should -Match 'OU'
    }

    It 'skips names already used as UPN / mail / proxyAddress' {
        Mock Get-ADGroup -ModuleName UserLifecycle { New-FakeAdGroup 'GG-x' }
        Mock Get-ADObject -ModuleName UserLifecycle { if ($LDAPFilter -like '*(sAMAccountName=jperez)*') { [pscustomobject]@{ Name = 'taken' } } }
        $plan = InModuleScope UserLifecycle { New-LcOnboardingPlan -GivenName 'Juan' -Surname 'Pérez Gil' -Department 'Ventas' -Title 'Comercial' }
        $plan.SamAccountName | Should -Be 'jperezg'
        Should -Invoke Get-ADObject -ModuleName UserLifecycle -ParameterFilter { $LDAPFilter -like '*(proxyAddresses=smtp:jperez@contoso.com)*' }
    }
}

Describe 'Active Directory backend: offboarding' {
    BeforeAll {
        $script:groups = @('CN=GG-Marketing,OU=Grupos,DC=contoso,DC=local', 'CN=GG-VPN,OU=Grupos,DC=contoso,DC=local')
    }
    BeforeEach {
        Mock Get-ADUser -ModuleName UserLifecycle { New-FakeAdUser 'aruiz' -MemberOf $script:groups }
        Mock Get-ADGroup -ModuleName UserLifecycle { New-FakeAdGroup 'GG-x' }
        Mock Get-ADObject -ModuleName UserLifecycle { }
        Mock Disable-ADAccount -ModuleName UserLifecycle { }
        Mock Set-ADAccountPassword -ModuleName UserLifecycle { }
        Mock Remove-ADGroupMember -ModuleName UserLifecycle { }
        Mock Set-ADUser -ModuleName UserLifecycle { }
        Mock Move-ADObject -ModuleName UserLifecycle { [pscustomobject]@{ DistinguishedName = 'CN=User aruiz,OU=Bajas,DC=contoso,DC=local' } }
        Mock Rename-ADObject -ModuleName UserLifecycle { }
    }

    It 'runs every offboarding step against AD' {
        InModuleScope UserLifecycle { $script:Lc.Config.Offboarding.RemoveShareAccess = $false }
        $r = Disable-LifecycleUser -Identity 'aruiz' -Reason 'Fin de contrato' -Ticket 'T-1' -Confirm:$false
        $r.Status | Should -Be 'Success'
        Should -Invoke Disable-ADAccount -ModuleName UserLifecycle -Times 1
        Should -Invoke Set-ADAccountPassword -ModuleName UserLifecycle -Times 1 -ParameterFilter { $Reset -and $NewPassword -is [securestring] }
        Should -Invoke Remove-ADGroupMember -ModuleName UserLifecycle -Times 2 -Exactly
        Should -Invoke Set-ADUser -ModuleName UserLifecycle -Times 1 -ParameterFilter { $Description -like 'BAJA * | T-1 | Fin de contrato | por *' }
        Should -Invoke Move-ADObject -ModuleName UserLifecycle -Times 1 -ParameterFilter { $TargetPath -eq 'OU=Bajas,DC=contoso,DC=local' }
        Should -Invoke Rename-ADObject -ModuleName UserLifecycle -Times 0
    }

    It 'renames before moving if the archive OU already has the same CN' {
        Mock Get-ADObject -ModuleName UserLifecycle { [pscustomobject]@{ Name = 'User aruiz' } }
        Mock Rename-ADObject -ModuleName UserLifecycle { [pscustomobject]@{ DistinguishedName = 'CN=User aruiz (aruiz),OU=Marketing,OU=Usuarios,DC=contoso,DC=local' } }
        InModuleScope UserLifecycle { $null = Move-LcDirUser -SamAccountName 'aruiz' -TargetOU 'OU=Bajas,DC=contoso,DC=local' }
        Should -Invoke Rename-ADObject -ModuleName UserLifecycle -Times 1 -ParameterFilter { $NewName -eq 'User aruiz (aruiz)' }
        Should -Invoke Move-ADObject -ModuleName UserLifecycle -Times 1 -ParameterFilter { $Identity -like 'CN=User aruiz (aruiz),*' }
    }

    It 'refuses the built-in Administrator (RID 500) and changes nothing' {
        Mock Get-ADUser -ModuleName UserLifecycle { New-FakeAdUser 'Administrator' -Rid 500 }
        $r = Disable-LifecycleUser -Identity 'Administrator' -Confirm:$false -ErrorAction SilentlyContinue
        $r.Status | Should -Be 'Rejected'
        Should -Invoke Disable-ADAccount -ModuleName UserLifecycle -Times 0
    }

    It 'continues with the remaining steps if one fails, and reports Partial' {
        Mock Remove-ADGroupMember -ModuleName UserLifecycle { throw 'Insufficient access rights' } -ParameterFilter { $Identity -like 'CN=GG-VPN*' }
        $r = Disable-LifecycleUser -Identity 'aruiz' -Confirm:$false -WarningAction SilentlyContinue
        $r.Status | Should -Be 'Partial'
        ($r.Steps | Where-Object Name -eq 'Quitar del grupo GG-VPN').Status | Should -Be 'Failed'
        Should -Invoke Move-ADObject -ModuleName UserLifecycle -Times 1
    }
}

Describe 'Microsoft Graph backend' {
    BeforeAll {
        $script:userId = '11111111-2222-3333-4444-555555555555'
        $script:e3 = '05e9a617-0261-4cee-bb44-138d3ef5d965'
    }

    It 'looks users up with an OData $filter (and escapes quotes)' {
        Mock Invoke-MgGraphRequest -ModuleName UserLifecycle { @{ value = @() } }
        $u = InModuleScope UserLifecycle { Get-LcCloudUser "o'brien@contoso.com" }
        $u | Should -BeNullOrEmpty
        Should -Invoke Invoke-MgGraphRequest -ModuleName UserLifecycle -Times 1 -ParameterFilter {
            $Method -eq 'GET' -and $Uri -like '/v1.0/users?$filter=*' -and [uri]::UnescapeDataString($Uri) -like "*userPrincipalName eq 'o''brien@contoso.com'*"
        }
    }

    It 'maps assignedLicenses to SKU ids' {
        Mock Invoke-MgGraphRequest -ModuleName UserLifecycle {
            @{ value = @(@{ id = 'abc'; userPrincipalName = 'a@contoso.com'; usageLocation = 'ES'; accountEnabled = $true; assignedLicenses = @(@{ skuId = 'sku-1' }, @{ skuId = 'sku-2' }) }) }
        }
        $u = InModuleScope UserLifecycle { Get-LcCloudUser 'a@contoso.com' }
        $u.Id | Should -Be 'abc'
        $u.Licenses | Should -Be @('sku-1', 'sku-2')
    }

    It 'computes free licences from subscribedSkus' {
        Mock Invoke-MgGraphRequest -ModuleName UserLifecycle {
            @{ value = @(@{ skuId = 'x'; skuPartNumber = 'SPE_E3'; prepaidUnits = @{ enabled = 25 }; consumedUnits = 25 }) }
        }
        $s = InModuleScope UserLifecycle { Get-LcCloudSkus }
        $s.SkuPartNumber | Should -Be 'SPE_E3'
        $s.Available | Should -Be 0
    }

    It 'sends the right body to assignLicense' {
        Mock Invoke-MgGraphRequest -ModuleName UserLifecycle { }
        InModuleScope UserLifecycle -Parameters @{ U = $script:userId; S = $script:e3 } { Add-LcCloudLicense -UserId $U -SkuId $S }
        Should -Invoke Invoke-MgGraphRequest -ModuleName UserLifecycle -Times 1 -ParameterFilter {
            $b = $Body | ConvertFrom-Json
            $Method -eq 'POST' -and $Uri -eq "/v1.0/users/$($script:userId)/assignLicense" -and
            $b.addLicenses[0].skuId -eq $script:e3 -and @($b.removeLicenses).Count -eq 0 -and $ContentType -eq 'application/json'
        }
    }

    It 'removes licences in a single call' {
        Mock Invoke-MgGraphRequest -ModuleName UserLifecycle { }
        InModuleScope UserLifecycle -Parameters @{ U = $script:userId } { Remove-LcCloudLicense -UserId $U -SkuIds @('a', 'b') }
        Should -Invoke Invoke-MgGraphRequest -ModuleName UserLifecycle -Times 1 -ParameterFilter {
            $b = $Body | ConvertFrom-Json
            @($b.removeLicenses) -join ',' -eq 'a,b' -and @($b.addLicenses).Count -eq 0
        }
    }

    It 'revokes sign-in sessions and sets usageLocation' {
        Mock Invoke-MgGraphRequest -ModuleName UserLifecycle { }
        InModuleScope UserLifecycle -Parameters @{ U = $script:userId } {
            Revoke-LcCloudSession -UserId $U
            Set-LcCloudUsageLocation -UserId $U -UsageLocation 'ES'
        }
        Should -Invoke Invoke-MgGraphRequest -ModuleName UserLifecycle -Times 1 -ParameterFilter { $Method -eq 'POST' -and $Uri -eq "/v1.0/users/$($script:userId)/revokeSignInSessions" }
        Should -Invoke Invoke-MgGraphRequest -ModuleName UserLifecycle -Times 1 -ParameterFilter { $Method -eq 'PATCH' -and ($Body | ConvertFrom-Json).usageLocation -eq 'ES' }
    }

    It 'gives up waiting for sync after the timeout and returns nothing' {
        Mock Invoke-MgGraphRequest -ModuleName UserLifecycle { @{ value = @() } }
        $u = InModuleScope UserLifecycle { Wait-LcCloudUser -UserPrincipalName 'new@contoso.com' -TimeoutSeconds 0 }
        $u | Should -BeNullOrEmpty
    }

    It 'leaves the licence step Pending when the user has not synced yet' {
        Mock Invoke-MgGraphRequest -ModuleName UserLifecycle { @{ value = @() } }
        $op = InModuleScope UserLifecycle {
            $op = New-LcOperation -Type 'CloudProvisioning' -InputData @{} -Ticket ''
            Invoke-LcCloudOnboardingSteps -Operation $op -UserPrincipalName 'new@contoso.com' -Licenses @('SPE_E3') -WaitSeconds 0
            $op
        }
        $op.Steps[-1].Status | Should -Be 'Pending'
        $op.Steps[-1].Detail | Should -Match 'Invoke-LifecycleCloudProvisioning -Identity new'
    }
}
