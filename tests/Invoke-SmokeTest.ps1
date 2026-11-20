<#
    End-to-end smoke test in Lab mode. No dependencies (no Pester, no AD, no tenant).
    Runs on Windows PowerShell 5.1 and PowerShell 7 (Windows / Linux / macOS).

        ./tests/Invoke-SmokeTest.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ulc-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null

# Isolated copy of the example config (its own lab DB and audit folder)
$cfg = Get-Content (Join-Path $repo 'config/settings.example.json') -Raw | ConvertFrom-Json
$cfg.Audit.Path = Join-Path $work 'audit'
$cfg.Lab.DataPath = Join-Path $work 'lab.json'
$cfgPath = Join-Path $work 'settings.json'
$cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $cfgPath -Encoding UTF8

Import-Module (Join-Path $repo 'src/UserLifecycle') -Force
$null = Initialize-Lifecycle -ConfigPath $cfgPath

$script:failures = 0
$script:passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:passed++; Write-Host "  [PASS] $Message" -ForegroundColor Green }
    else { $script:failures++; Write-Host "  [FAIL] $Message" -ForegroundColor Red }
}
function Get-Pw($secure) { (New-Object System.Net.NetworkCredential('', $secure)).Password }

$mod = Get-Module UserLifecycle

Write-Host "`nNaming" -ForegroundColor Cyan
$c = & $mod { @(Get-LcSamCandidates -GivenName 'José María' -Surname 'Fernández de la Vega' -MaxLength 20) }
Assert-True ($c[0] -eq 'jfernandez') "First candidate strips accents: $($c[0])"
Assert-True ($c[1] -eq 'jfernandezd') "Second candidate adds 2nd surname initial (particles grouped): $($c[1])"
Assert-True ($c[2] -eq 'jmfernandez') "Third candidate uses 2nd given name: $($c[2])"
$c = & $mod { @(Get-LcSamCandidates -GivenName 'Ñuño' -Surname 'Peña-Ibáñez' -MaxLength 20) }
Assert-True ($c[0] -eq 'npenaibanez') "Ñ and hyphens normalised: $($c[0])"
$c = & $mod { @(Get-LcSamCandidates -GivenName 'Maximiliano' -Surname 'Wolfeschlegelsteinhausen' -MaxLength 20) }
Assert-True (@($c | Where-Object { $_.Length -gt 20 }).Count -eq 0) 'No candidate exceeds 20 chars (sAMAccountName limit)'
Assert-True ((& $mod { Format-LcPersonName 'JUAN DE LA FUENTE' }) -ceq 'Juan de la Fuente') 'ALL CAPS name converted to Title Case keeping particles'
Assert-True ((& $mod { ConvertTo-LcLdapValue 'a*)(uid=*' }) -eq 'a\2a\29\28uid=\2a') 'LDAP filter values are escaped (RFC 4515)'

Write-Host "`nPasswords" -ForegroundColor Cyan
$pws = 1..50 | ForEach-Object { & $mod { New-LcPassword 16 } }
$okComplex = @($pws | Where-Object { $_.Length -eq 16 -and $_ -cmatch '[A-Z]' -and $_ -cmatch '[a-z]' -and $_ -match '\d' -and $_ -match '[^A-Za-z0-9]' }).Count
Assert-True ($okComplex -eq 50) 'All generated passwords meet length + complexity'
Assert-True (@($pws | Select-Object -Unique).Count -eq 50) 'Generated passwords are unique'
Assert-True (@($pws | Where-Object { $_ -cmatch '[0O1lI$`]' }).Count -eq 0) 'No ambiguous characters'

Write-Host "`nOnboarding" -ForegroundColor Cyan
$plan = Get-LifecycleOnboardingPlan -GivenName 'juan' -Surname 'GARCÍA LÓPEZ' -Department 'Ventas' -Title 'Jefe de Ventas'
Assert-True ($plan.CanProceed) 'Plan is valid'
Assert-True ($plan.SamAccountName -eq 'jgarcial') "Collision with existing 'jgarcia' resolved to: $($plan.SamAccountName)"
Assert-True ($plan.DisplayName -ceq 'Juan García López') "Display name normalised: $($plan.DisplayName)"
Assert-True (@($plan.Groups) -contains 'GG-Responsables') 'Title rule Jefe* adds GG-Responsables'
Assert-True (@($plan.Groups)[0] -eq 'GG-Todos') 'Base groups come first'

$r = New-LifecycleUser -GivenName 'Juan' -Surname 'García López' -Department 'Ventas' -Title 'Jefe de Ventas' -Manager 'lmartinez' -EmployeeId 'E-1001' -Ticket 'RRHH-1' -Confirm:$false
Assert-True ($r.Status -eq 'Success') "Onboarding status: $($r.Status)"
Assert-True ((Get-Pw $r.InitialPassword).Length -eq 16) 'Initial password returned as SecureString'
Assert-True (Test-Path $r.ReportPath) 'HTML report generated'
$report = Get-Content $r.ReportPath -Raw
Assert-True ($report -notmatch [regex]::Escape((Get-Pw $r.InitialPassword))) 'Password is NOT in the report'
$jsonReport = Get-Content ($r.ReportPath -replace '\.html$', '.json') -Raw
Assert-True ($jsonReport -notmatch [regex]::Escape((Get-Pw $r.InitialPassword))) 'Password is NOT in the JSON report'
$u = & $mod { Get-LcDirUser 'jgarcial' }
Assert-True ($u.OU -eq 'OU=Ventas,OU=Usuarios,DC=contoso,DC=local') 'User created in department OU'
Assert-True (@($u.MemberOf.Name) -contains 'GG-CRM') 'User added to department groups'
$cloud = & $mod { Get-LcCloudUser 'jgarcial@contoso.com' }
Assert-True ($cloud.UsageLocation -eq 'ES' -and @($cloud.Licenses).Count -eq 1) 'usageLocation set and licence assigned'

$dup = New-LifecycleUser -GivenName 'Otra' -Surname 'Persona' -Department 'Ventas' -Title 'Comercial' -EmployeeId 'E-1001' -Confirm:$false -ErrorAction SilentlyContinue
Assert-True ($dup.Status -eq 'Rejected') 'Duplicate employee ID rejected'

$fin = New-LifecycleUser -GivenName 'Marta' -Surname 'Sanz' -Department 'Finanzas' -Title 'Analista' -Confirm:$false -WarningAction SilentlyContinue
Assert-True ($fin.Status -eq 'Partial') 'Exhausted licence (POWER_BI_PRO) => Partial status'
Assert-True (@($fin.Steps | Where-Object { $_.Name -eq 'Asignar licencia POWER_BI_PRO' -and $_.Status -eq 'Warning' }).Count -eq 1) 'Licence shortage reported as warning step'

$intern = Get-LifecycleOnboardingPlan -GivenName 'Leo' -Surname 'Gil' -Department 'Marketing' -Title 'Becario de Marketing'
Assert-True ((@($intern.Licenses) -join ',') -eq 'O365_BUSINESS_ESSENTIALS') 'Title rule licences override department licences'

$xss = Get-LifecycleOnboardingPlan -GivenName '<script>alert(1)</script>' -Surname 'X' -Department 'Ventas' -Title 'Comercial'
Assert-True (-not $xss.CanProceed) 'Names with HTML/script characters are rejected'

$what = New-LifecycleUser -GivenName 'Ana' -Surname 'Prueba' -Department 'Sistemas' -Title 'Técnica' -WhatIf
Assert-True ($null -eq (& $mod { Get-LcDirUser 'aprueba' })) '-WhatIf does not create anything'

Write-Host "`nPrivileged access guard" -ForegroundColor Cyan
& $mod { $script:Lc.Config.TitleRules += , ([ordered]@{ Match = 'CEO'; Groups = @('Domain Admins'); Licenses = $null }) }
$bad = New-LifecycleUser -GivenName 'Eva' -Surname 'Mal' -Department 'Sistemas' -Title 'CEO' -Confirm:$false -ErrorAction SilentlyContinue
Assert-True ($bad.Status -eq 'Rejected') 'Onboarding into Domain Admins is blocked'
Assert-True ($null -eq (& $mod { Get-LcDirUser 'emal' })) 'Nothing was created for the blocked request'
$null = Initialize-Lifecycle -ConfigPath $cfgPath

Write-Host "`nOffboarding" -ForegroundColor Cyan
$off = Disable-LifecycleUser -Identity 'aruiz' -Reason 'Fin de contrato' -Ticket 'RRHH-2' -Confirm:$false
Assert-True ($off.Status -eq 'Success') "Offboarding status: $($off.Status)"
$u = & $mod { Get-LcDirUser 'aruiz' }
Assert-True (-not $u.Enabled) 'Account disabled'
Assert-True ($u.OU -eq 'OU=Bajas,DC=contoso,DC=local') 'Moved to archive OU'
Assert-True (@($u.MemberOf).Count -eq 0) 'All group memberships removed'
Assert-True ($u.Description -like 'BAJA *RRHH-2*Fin de contrato*') "Description stamped: $($u.Description)"
$cloud = & $mod { Get-LcCloudUser 'aruiz@contoso.com' }
Assert-True (@($cloud.Licenses).Count -eq 0) 'Licences released'
$lab = & $mod { Read-LcLab }
Assert-True ($null -ne (@($lab.Tenant.Users) | Where-Object { $_.UserPrincipalName -eq 'aruiz@contoso.com' }).SessionsRevokedAt) 'Cloud sessions revoked'
$json = Get-Content ($off.ReportPath -replace '\.html$', '.json') -Raw | ConvertFrom-Json
Assert-True (@($json.Snapshot.Groups) -contains 'GG-Marketing') 'Snapshot of previous groups kept in report'

$off2 = Disable-LifecycleUser -Identity 'jgarcial' -Confirm:$false
$lab = & $mod { Read-LcLab }
Assert-True (@($lab.Acls | Where-Object { $_.Identity -like '*jgarcial' -and $_.Path -notlike '*home$*' }).Count -eq 0) 'Share ACEs revoked on offboarding'
Assert-True (@($lab.Acls | Where-Object { $_.Identity -like '*jgarcial' -and $_.Path -like '*home$*' }).Count -eq 1) 'Home folder kept for data retention'

$adm = Disable-LifecycleUser -Identity 'Administrator' -Confirm:$false -ErrorAction SilentlyContinue
Assert-True ($adm.Status -eq 'Rejected') 'Built-in Administrator (RID 500) cannot be offboarded'
$nobody = Disable-LifecycleUser -Identity 'noexiste' -Confirm:$false -ErrorAction SilentlyContinue
Assert-True ($nobody.Status -eq 'Rejected') 'Unknown user rejected'

Write-Host "`nAudit log" -ForegroundColor Cyan
$log = @(Get-LifecycleAuditLog -Last 100)
Assert-True ($log.Count -ge 7) "Audit log has $($log.Count) entries"
Assert-True (@($log | Where-Object Status -eq 'Rejected').Count -ge 3) 'Rejected attempts are audited too'
$v = Test-LifecycleAuditLog
Assert-True ($v.Valid) "Hash chain valid: $($v.Message)"
$logPath = Join-Path $cfg.Audit.Path 'audit-log.jsonl'
$lines = [System.IO.File]::ReadAllLines($logPath)
$lines[1] = $lines[1] -replace '"Operator":"[^"]*"', '"Operator":"someone-else"'
[System.IO.File]::WriteAllLines($logPath, $lines)
$v = Test-LifecycleAuditLog
Assert-True (-not $v.Valid -and $v.BrokenAtLine -eq 3) "Tampering detected: $($v.Message)"

Remove-Item -Recurse -Force $work
Write-Host ("`n{0} passed, {1} failed`n" -f $script:passed, $script:failures) -ForegroundColor $(if ($script:failures) { 'Red' } else { 'Green' })
if ($script:failures) { exit 1 }
