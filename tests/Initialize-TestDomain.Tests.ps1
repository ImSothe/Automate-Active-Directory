#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Tests scripts/Initialize-TestDomain.ps1 against a FAKE, stateful "ActiveDirectory" module
    (OUs, groups, forest UPN suffixes and SMB shares are kept in memory), so the script can be run
    end to end on any OS without a domain controller.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake cmdlets mirror the real signatures.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The icacls.exe stub must set $global:LASTEXITCODE and record its calls globally, like a native command.')]
param()

BeforeAll {
    $script:repo = Split-Path -Parent $PSScriptRoot
    $script:work = Join-Path ([System.IO.Path]::GetTempPath()) ('ulc-init-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $modDir = Join-Path $script:work 'modules/ActiveDirectory'
    New-Item -ItemType Directory -Path $modDir -Force | Out-Null

    # --- Fake ActiveDirectory + SmbShare cmdlets with in-memory state -------------------------
    @'
$script:State = @{ OUs = [System.Collections.Generic.List[string]]::new(); Groups = [System.Collections.Generic.List[string]]::new(); Suffixes = [System.Collections.Generic.List[string]]::new(); Shares = @{} }
function Reset-FakeAD { $script:State.OUs.Clear(); $script:State.Groups.Clear(); $script:State.Suffixes.Clear(); $script:State.Shares.Clear() }
function Get-FakeADState { $script:State }
function Get-ADDomain { [pscustomobject]@{ DistinguishedName = 'DC=contoso,DC=local'; DNSRoot = 'contoso.local' } }
function Get-ADForest { [pscustomobject]@{ Name = 'contoso.local'; RootDomain = 'contoso.local'; UPNSuffixes = @($script:State.Suffixes) } }
function Set-ADForest { param($Identity, $UPNSuffixes) $script:State.Suffixes.Add($UPNSuffixes.Add) }
function Get-ADOrganizationalUnit { param($Identity) if ($script:State.OUs -notcontains $Identity) { throw "Directory object not found: $Identity" } [pscustomobject]@{ DistinguishedName = $Identity } }
function New-ADOrganizationalUnit {
    param($Name, $Path, $ProtectedFromAccidentalDeletion)
    if ($Path -ne 'DC=contoso,DC=local' -and $script:State.OUs -notcontains $Path) { throw "Parent does not exist: $Path" }
    $script:State.OUs.Add("OU=$Name,$Path")
}
function Get-ADGroup { param($LDAPFilter) if ($LDAPFilter -match '^\(sAMAccountName=(.+)\)$' -and $script:State.Groups -contains $Matches[1]) { [pscustomobject]@{ Name = $Matches[1] } } }
function New-ADGroup {
    param($Name, $SamAccountName, $GroupScope, $GroupCategory, $Path, $Description)
    if ($script:State.OUs -notcontains $Path) { throw "Group OU does not exist: $Path" }
    $script:State.Groups.Add($Name)
}
function Get-SmbShare { param($Name, $ErrorAction) if ($script:State.Shares.ContainsKey($Name)) { [pscustomobject]@{ Name = $Name } } }
function New-SmbShare { param($Name, $Path, $FullAccess) $script:State.Shares[$Name] = $Path; [pscustomobject]@{ Name = $Name } }
'@ | Set-Content -Path (Join-Path $modDir 'ActiveDirectory.psm1') -Encoding UTF8

    $script:oldModulePath = $env:PSModulePath
    $script:oldComputer = $env:COMPUTERNAME
    $env:PSModulePath = (Join-Path $script:work 'modules') + [System.IO.Path]::PathSeparator + $env:PSModulePath
    $env:COMPUTERNAME = 'DC01'
    Import-Module ActiveDirectory -Force

    # icacls.exe stub (functions win over executables in command resolution)
    $global:IcaclsCalls = [System.Collections.Generic.List[string]]::new()
    function global:icacls.exe { $global:IcaclsCalls.Add(($args -join ' ')); $global:LASTEXITCODE = 0 }

    # Lab config pointed at this "DC01"
    $cfg = Get-Content (Join-Path $script:repo 'config/settings.example.json') -Raw | ConvertFrom-Json
    $cfg.Mode = 'ActiveDirectory'
    $cfg.Graph.Enabled = $false
    $cfg.Audit.Path = Join-Path $script:work 'audit'
    $json = ($cfg | ConvertTo-Json -Depth 10) -replace 'fs01\.contoso\.local', 'dc01.contoso.local'
    $script:cfgPath = Join-Path $script:work 'settings.json'
    Set-Content -Path $script:cfgPath -Value $json -Encoding UTF8

    $script:sharesRoot = Join-Path $script:work 'Shares'
    $script:scriptPath = Join-Path $script:repo 'scripts/Initialize-TestDomain.ps1'
}

AfterAll {
    Remove-Item function:global:icacls.exe -ErrorAction SilentlyContinue
    Remove-Module ActiveDirectory, UserLifecycle -Force -ErrorAction SilentlyContinue
    $env:PSModulePath = $script:oldModulePath
    $env:COMPUTERNAME = $script:oldComputer
    Remove-Item -Recurse -Force $script:work -ErrorAction SilentlyContinue
}

Describe 'Initialize-TestDomain.ps1' {
    BeforeEach { Reset-FakeAD; $global:IcaclsCalls.Clear(); Remove-Item $script:sharesRoot -Recurse -Force -ErrorAction SilentlyContinue }

    It 'changes nothing with -WhatIf' {
        & $script:scriptPath -ConfigPath $script:cfgPath -SharesRoot $script:sharesRoot -WhatIf 6>$null
        (Get-FakeADState).OUs | Should -HaveCount 0
        (Get-FakeADState).Groups | Should -HaveCount 0
        Test-Path $script:sharesRoot | Should -BeFalse
    }

    Context 'real run' {
        BeforeEach { & $script:scriptPath -ConfigPath $script:cfgPath -SharesRoot $script:sharesRoot 6>$null }

        It 'creates the OU tree parents first' {
            $ous = (Get-FakeADState).OUs
            $ous | Should -Contain 'OU=Usuarios,DC=contoso,DC=local'
            $ous | Should -Contain 'OU=Ventas,OU=Usuarios,DC=contoso,DC=local'
            $ous | Should -Contain 'OU=Bajas,DC=contoso,DC=local'
            $ous | Should -Contain 'OU=Grupos,DC=contoso,DC=local'
            $ous.IndexOf('OU=Usuarios,DC=contoso,DC=local') | Should -BeLessThan $ous.IndexOf('OU=Ventas,OU=Usuarios,DC=contoso,DC=local')
        }

        It 'creates every group referenced by the config' {
            $groups = (Get-FakeADState).Groups
            foreach ($g in 'GG-Todos', 'GG-Ventas', 'GG-CRM', 'GG-Finanzas', 'GG-Responsables', 'GG-Becarios', 'GG-VPN', 'GG-Direccion') {
                $groups | Should -Contain $g
            }
        }

        It 'adds the UPN suffix' {
            (Get-FakeADState).Suffixes | Should -Contain 'contoso.com'
        }

        It 'creates shares, department folders and locks down NTFS on share roots' {
            (Get-FakeADState).Shares.Keys | Should -Contain 'Departamentos'
            (Get-FakeADState).Shares.Keys | Should -Contain 'home$'
            Test-Path (Join-Path $script:sharesRoot 'Departamentos/Ventas') | Should -BeTrue
            Test-Path (Join-Path $script:sharesRoot 'home') | Should -BeTrue
            $global:IcaclsCalls | Should -HaveCount 2
            $global:IcaclsCalls[0] | Should -Match '/inheritance:r'
            $global:IcaclsCalls[0] | Should -Match '\*S-1-5-32-544:\(OI\)\(CI\)F'
        }

        It 'is idempotent (second run creates nothing new)' {
            $before = @{ OUs = (Get-FakeADState).OUs.Count; Groups = (Get-FakeADState).Groups.Count; Shares = (Get-FakeADState).Shares.Count }
            $global:IcaclsCalls.Clear()
            & $script:scriptPath -ConfigPath $script:cfgPath -SharesRoot $script:sharesRoot 6>$null
            (Get-FakeADState).OUs.Count | Should -Be $before.OUs
            (Get-FakeADState).Groups.Count | Should -Be $before.Groups
            (Get-FakeADState).Shares.Count | Should -Be $before.Shares
            $global:IcaclsCalls | Should -HaveCount 0
        }
    }

    It 'refuses a config whose OUs belong to another domain' {
        $bad = Join-Path $script:work 'bad.json'
        (Get-Content $script:cfgPath -Raw) -replace 'DC=contoso,DC=local', 'DC=fabrikam,DC=local' | Set-Content $bad -Encoding UTF8
        { & $script:scriptPath -ConfigPath $bad -SharesRoot $script:sharesRoot 6>$null } | Should -Throw '*does not belong to this domain*'
    }
}
