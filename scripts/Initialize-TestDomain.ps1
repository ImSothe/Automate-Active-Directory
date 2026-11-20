<#
.SYNOPSIS
    Prepares a TEST domain with everything settings.json expects: OUs, groups, shared folders
    and (optionally) the sample users used in the demos.

.DESCRIPTION
    ⚠️ LAB ONLY. Run it on the domain controller of a test domain (it creates SMB shares and
    folders on the local machine when the configured UNC paths point to it).

    It is idempotent: run it as many times as you want, it only creates what is missing.
    Use -WhatIf first to see what it would do.

.EXAMPLE
    .\scripts\Initialize-TestDomain.ps1 -WhatIf
.EXAMPLE
    .\scripts\Initialize-TestDomain.ps1 -WithSampleUsers
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\settings.json'),
    # Local folder where the SMB shares are created when the UNC paths point to this server
    [string]$SharesRoot = 'C:\Shares',
    # Also creates jgarcia, aruiz and lmartinez using the tool itself (good first end-to-end test)
    [switch]$WithSampleUsers
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..\src\UserLifecycle') -Force
$null = Initialize-Lifecycle -ConfigPath $ConfigPath
$cfg = & (Get-Module UserLifecycle) { $script:Lc.Config }

if ($cfg.Mode -ne 'ActiveDirectory') { throw "settings.json must have ""Mode"": ""ActiveDirectory"" (current: $($cfg.Mode))." }

$domain = Get-ADDomain
$domainDn = $domain.DistinguishedName
Write-Host "Domain: $($domain.DNSRoot) ($domainDn)" -ForegroundColor Cyan

foreach ($dn in @($cfg.Domain.UsersBaseOU, $cfg.Domain.ArchiveOU) + @($cfg.Departments | ForEach-Object { $_.OU })) {
    if ($dn -notlike "*,$domainDn") {
        throw "The OU '$dn' in settings.json does not belong to this domain ($domainDn). Fix the DC=... parts of the config."
    }
}

function Test-OU([string]$Dn) {
    try { $null = Get-ADOrganizationalUnit -Identity $Dn; return $true } catch { return $false }
}

function New-OUPath {
    # Creates an OU and its missing parents (e.g. OU=Ventas,OU=Usuarios,DC=...)
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Dn)
    if ($Dn -eq $domainDn -or (Test-OU $Dn)) { return }
    if ($Dn -notmatch '^OU=((?:\\.|[^,\\])+),(.+)$') { throw "Not an OU DN: $Dn" }
    $name = $Matches[1] -replace '\\(.)', '$1'
    $parent = $Matches[2]
    New-OUPath $parent
    if ($PSCmdlet.ShouldProcess($Dn, 'Create OU')) {
        # Not protected from accidental deletion: it's a lab, you'll want to clean it up
        New-ADOrganizationalUnit -Name $name -Path $parent -ProtectedFromAccidentalDeletion $false
        Write-Host "  + OU $Dn" -ForegroundColor Green
    }
}

# 1) UPN suffix (so jgarcia@contoso.com is a valid sign-in name)
Write-Host "`n[1/5] UPN suffix" -ForegroundColor Cyan
$forest = Get-ADForest
$suffix = $cfg.Domain.UpnSuffix
if ($suffix -ne $forest.RootDomain -and $forest.UPNSuffixes -notcontains $suffix) {
    if ($PSCmdlet.ShouldProcess($forest.Name, "Add UPN suffix $suffix")) {
        Set-ADForest -Identity $forest -UPNSuffixes @{ Add = $suffix }
        Write-Host "  + UPN suffix $suffix" -ForegroundColor Green
    }
}
else { Write-Host "  = $suffix already available" }

# 2) OUs
Write-Host "`n[2/5] Organizational units" -ForegroundColor Cyan
$groupsOu = "OU=Grupos,$domainDn"
foreach ($dn in @($cfg.Domain.UsersBaseOU, $cfg.Domain.ArchiveOU, $groupsOu) + @($cfg.Departments | ForEach-Object { $_.OU })) {
    New-OUPath $dn
}

# 3) Groups (global security groups)
Write-Host "`n[3/5] Groups" -ForegroundColor Cyan
$groupNames = @($cfg.BaseGroups) + @($cfg.Departments | ForEach-Object { $_.Groups }) + @($cfg.TitleRules | ForEach-Object { $_.Groups })
foreach ($g in ($groupNames | Where-Object { $_ } | Select-Object -Unique)) {
    $escaped = & (Get-Module UserLifecycle) { param($v) ConvertTo-LcLdapValue $v } $g
    if (Get-ADGroup -LDAPFilter "(sAMAccountName=$escaped)") { Write-Host "  = $g"; continue }
    if ($PSCmdlet.ShouldProcess($g, 'Create global security group')) {
        New-ADGroup -Name $g -SamAccountName $g -GroupScope Global -GroupCategory Security -Path $groupsOu -Description 'Created by Initialize-TestDomain.ps1'
        Write-Host "  + $g" -ForegroundColor Green
    }
}

# 4) Shared folders (only those whose UNC server is this machine)
Write-Host "`n[4/5] Shared folders" -ForegroundColor Cyan
$me = @($env:COMPUTERNAME, "$env:COMPUTERNAME.$($domain.DNSRoot)", 'localhost') | ForEach-Object { $_.ToLowerInvariant() }
$uncPaths = @($cfg.Departments | ForEach-Object { $_.Shares | ForEach-Object { $_.Path } })
if ($cfg.HomeFolder.Enabled) { $uncPaths += $cfg.HomeFolder.Root }
$shares = @{}
foreach ($unc in ($uncPaths | Select-Object -Unique)) {
    if ($unc -notmatch '^\\\\([^\\]+)\\([^\\]+)(\\.*)?$') { Write-Warning "  ! Not a UNC path: $unc"; continue }
    $server = $Matches[1].ToLowerInvariant(); $share = $Matches[2]; $sub = $Matches[3]
    if ($me -notcontains $server) { Write-Warning "  ! $unc points to '$server', not to this machine ($env:COMPUTERNAME). Skipped."; continue }
    $local = Join-Path $SharesRoot ($share.TrimEnd('$'))
    $shares[$share] = $local
    if (-not (Test-Path $local) -and $PSCmdlet.ShouldProcess($local, 'Create share root with locked-down NTFS')) {
        New-Item -ItemType Directory -Path $local -Force | Out-Null
        # No inherited "Users: Read" from C:\ -> only Administrators + SYSTEM (inherited by subfolders)
        # and Authenticated Users may only list the root. Access to each folder is what the tool grants.
        # SIDs instead of names so it also works on a Spanish Windows ("Administradores", "Usuarios autentificados").
        & icacls.exe $local /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-11:RX' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls failed on $local" }
        Write-Host "  + folder $local (NTFS: Administrators/SYSTEM only)" -ForegroundColor Green
    }
    $folder = if ($sub) { Join-Path $local $sub.TrimStart('\') } else { $local }
    if (-not (Test-Path $folder) -and $PSCmdlet.ShouldProcess($folder, 'Create folder')) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Write-Host "  + folder $folder" -ForegroundColor Green
    }
}
foreach ($share in $shares.Keys) {
    if (Get-SmbShare -Name $share -ErrorAction SilentlyContinue) { Write-Host "  = share \\$env:COMPUTERNAME\$share"; continue }
    if ($PSCmdlet.ShouldProcess("\\$env:COMPUTERNAME\$share", 'Create SMB share')) {
        if (-not (Test-Path $shares[$share])) { New-Item -ItemType Directory -Path $shares[$share] -Force | Out-Null }
        # Share permission wide open to authenticated users; the real control is NTFS (best practice)
        New-SmbShare -Name $share -Path $shares[$share] -FullAccess 'Authenticated Users' | Out-Null
        Write-Host "  + share \\$env:COMPUTERNAME\$share -> $($shares[$share])" -ForegroundColor Green
    }
}

# 5) Sample users, created WITH THE TOOL ITSELF (first real end-to-end test)
Write-Host "`n[5/5] Sample users" -ForegroundColor Cyan
if (-not $WithSampleUsers) { Write-Host '  (skipped: use -WithSampleUsers)' }
else {
    $depts = @($cfg.Departments)
    $samples = @(
        @{ GivenName = 'José'; Surname = 'García Pérez'; Department = $depts[0].Name; Title = 'Comercial' }
        @{ GivenName = 'Ana'; Surname = 'Ruiz Martín'; Department = $depts[[Math]::Min(1, $depts.Count - 1)].Name; Title = 'Técnica de Marketing' }
        @{ GivenName = 'Luis'; Surname = 'Martínez Soto'; Department = $depts[[Math]::Min(2, $depts.Count - 1)].Name; Title = 'Jefe de Sistemas' }
    )
    foreach ($s in $samples) {
        $existing = Find-LifecycleUser -Search "$($s.GivenName) $($s.Surname)"
        if ($existing) { Write-Host "  = $($s.GivenName) $($s.Surname) already exists"; continue }
        if ($PSCmdlet.ShouldProcess("$($s.GivenName) $($s.Surname)", 'Onboard sample user with New-LifecycleUser')) {
            $r = New-LifecycleUser @s -Ticket 'LAB-SEED' -CloudWaitSeconds 0 -Confirm:$false
            Write-Host ("  + {0,-10} {1}  [{2}]" -f $r.SamAccountName, $r.DisplayName, $r.Status) -ForegroundColor Green
        }
    }
}

Write-Host "`nDone. Next: .\scripts\Start-UI.ps1" -ForegroundColor Cyan
