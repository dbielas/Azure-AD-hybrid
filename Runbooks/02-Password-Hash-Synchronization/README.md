# Password Hash Synchronization (PHS) Operations & Troubleshooting Runbook

## 1. Executive Overview & Scope
* **Purpose:** Provides Tier 1–3 Helpdesk analysts, Systems Administrators, and Identity/Security Engineers with operational guidance, troubleshooting matrices, and permission delegation commands for Password Hash Synchronization (PHS) between on-premises Active Directory Domain Services (`DC01`) and Microsoft Entra ID via Entra Connect (`ENTRA-SYNC01`).
* **Target Audience:** Service Desk Analysts, Systems Administrators, Security Operations Center (SOC).
* **Prerequisites & Licensing:** Microsoft Entra ID Free/P1/P2, Entra Connect deployed with Password Hash Sync enabled on `ENTRA-SYNC01`.

---

## 2. Architecture & System Dependencies

### High-Level Signal Flow
```text
[DC01 (Active Directory)] ──(1. MS-DRSR RPC Calls)──> [ENTRA-SYNC01 (ADSync)]
                                                             │
                                                  (2. SHA-256 HMAC Hash)
                                                             │
                                                             ▼
                                                (3. HTTPS / TLS 1.2 Outbound)
                                                             │
                                                             ▼
                                                [Microsoft Entra ID Tenant]
```

### Critical Endpoints & Network Ports
* **On-Premises Replication Traffic:** TCP/UDP `135` (RPC Endpoint Mapper) and RPC dynamic range (`49152-65535`) between `ENTRA-SYNC01` and `DC01` for directory replication calls.
* **Outbound Cloud Connectivity:** TCP `443` HTTPS outbound to `*.msappproxy.net`, `*.servicebus.windows.net`, and Microsoft Entra ID authentication endpoints (`https://login.microsoftonline.com`).

---

## 3. Account Delegation & On-Premises ACLs

The custom Entra Connect service account (`hybrid.lan\svc-entrasync`) requires Directory Replication Service (DRS) rights at the domain root to extract password hashes via the MS-DRSR protocol.

### Required Active Directory Rights
* **Replicating Directory Changes** (`DS-Replication-Get-Changes`)
* **Replicating Directory Changes All** (`DS-Replication-Get-Changes-All`)

### ACL Verification & Remediation Command
Run this command on `DC01` if permission errors prevent hash extraction from domain controllers:
```cmd
dsacls "DC=hybrid,DC=lan" /I:S /G "hybrid.lan\svc-entrasync:CA;Replicating Directory Changes;;" "hybrid.lan\svc-entrasync:CA;Replicating Directory Changes All;;"
```

---

## 4. Operational Health Checks & Verification

### On the Entra Connect Sync Server (`ENTRA-SYNC01`)
* **Event Viewer Navigation:** `Applications and Services Logs` $\rightarrow$ `Azure AD Connect`
  * **Event ID 114 / 654:** Password hash sync cycle started / successfully completed.
  * **Event ID 611 / 652:** Hash replication failure or permission access denied during extraction from domain controllers.
* **Service Dependency:** Ensure the `Microsoft Azure AD Sync` (`ADSync`) service is running.

### PowerShell Configuration & Diagnostics Check
Run these commands in an elevated PowerShell session on `ENTRA-SYNC01`:

```powershell
# Import ADSync Configuration Module
Import-Module "C:\Program Files\Microsoft Azure Active Directory Connect\Module\ADSyncConfig\ADSyncConfig.psd1"

# Verify PHS Global and Connector Status via Diagnostics
Invoke-ADSyncDiagnostics -PasswordHashSynchronization

# Trigger an immediate full Password Hash Sync cycle for all users
$adConnector = (Get-ADSyncConnector | Where-Object {$_.Type -eq "AD"}).Name
Invoke-ADSyncPasswordHashSync -ConnectorName $adConnector
```

---

## 5. Troubleshooting Decision Matrix

| Symptom / Error | Root Cause | Remediation Procedure |
| :--- | :--- | :--- |
| **Event ID 611 (`Access Denied`)** | Service account missing Directory Replication permissions on the domain root. | Re-delegate replication rights on the domain root using the `dsacls` remediation command in Section 3. |
| **Single User Hash Not Syncing** | User account has `User must change password at next logon` (`pwdLastSet = 0`) set on-premises. | PHS ignores accounts requiring an immediate password change. User must set an initial password on-premises first, or reset via SSPR. |
| **High Latency / Stale Passwords** | Network congestion or RPC port exhaustion between `ENTRA-SYNC01` and `DC01`. | Verify RPC dynamic port availability (`49152-65535`) and test latency between `ENTRA-SYNC01` and all active DCs. |
| **Global Hash Sync Stopped** | PHS feature disabled globally in the Entra Connect configuration or service stopped. | Re-run Entra Connect wizard (`AzureADConnect.exe`), select *Customize Synchronization Options*, and ensure *Password Hash Synchronization* is checked. |

---

## 6. Audit & Compliance Reference

### Cloud Audit Trail (Entra Admin Center)
* **Service:** `Core Directory`
* **Activity:** `Update user`
* **Initiated By:** `ConnectSyncProvisioning_*` (Service Principal)
* **Property Note:** Password hash updates write to system metadata silently without altering explicit cleartext or hash strings in tenant logs.

### On-Premises Security Log (`DC01`)
* **Log Path:** `Security`
* **Event ID 4662:** An operation was performed on an object (shows `Subject` as service account `hybrid.lan\svc-entrasync` requesting control access rights for `Replicating Directory Changes`).