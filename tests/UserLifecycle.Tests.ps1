#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Unit + integration tests (Lab mode). Run with: Invoke-Pester ./tests -Output Detailed

BeforeAll {
    $script:repo = Split-Path -Parent $PSScriptRoot
    $script:work = Join-Path ([System.IO.Path]::GetTempPath()) ('ulc-pester-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:work | Out-Null

    $cfg = Get-Content (Join-Path $script:repo 'config/settings.example.json') -Raw | ConvertFrom-Json
    $cfg.Audit.Path = Join-Path $script:work 'audit'
    $cfg.Lab.DataPath = Join-Path $script:work 'lab.json'
    $script:cfgPath = Join-Path $script:work 'settings.json'
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $script:cfgPath -Encoding UTF8

    Import-Module (Join-Path $script:repo 'src/UserLifecycle') -Force
    $null = Initialize-Lifecycle -ConfigPath $script:cfgPath

    function Get-PlainPassword($secure) { (New-Object System.Net.NetworkCredential('', $secure)).Password }
}

AfterAll {
    Remove-Module UserLifecycle -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $script:work -ErrorAction SilentlyContinue
}

Describe 'Account naming' {
    It 'generates <Expected> for <Given> <Surname>' -TestCases @(
        @{ Given = 'José María'; Surname = 'Fernández de la Vega'; Expected = 'jfernandez' }
        @{ Given = 'Ñuño'; Surname = 'Peña-Ibáñez'; Expected = 'npenaibanez' }
        @{ Given = 'Ana'; Surname = 'de la Fuente García'; Expected = 'adelafuente' }
        @{ Given = 'Zoë'; Surname = "O'Connor"; Expected = 'zoconnor' }
    ) {
        InModuleScope UserLifecycle -Parameters @{ G = $Given; S = $Surname; E = $Expected } {
            @(Get-LcSamCandidates -GivenName $G -Surname $S)[0] | Should -Be $E
        }
    }

    It 'never exceeds the 20-character sAMAccountName limit' {
        InModuleScope UserLifecycle {
            $c = @(Get-LcSamCandidates -GivenName 'Maximiliano' -Surname 'Wolfeschlegelsteinhausen Bergerdorff')
            ($c | Where-Object { $_.Length -gt 20 }) | Should -BeNullOrEmpty
            $c | Select-Object -Unique | Should -HaveCount $c.Count
        }
    }

    It 'normalises ALL CAPS names keeping particles lowercase' {
        InModuleScope UserLifecycle { Format-LcPersonName 'JUAN DE LA FUENTE' | Should -BeExactly 'Juan de la Fuente' }
    }

    It 'escapes LDAP filter values (RFC 4515)' {
        InModuleScope UserLifecycle { ConvertTo-LcLdapValue 'a*)(uid=*\' | Should -Be 'a\2a\29\28uid=\2a\5c' }
    }
}

Describe 'Password generation' {
    It 'produces unique, complex passwords without ambiguous characters' {
        $pws = InModuleScope UserLifecycle { 1..40 | ForEach-Object { New-LcPassword 16 } }
        $pws | Select-Object -Unique | Should -HaveCount 40
        foreach ($p in $pws) {
            $p.Length | Should -Be 16
            $p | Should -MatchExactly '[A-Z]'
            $p | Should -MatchExactly '[a-z]'
            $p | Should -Match '\d'
            $p | Should -Match '[^A-Za-z0-9]'
            $p | Should -Not -MatchExactly '[0O1lI$`]'
        }
    }
}

Describe 'Onboarding' {
    It 'resolves name collisions and applies title rules' {
        $plan = Get-LifecycleOnboardingPlan -GivenName 'juan' -Surname 'GARCÍA LÓPEZ' -Department 'Ventas' -Title 'Jefe de Ventas'
        $plan.CanProceed | Should -BeTrue
        $plan.SamAccountName | Should -Be 'jgarcial'
        $plan.DisplayName | Should -BeExactly 'Juan García López'
        $plan.Groups | Should -Contain 'GG-Responsables'
        $plan.Groups[0] | Should -Be 'GG-Todos'
    }

    It 'lets a title rule override department licences' {
        $plan = Get-LifecycleOnboardingPlan -GivenName 'Leo' -Surname 'Gil' -Department 'Marketing' -Title 'Becario de Marketing'
        $plan.Licenses | Should -Be @('O365_BUSINESS_ESSENTIALS')
    }

    It 'rejects names containing markup' {
        $plan = Get-LifecycleOnboardingPlan -GivenName '<script>' -Surname 'X' -Department 'Ventas' -Title 'Comercial'
        $plan.CanProceed | Should -BeFalse
    }

    It 'does not create anything with -WhatIf' {
        $null = New-LifecycleUser -GivenName 'Ana' -Surname 'Prueba' -Department 'Sistemas' -Title 'Técnica' -WhatIf
        InModuleScope UserLifecycle { Get-LcDirUser 'aprueba' | Should -BeNullOrEmpty }
    }

    Context 'successful onboarding' {
        BeforeAll {
            $script:r = New-LifecycleUser -GivenName 'Juan' -Surname 'García López' -Department 'Ventas' -Title 'Jefe de Ventas' -Manager 'lmartinez' -EmployeeId 'E-1001' -Ticket 'RRHH-1' -Confirm:$false
        }

        It 'succeeds' { $script:r.Status | Should -Be 'Success' }

        It 'creates the user in the department OU with its groups' {
            InModuleScope UserLifecycle {
                $u = Get-LcDirUser 'jgarcial'
                $u.OU | Should -Be 'OU=Ventas,OU=Usuarios,DC=contoso,DC=local'
                $u.MemberOf.Name | Should -Contain 'GG-CRM'
            }
        }

        It 'assigns usage location and licence in Entra ID' {
            InModuleScope UserLifecycle {
                $c = Get-LcCloudUser 'jgarcial@contoso.com'
                $c.UsageLocation | Should -Be 'ES'
                $c.Licenses | Should -HaveCount 1
            }
        }

        It 'never writes the initial password to the reports' {
            $pw = Get-PlainPassword $script:r.InitialPassword
            $pw.Length | Should -Be 16
            (Get-Content $script:r.ReportPath -Raw) | Should -Not -Match ([regex]::Escape($pw))
            (Get-Content ($script:r.ReportPath -replace '\.html$', '.json') -Raw) | Should -Not -Match ([regex]::Escape($pw))
        }

        It 'rejects a duplicated employee ID' {
            $dup = New-LifecycleUser -GivenName 'Otra' -Surname 'Persona' -Department 'Ventas' -Title 'Comercial' -EmployeeId 'E-1001' -Confirm:$false -ErrorAction SilentlyContinue
            $dup.Status | Should -Be 'Rejected'
        }
    }

    It 'reports Partial when a licence has no free units' {
        $r = New-LifecycleUser -GivenName 'Marta' -Surname 'Sanz' -Department 'Finanzas' -Title 'Analista' -Confirm:$false -WarningAction SilentlyContinue
        $r.Status | Should -Be 'Partial'
        ($r.Steps | Where-Object { $_.Name -eq 'Asignar licencia POWER_BI_PRO' }).Status | Should -Be 'Warning'
    }

    It 'blocks onboarding into privileged groups' {
        InModuleScope UserLifecycle { $script:Lc.Config.TitleRules += , ([ordered]@{ Match = 'CEO'; Groups = @('Domain Admins'); Licenses = $null }) }
        $r = New-LifecycleUser -GivenName 'Eva' -Surname 'Mal' -Department 'Sistemas' -Title 'CEO' -Confirm:$false -ErrorAction SilentlyContinue
        $r.Status | Should -Be 'Rejected'
        InModuleScope UserLifecycle { Get-LcDirUser 'emal' | Should -BeNullOrEmpty }
        $null = Initialize-Lifecycle -ConfigPath $script:cfgPath
    }
}

Describe 'Offboarding' {
    BeforeAll {
        $script:off = Disable-LifecycleUser -Identity 'aruiz' -Reason 'Fin de contrato' -Ticket 'RRHH-2' -Confirm:$false
    }

    It 'succeeds' { $script:off.Status | Should -Be 'Success' }

    It 'disables, strips groups and archives the account' {
        InModuleScope UserLifecycle {
            $u = Get-LcDirUser 'aruiz'
            $u.Enabled | Should -BeFalse
            $u.OU | Should -Be 'OU=Bajas,DC=contoso,DC=local'
            $u.MemberOf | Should -BeNullOrEmpty
            $u.Description | Should -BeLike 'BAJA *RRHH-2*Fin de contrato*'
        }
    }

    It 'releases licences and revokes cloud sessions' {
        InModuleScope UserLifecycle {
            (Get-LcCloudUser 'aruiz@contoso.com').Licenses | Should -BeNullOrEmpty
            $t = @((Read-LcLab).Tenant.Users) | Where-Object { $_.UserPrincipalName -eq 'aruiz@contoso.com' }
            $t.SessionsRevokedAt | Should -Not -BeNullOrEmpty
        }
    }

    It 'keeps a snapshot of the previous state' {
        $json = Get-Content ($script:off.ReportPath -replace '\.html$', '.json') -Raw | ConvertFrom-Json
        $json.Snapshot.Groups | Should -Contain 'GG-Marketing'
    }

    It 'refuses to offboard the built-in Administrator' {
        (Disable-LifecycleUser -Identity 'Administrator' -Confirm:$false -ErrorAction SilentlyContinue).Status | Should -Be 'Rejected'
    }
}

Describe 'Audit log' {
    It 'records every operation, including rejected ones' {
        $log = @(Get-LifecycleAuditLog -Last 100)
        $log.Count | Should -BeGreaterOrEqual 5
        @($log | Where-Object Status -eq 'Rejected').Count | Should -BeGreaterOrEqual 2
    }

    It 'has a valid hash chain' {
        (Test-LifecycleAuditLog).Valid | Should -BeTrue
    }

    It 'detects tampering' {
        $path = Join-Path (Join-Path $script:work 'audit') 'audit-log.jsonl'
        $lines = [System.IO.File]::ReadAllLines($path)
        $lines[0] = $lines[0] -replace '"Operator":"[^"]*"', '"Operator":"someone-else"'
        [System.IO.File]::WriteAllLines($path, $lines)
        $v = Test-LifecycleAuditLog
        $v.Valid | Should -BeFalse
        $v.BrokenAtLine | Should -Be 2
    }
}
