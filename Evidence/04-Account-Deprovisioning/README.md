# Account Disable & Deprovisioning Lifecycle Validation

## Executive Summary
This directory contains end-to-end evidence validating on-premises account disabling and cloud identity deprovisioning from Active Directory (`DC01`) to Microsoft Entra ID via Entra Connect (`ENTRA-SYNC01`). It demonstrates how modifying the on-premises `userAccountControl` attribute triggers automated cloud state updates (`accountEnabled: false`) and enforces instant access revocation patterns across hybrid identity boundaries.

---

## 1. Test Metadata
* **Target Account:** `amercer` / `amercer@hybrid.lan` (`Alex Mercer`) $\rightarrow$ `amercer@davidbielascomcast.onmicrosoft.com`
* **Service Principal:** `ConnectSyncProvisioning_ENTRA-SYNC01_e72762af8e46`
* **Sync Server:** `ENTRA-SYNC01`
* **Domain Controller:** `DC01`
* **Target Attribute:** `userAccountControl` (Bitmask `66050`: `DONT_EXPIRE_PASSWORD` + `NORMAL_ACCOUNT` + `ACCOUNTDISABLE`)
* **Cloud State Change:** `accountEnabled` (`true` $\rightarrow$ `false`)

---

## 2. Evidence Chain of Custody

| Step | Source System | Evidence File / Artifact | Key Findings |
|---|---|---|---|
| **01. On-Premises Disable** | `DC01` | [Account-Disable.ps1](./Account-Disable.ps1) / [output](./dc01-account-disable.txt) | Executed `Disable-ADAccount`; flipped `ACCOUNTDISABLE` bit `0x0002` (`66048` $\rightarrow$ `66050`). |
| **02. Delta Engine Execution** | `ENTRA-SYNC01` | [delta-sync-trigger](./delta-sync-trigger.jpg) | Triggered `Start-ADSyncSyncCycle -PolicyType Delta`; engine staged `userAccountControl` modifications in AD Connector Space. |
| **03. Delta Export Staging** | `ENTRA-SYNC01` | [miisclient-export-disable](./miisclient-export-disable.jpg) | Verified `Connector Space Object Properties` during Delta Export. Confirmed `accountEnabled` attribute transform staged from `true` to `false`. |
| **04. Entra ID Audit Log** | Entra ID Portal | [entra-audit-account-disable](./entra-audit-account-disable.jpg) | Verified `Disable account` / `Update user` event under Core Directory audit logs. Confirmed `accountEnabled: false` property diff. |
| **05. Token & Access Revocation** | Entra ID Portal | [entra-user-state-disabled](./entra-user-state-disabled.jpg) | Verified global account status set to **Disabled** in Entra ID Admin Center, blocking primary authentication and session refreshes. |

---

## 3. Deep-Dive Analysis: Disable Mechanics & State Engine

### On-Premises Flag Evaluation
In Active Directory, disabling an account modifies the `userAccountControl` bitmask property:
* **Standard User Baseline:** Typically `512` (`NORMAL_ACCOUNT`), updating to `514` (`NORMAL_ACCOUNT` + `ACCOUNTDISABLE`).
* **Lab Environment (`66050`):** Because the account was provisioned with `PasswordNeverExpires: True`, the active bitmask was `66048` (`0x10200`). Disabling the account set bit `0x0002` (`ACCOUNTDISABLE`), yielding `66050`:
  $$\text{DONT\_EXPIRE\_PASSWORD}\ (65536) + \text{NORMAL\_ACCOUNT}\ (512) + \text{ACCOUNTDISABLE}\ (2) = \mathbf{66050}$$

### Sync Engine Transformation Logic
During the Delta Synchronization cycle, Entra Connect evaluates the bitwise flag via outbound sync rules:
1. **Inbound Rule (`In from AD - User Common`):** Translates the raw bitmask `userAccountControl` property into a boolean metaverse attribute: `accountEnabled`.
2. **Metaverse Evaluation:** If `(userAccountControl & 2) == 2`, `accountEnabled` is set to `False`.
3. **Outbound Rule (`Out to AAD - User Join`):** Exports the boolean `accountEnabled: false` state via Graph API to the target Entra tenant.

### Security Impact & Session Invalidation
When `accountEnabled` flips to `false` in Entra ID:
* **Interactive Auth:** Immediate blockage of new Interactive Logins (Modern Auth / Basic Auth).
* **Token Invalidation:** Triggers Continuous Access Evaluation (CAE) checks to revoke active Refresh Tokens, revoking session access across M365/Entra-integrated applications.

---

## 4. Operational Considerations & Scope Management

### Soft-Delete vs. Scope Exclusion
* **Account Disable (This Directory):** The object remains **in sync scope** (OU filters still apply). The identity exists in Entra ID, but its authentication state is globally locked (`accountEnabled: false`).
* **Moving Out of Scope:** Moving a disabled account to an unsynced OU triggers a **Cloud Soft-Delete** (moving the object to *Deleted Users* in Entra ID for 30 days before hard-deletion).

### Privileged Account Edge Case (AdminSDHolder)
If an account being disabled is a member of protected AD groups (e.g., *Account Operators*, *Domain Admins*), ACL inheritance may be disabled via `AdminSDHolder`. Ensure sync engine service accounts retain `Read userAccountControl` rights across all target OUs to prevent stale active states in the cloud.

---

## 5. Artifacts

* 📄 **PowerShell Disable Script:** [`Account-Disable.ps1`](./Account-Disable.ps1)
* 📄 **Active Directory Output:** [`dc01-account-disable.txt`](./dc01-account-disable.txt)
* 🖼️ **Delta Sync Trigger:** [`delta-sync-trigger.jpg`](./delta-sync-trigger.jpg)
* 🖼️ **Connector Space Object Properties:** [`miisclient-export-disable.jpg`](./miisclient-export-disable.jpg)
* 🖼️ **Entra Audit Log Confirmation:** [`entra-audit-account-disable.jpg`](./entra-audit-account-disable.jpg)
* 🖼️ **Entra User State Confirmation:** [`entra-user-state-disabled.jpg`](./entra-user-state-disabled.jpg)
