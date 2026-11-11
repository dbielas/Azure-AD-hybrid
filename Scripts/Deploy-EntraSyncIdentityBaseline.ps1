<#
.SYNOPSIS
    Master Tier-0 Identity Baseline Provisioning for Entra Connect Sync.
.DESCRIPTION
    1. Builds organizational unit structures (Synced_Objects/Shared_Resources/Service_Accounts).
    2. Provisions 'svc-entrasync' with a 32-character complex password.
    3. Hardens the account (LogonWorkstations restrictions; excluded from Protected Users to preserve DRS/delegation).
    4. Exports encrypted credentials to CLIXML for installation staging.
    5. Imports AdSyncConfig and stamps least-privilege ACLs (Read, PHS, SSPR Writeback).
.NOTES
    Target Host: DC01 (10.0.2.4)
    Execution Context: Domain Admin / Tier-0 Privileged Admin
#>

# Ensure script halts immediately on any error
$ErrorActionPreference = 'Stop'

# Define Identity & Path Parameters
$AccountName   = "svc-entrasync"
$DisplayName   = "svc-entrasync (Entra Connect Sync Engine)"
$Description   = "Tier-0 Service Account for Entra Connect Sync Engine (ENTRA-SYNC01 / 10.0.2.5)"

$DomainDN      = (Get-ADDomain).DistinguishedName
$DomainNetBIOS = (Get-ADDomain).NetBIOSName

# AD Structure Paths
$BaseOUPath   = "OU=Synced_Objects,$DomainDN"
$SharedOUPath = "OU=Shared_Resources,$BaseOUPath"
$TargetOU     = "OU=Service_Accounts,$SharedOUPath"
$SSPROU       = "OU=Users,OU=Synced_Objects,$DomainDN"

# Module Staging Path
$AdSyncModulePath = "C:\Users\Administrator\Downloads\AdSyncConfig\AdSyncConfig.psm1"

# -------------------------------------------------------------------------
# STEP 1: IMPORT ADSYNC MODULE & BUILD OU HIERARCHY
# -------------------------------------------------------------------------
Write-Host "`n[+] Importing AdSyncConfig module..." -ForegroundColor Cyan
if (Test-Path $AdSyncModulePath) {
    Import-Module $AdSyncModulePath -Force
} else {
    throw "AdSyncConfig module not found at: $AdSyncModulePath"
}

if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$BaseOUPath'")) {
    Write-Host "[+] Creating root OU: $BaseOUPath" -ForegroundColor Cyan
    New-ADOrganizationalUnit -Name "Synced_Objects" -Path $DomainDN -ProtectedFromAccidentalDeletion $true
}

if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$SharedOUPath'")) {
    Write-Host "[+] Creating sub-OU: $SharedOUPath" -ForegroundColor Cyan
    New-ADOrganizationalUnit -Name "Shared_Resources" -Path $BaseOUPath -ProtectedFromAccidentalDeletion $true
}

if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$TargetOU'")) {
    Write-Host "[+] Creating target OU: $TargetOU" -ForegroundColor Cyan
    New-ADOrganizationalUnit -Name "Service_Accounts" -Path $SharedOUPath -ProtectedFromAccidentalDeletion $true
}

# -------------------------------------------------------------------------
# STEP 2: GENERATE CREDENTIALS & CREATE SERVICE ACCOUNT
# -------------------------------------------------------------------------
$RandomBytes = New-Object Byte[] 24
(New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($RandomBytes)
$ComplexPassword = [Convert]::ToBase64String($RandomBytes) + "!aA9#"
$SecurePassword  = ConvertTo-SecureString $ComplexPassword -AsPlainText -Force

$ExistingUser = Get-ADUser -Filter "SamAccountName -eq '$AccountName'" -ErrorAction SilentlyContinue

if (-not $ExistingUser) {
    Write-Host "[+] Creating AD User: $AccountName..." -ForegroundColor Cyan
    
    New-ADUser -SamAccountName $AccountName `
               -UserPrincipalName "$AccountName@$((Get-ADDomain).DNSRoot)" `
               -Name $AccountName `
               -DisplayName $DisplayName `
               -Description $Description `
               -Path $TargetOU `
               -AccountPassword $SecurePassword `
               -Enabled $true `
               -PasswordNeverExpires $true `
               -CannotChangePassword $true
        
    Write-Host "[✓] Account $AccountName successfully created." -ForegroundColor Green
} else {
    Write-Host "[!] Account $AccountName already exists. Skipping creation." -ForegroundColor Yellow
}

# -------------------------------------------------------------------------
# STEP 3: TIER-0 HARDENING & RESTRICTIONS
# -------------------------------------------------------------------------
Write-Host "[+] Restricting logon paths for $AccountName to ENTRA-SYNC01 and DC01..." -ForegroundColor Cyan
Set-ADUser -Identity $AccountName -LogonWorkstations "ENTRA-SYNC01,DC01"

# Export encrypted credential XML for staging
$ExportDir = if ($PSScriptRoot) { $PSScriptRoot } else { "C:\Users\Administrator\Downloads" }
$CredentialPath = Join-Path -Path $ExportDir -ChildPath "svc-entrasync-cred.xml"

$Credential = New-Object System.Management.Automation.PSCredential ("$DomainNetBIOS\$AccountName", $SecurePassword)
$Credential | Export-Clixml -Path $CredentialPath
Write-Host "[✓] Credential XML exported to: $CredentialPath" -ForegroundColor Green

# -------------------------------------------------------------------------
# STEP 4: APPLY LEAST-PRIVILEGE AD DELEGATION (AdSyncConfig)
# -------------------------------------------------------------------------
Write-Host "`n[+] Applying Active Directory Access Control Lists (ACLs)..." -ForegroundColor Cyan

# 1. Basic Read across entire domain
Write-Host "  └─ Setting Basic Read permissions on Domain Root..." -ForegroundColor Gray
Set-ADSyncBasicReadPermissions `
    -ADConnectorAccountName $AccountName `
    -ADConnectorAccountDomain $DomainNetBIOS

# 2. Directory Replication Rights (PHS) at domain root
Write-Host "  └─ Setting Directory Replication permissions (PHS) on Domain Root..." -ForegroundColor Gray
Set-ADSyncPasswordHashSyncPermissions `
    -ADConnectorAccountName $AccountName `
    -ADConnectorAccountDomain $DomainNetBIOS

# 3. SSPR Writeback rights scoped strictly to OU=Users,OU=Synced_Objects
Write-Host "  └─ Setting SSPR Password Writeback permissions on $SSPROU..." -ForegroundColor Gray
Set-ADSyncPasswordWritebackPermissions `
    -ADConnectorAccountName $AccountName `
    -ADConnectorAccountDomain $DomainNetBIOS `
    -ADobjectDN $SSPROU

Write-Host "`n=========================================================================" -ForegroundColor Green
Write-Host " [SUCCESS] Entra Connect Identity & Security Baseline Deployed" -ForegroundColor Green
Write-Host " Service Account: $DomainNetBIOS\$AccountName" -ForegroundColor White
Write-Host " Target OU:      $TargetOU" -ForegroundColor White
Write-Host " SSPR Scope:     $SSPROU" -ForegroundColor White
Write-Host "=========================================================================`n" -ForegroundColor Green
