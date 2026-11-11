# Hybrid Account Disable & Deprovisioning Lifecycle Operations Runbook

## 1. Executive Overview & Scope
* **Purpose:** Defines the standardized, deterministic sequence for disabling, deprovisioning, and revoking access for offboarded identities across hybrid Active Directory (`DC01`) and Microsoft Entra ID. It ensures immediate access termination on-premises, rapid cloud session invalidation, and synchronized license reclamation via Entra Connect (`ENTRA-SYNC01`).
* **Target Audience:** Service Desk Analysts, Systems Administrators, Identity Governance & Security Operations (SOC).
* **Scope & Automation:** Covers both standard scheduled offboarding and immediate emergency termination workflows.

---

## 2. Architecture & Deprovisioning Mechanics

### High-Level Offboarding Signal Path
```text
[1. On-Premises Action]          [2. Synchronization Cycle]           [3. Cloud State Enforcement]
 ┌──────────────────────┐         ┌────────────────────────┐         ┌────────────────────────────┐
 │  Move to Disabled OU │         │ ENTRA-SYNC01 (ADSync)  │         │  Microsoft Entra ID Tenant │
 │  Set AccountDisabled │ ──────> │  Delta Import & Sync   │ ──────> │  User Account Disabled     │
 │  Stamp ExtensionAttr │         │  (mS-DS-ConsistencyGuid│         │  Cloud Sessions Revoked    │
 └──────────────────────┘         └────────────────────────┘         └────────────────────────────┘
            │                                                                      │
            ▼                                                                      ▼
  (Clear On-Prem Sessions)                                               (Reclaim M365 Licenses)
```

### Critical State Transitions
* **On-Premises Trigger:** Disabling an account on `DC01` sets bit `0x0002` (`ACCOUNTDISABLE`) in the `userAccountControl` attribute.
* **Cloud Propagation:** Entra Connect evaluates `userAccountControl` during the next Delta Sync cycle and sets `AccountEnabled = $false` on the corresponding Entra ID user object.
* **Scope Exclusion (Hard Delete / Soft Delete):** Moving an account out of the synced OU scope causes Entra Connect to mark the cloud user as a **Soft-Deleted Object** (retained in Entra ID Deleted Users for 30 days).

---

## 3. Account Delegation & On-Premises ACLs

The Entra Connect custom service account (`hybrid.lan\svc-entrasync`) requires explicit read/write access to synced user containers and disabled/staging OUs to manage sync state flags and anchor bindings.

### Required Active Directory Rights
* **Read / Write Property:** `userAccountControl`
* **Write Property:** `mS-DS-ConsistencyGuid`
* **Write Property:** `extensionAttribute1-15` (for offboarding state metadata tagging)

### ACL Verification & Remediation Command
Run this command on `DC01` if service account permissions fail during offboarding updates:
```cmd
dsacls "OU=Disabled_Users,OU=Synced_Objects,DC=hybrid,DC=lan" /I:S /G "hybrid.lan\svc-entrasync:RPWP;userAccountControl;user" "hybrid.lan\svc-entrasync:WP;mS-DS-ConsistencyGuid;user"
```

---

## 4. Standard Operational Procedures

### Step 1: Disable On-Premises Account & Revoke Kerberos/NTLM
> **Execution Node:** `DC01`

Disable the AD account, clear sensitive group memberships, set an unpredictable password, and scramble Kerberos ticket keys.

```powershell
# Import Active Directory Module
Import-Module ActiveDirectory

$TargetUser = "amercer"

# 1. Disable Account & Force Random 32-Character Password
$RandomPassword = ConvertTo-SecureString -String ([Guid]::NewGuid().ToString() + "!Aa1") -AsPlainText -Force
Set-ADAccountPassword -Identity $TargetUser -NewPassword $RandomPassword
Disable-ADAccount -Identity $TargetUser

# 2. Clear Interactive Group Memberships (Preserve Domain Users)
$UserGroups = Get-ADPrincipalGroupMembership -Identity $TargetUser | Where-Object { $_.Name -ne "Domain Users" }
Remove-ADPrincipalGroupMembership -Identity $TargetUser -MemberOf $UserGroups -Confirm:$false

# 3. Move Account to Non-Sync or Disabled OU Container
Get-ADUser -Identity $TargetUser | Move-ADObject -TargetPath "OU=Disabled_Users,OU=Synced_Objects,DC=hybrid,DC=lan"
```

### Step 2: Force Immediate Cloud Synchronization
> **Execution Node:** `ENTRA-SYNC01`

Accelerate cloud state propagation by initiating an immediate Delta Sync cycle rather than waiting for the standard 30-minute interval.

```powershell
# Import ADSync Module and trigger delta sync
Import-Module "C:\Program Files\Microsoft Azure Active Directory Connect\Module\ADSyncConfig\ADSyncConfig.psd1"
Start-ADSyncSyncCycle -PolicyType Delta
```

### Step 3: Revoke Cloud Sessions & Reclaim Licenses
> **Execution Node:** Cloud / Entra ID PowerShell

Kill active OAuth refresh tokens, invalidate continuous access evaluation (CAE) tokens, and strip assigned M365 licenses.

```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All"

$CloudUser = Get-MgUser -UserId "amercer@davidbielascomcast.onmicrosoft.com"

# 1. Revoke All Active Refresh Tokens / Sign-In Sessions
Revoke-MgUserSignInSession -UserId $CloudUser.Id

# 2. Reclaim Assigned Direct Licenses
$AssignedLicenses = (Get-MgUser -UserId $CloudUser.Id -Property AssignedLicenses).AssignedLicenses
if ($AssignedLicenses) {
    $RemoveLicenses = $AssignedLicenses | Select-Object -ExpandProperty SkuId
    Set-MgUserLicense -UserId $CloudUser.Id -RemoveLicenses $RemoveLicenses -AddLicenses @{}
}
```

---

## 5. Emergency "Kill-Switch" Workflow

For high-risk terminations where waiting for directory synchronization is unacceptable, execute this **dual-action protocol**:

1. **Immediate Cloud Kill-Switch (Cloud-First):** Run directly in Graph PowerShell to revoke access within ~60 seconds.
   ```powershell
   # Instant Cloud Block & Session Revocation
   Update-MgUser -UserId "amercer@davidbielascomcast.onmicrosoft.com" -AccountEnabled:$false
   Revoke-MgUserSignInSession -UserId "amercer@davidbielascomcast.onmicrosoft.com"
   ```
2. **On-Premises Enforcement (AD-Second):** Immediately execute **Step 1** from Section 4 on `DC01` to prevent local resource access and enforce persistent state across subsequent sync passes.

---

## 6. Troubleshooting Decision Matrix

| Symptom / Error | Root Cause | Remediation Procedure |
| :--- | :--- | :--- |
| **Account Disabled On-Premises, but Active in Cloud** | Delta Sync cycle has not executed, or `userAccountControl` write permission missing. | Force immediate delta cycle (`Start-ADSyncSyncCycle -PolicyType Delta`). Verify service account ACLs using Section 3 `dsacls` command. |
| **User Can Still Access M365 Resources** | Active OAuth access token or Continuous Access Evaluation (CAE) session active. | Execute `Revoke-MgUserSignInSession` in Graph PowerShell to force instant token invalidation. |
| **User Moved to Disabled OU Disappears from Entra ID** | Target Disabled OU is excluded from Entra Connect Filtering scope. | Object enters **Soft-Deleted Users** state in Entra ID. If the account must remain visible (e.g., for shared mailbox conversion), move to a synced Disabled OU. |
| **Exchange Online Mailbox License Loss Kills Mailbox** | Direct license removed before placing mailbox on Litigation Hold or converting to Shared. | Convert mailbox to **Shared Mailbox** in Exchange Online Admin Center *before* removing M365 license assignment. |

---

## 7. Audit & Compliance Reference

### Cloud Audit Trail (Entra Admin Center)
* **Service:** `Core Directory` / `User Management`
* **Activity:** `Disable account`, `Revoke user sessions`, `Change user license`
* **Initiated By:** `ConnectSyncProvisioning_*` (for synchronized disables) or Administrator UPN (for direct revocations).

### On-Premises Security Log (`DC01`)
* **Log Path:** `Security`
* **Event ID 4725:** An account was disabled (Target: Offboarded User, Subject: Admin account).
* **Event ID 4723 / 4724:** An attempt was made to change/reset an account's password.
* **Event ID 4738:** A user account was changed (shows `userAccountControl` attribute modification delta).